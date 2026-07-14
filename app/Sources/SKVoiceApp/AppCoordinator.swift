import Foundation
import SwiftUI
import AppKit
import UserNotifications
import AVFoundation
import IOKit.hid
import ApplicationServices
import Synchronization
import SKVoiceCore

/// Floating bar / menu bar visual state.
enum BarState: Equatable {
    case idle
    case recording(mode: CaptureMode)
    case transcribing
    case refining
    case error(String)
}

/// Orchestrates the whole pipeline. Owns every core component and reacts to hotkey actions.
@MainActor
final class AppCoordinator: ObservableObject {
    @Published var barState: BarState = .idle
    @Published var inputLevel: Float = 0
    @Published var settings: AppSettings
    @Published var sidecarHealthy = false
    @Published var permissionsComplete: Bool
    @Published var historyRevision = 0   // bumped after each save so views refresh

    let history: HistoryStore?
    private let recorder = MicRecorder()
    private let sidecar: SidecarClient
    private var monitor: HotkeyMonitor?
    private var transcriber: DictationTranscriber?
    private var captureStart = Date()
    private var levelTimer: Timer?
    private var currentContext: (appName: String, windowTitle: String, text: String) = ("", "", "")
    private var contextTask: Task<Void, Never>?
    private var targetApp: NSRunningApplication?

    /// Active refine review, if any. While non-nil, Fn dictation revises the draft.
    private(set) var review: ReviewSession?
    private let reviewWindow = ReviewWindowController()

    init() {
        let loaded = AppSettings.load()
        settings = loaded
        permissionsComplete = Permissions.allGranted()

        history = try? HistoryStore(
            path: AppSettings.supportDirectory.appendingPathComponent("history.db").path)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        sidecar = SidecarClient(
            socketPath: "\(home)/.skvoice/sidecar.sock",
            nodePath: nil,
            sidecarDir: Self.bundledSidecarDir())
    }

    /// Resources/sidecar inside the app bundle; falls back to the repo layout for dev runs.
    static func bundledSidecarDir() -> String {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("sidecar").path,
           FileManager.default.fileExists(atPath: "\(bundled)/dist/index.js") {
            return bundled
        }
        // swift run from app/: ../sidecar
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent().appendingPathComponent("sidecar").path
    }

    // MARK: - Lifecycle

    func startServices() {
        guard permissionsComplete else { return }

        do {
            try recorder.prewarm()
        } catch {
            barState = .error("Mic unavailable")
            logError("prewarm failed: \(error)")
        }

        let asrLocale = settings.asrLocale
        Task {
            try? await DictationTranscriber.ensureModel(locale: asrLocale)
        }
        Task.detached {
            AudioStore.cleanup(olderThanDays: 30)
        }

        // Urdu mode: load the whisper context now (~11 s once) so the first dictation
        // doesn't stall.
        if usesWhisper && whisper == nil {
            Task {
                self.whisper = try? WhisperTranscriber()
            }
        }

        let prompt = settings.refineSystemPrompt
        let model = settings.modelOverride
        appliedSidecarConfig = (prompt, model)
        Task {
            await sidecar.configure { (systemPrompt: prompt, model: model) }
            await sidecar.start()
            sidecarHealthy = await sidecar.isHealthy()
        }

        let monitor = HotkeyMonitor(holdThreshold: settings.holdThreshold) { [weak self] action in
            Task { @MainActor in
                self?.handle(action: action)
            }
        }
        monitor.isPaused = settings.hotkeysPaused
        if !monitor.start() {
            barState = .error("Enable Input Monitoring")
            logError("event tap creation failed — missing Input Monitoring permission?")
        }
        self.monitor = monitor
    }

    func refreshPermissions() {
        let granted = Permissions.allGranted()
        if granted != permissionsComplete {
            permissionsComplete = granted
            if granted { startServices() }
        }
    }

    /// Sidecar config last applied — restart only when it actually changes, not on every
    /// settings mutation (vocab/snippet/style edits must not drop the warm session).
    private var appliedSidecarConfig: (prompt: String, model: String?)?

    private var appliedASRLocale: String?

    func applySettingsChange() {
        try? settings.save()
        monitor?.updateThreshold(settings.holdThreshold)
        monitor?.isPaused = settings.hotkeysPaused

        // Language changed → make sure the on-device model is installed.
        let locale = settings.asrLocale
        if appliedASRLocale != locale.identifier {
            appliedASRLocale = locale.identifier
            Task {
                try? await DictationTranscriber.ensureModel(locale: locale)
            }
        }

        let prompt = settings.refineSystemPrompt
        let model = settings.modelOverride
        guard appliedSidecarConfig?.prompt != prompt
                || appliedSidecarConfig?.model != model else { return }
        appliedSidecarConfig = (prompt, model)
        Task {
            await sidecar.configure { (systemPrompt: prompt, model: model) }
            await sidecar.restart()
            sidecarHealthy = await sidecar.isHealthy()
        }
    }

    func restartSidecar() {
        Task {
            await sidecar.restart()
            sidecarHealthy = await sidecar.isHealthy()
        }
    }

    func shutdown() {
        monitor?.stop()
        Task { await sidecar.stop() }
    }

    // MARK: - Hotkey pipeline

    /// Selected text grabbed at Fn+Shift-down (transform mode).
    private var grabbedSelection = ""
    private var selectionTask: Task<Void, Never>?
    /// Samples accumulated during the current capture (for audio saving + whisper).
    private let capturedSamples = SampleAccumulator()
    /// Lazy-loaded whisper context for Urdu mode (kept warm across captures).
    private var whisper: WhisperTranscriber?

    /// True when captures should be transcribed by whisper (Urdu mode + model present).
    private var usesWhisper: Bool {
        settings.dictationLanguage == "urdu-mixed" && WhisperTranscriber.modelInstalled
    }

    private func handle(action: HotkeyAction) {
        switch action {
        case .start(let mode):
            beginCapture(mode: mode)
            review?.listening = true
        case .upgrade(let mode):
            guard review == nil else { return }
            barState = .recording(mode: mode)
            if mode == .refine { captureScreenContext() }
            if mode == .transform { grabSelection() }
        case .finish(let mode):
            review?.listening = false
            endCapture(mode: mode)
        case .cancel:
            review?.listening = false
            cancelCapture()
        }
    }

    private let ducker = AudioDucker()

    private func beginCapture(mode: CaptureMode) {
        captureStart = Date()
        barState = .recording(mode: mode)
        currentContext = ("", "", "")
        targetApp = NSWorkspace.shared.frontmostApplication
        if settings.duckWhileDictating {
            Task.detached { [ducker] in ducker.duck() }
        }

        capturedSamples.reset()
        let sampleSink = capturedSamples

        if usesWhisper {
            // Whisper path: accumulate only; batch transcription happens at release.
            recorder.beginCapture { samples in
                sampleSink.append(samples)
            }
        } else {
            let transcriber = DictationTranscriber(locale: settings.asrLocale)
            self.transcriber = transcriber
            Task {
                try? await transcriber.start()
            }
            recorder.beginCapture { samples in
                sampleSink.append(samples)
                Task { await transcriber.feed(samples) }
            }
        }

        if mode == .refine {
            captureScreenContext()
        }
        if mode == .transform {
            grabSelection()
        }

        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.inputLevel = self.recorder.inputLevel
            }
        }
    }

    private func captureScreenContext() {
        contextTask?.cancel()
        contextTask = Task.detached { [weak self] in
            let context = ScreenContext.capture()
            await MainActor.run { self?.currentContext = context }
        }
    }

    private func grabSelection() {
        grabbedSelection = ""
        selectionTask?.cancel()
        selectionTask = Task { [weak self] in
            let selection = await SelectionGrabber.grab()
            self?.grabbedSelection = selection
        }
    }

    private func endCapture(mode: CaptureMode) {
        recorder.endCapture()
        Task.detached { [ducker] in ducker.restore() }
        stopLevelTimer()

        if transcriber == nil && usesWhisper {
            endCaptureWithWhisper(mode: mode)
            return
        }
        guard let transcriber else {
            barState = .idle
            return
        }
        self.transcriber = nil
        let duration = Date().timeIntervalSince(captureStart)
        barState = mode == .refine ? .refining : .transcribing

        let vocabulary = VocabularyProcessor(rules: settings.vocabulary)
        let frontAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""

        Task {
            let raw = await transcriber.finish()
            guard !raw.isEmpty else {
                self.flashError("Heard nothing")
                return
            }
            let transcript = vocabulary.apply(raw)

            if self.review != nil {
                // A review window is open — this dictation is a revision instruction.
                self.barState = .idle
                self.reviseReview(instruction: transcript)
                return
            }

            switch mode {
            case .dictation:
                // Deterministic pass: spoken commands + snippets, zero added latency.
                let processor = TranscriptPostProcessor(snippets: self.settings.snippets)
                guard let processed = processor.apply(transcript) else {
                    self.barState = .idle  // fully scratched — deliver nothing
                    return
                }
                if self.settings.translationActive {
                    await self.translateAndDeliver(text: processed, raw: raw,
                                                   appName: frontAppName,
                                                   duration: duration)
                } else {
                    await self.deliver(text: processed, raw: raw, mode: .dictation,
                                       appName: frontAppName, duration: duration)
                }
            case .refine:
                self.openReview(transcript: transcript, appName: frontAppName)
            case .transform:
                self.openTransform(instruction: transcript, appName: frontAppName)
            }
        }
    }

    /// Whisper path (Urdu mode): batch-transcribe the capture natively, then feed the
    /// same downstream pipeline (review for refine/transform, translate turn for
    /// dictation).
    private func endCaptureWithWhisper(mode: CaptureMode) {
        let duration = Date().timeIntervalSince(captureStart)
        barState = .transcribing
        let samples = capturedSamples.snapshot()
        let vocabulary = VocabularyProcessor(rules: settings.vocabulary)
        let frontAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""

        Task {
            let raw: String
            do {
                if self.whisper == nil {
                    self.whisper = try WhisperTranscriber()
                }
                let whisper = self.whisper!
                raw = try await Task.detached(priority: .userInitiated) {
                    try whisper.transcribe(samples: samples, language: "auto")
                }.value
            } catch {
                self.logError("whisper failed: \(error)")
                self.flashError("Urdu transcription failed")
                return
            }
            guard !raw.isEmpty else {
                self.flashError("Heard nothing")
                return
            }
            let transcript = vocabulary.apply(raw)

            if self.review != nil {
                self.barState = .idle
                self.reviseReview(instruction: transcript)
                return
            }
            switch mode {
            case .dictation:
                await self.translateAndDeliver(text: transcript, raw: raw,
                                               appName: frontAppName, duration: duration)
            case .refine:
                self.openReview(transcript: transcript, appName: frontAppName)
            case .transform:
                self.openTransform(instruction: transcript, appName: frontAppName)
            }
        }
    }

    /// Translation-mode dictation: reconstruct/translate through the warm session, then
    /// paste. Falls back to the raw transcript so the user is never blocked.
    private func translateAndDeliver(text: String, raw: String,
                                     appName: String, duration: Double) async {
        barState = .refining
        do {
            let english = try await sidecar.revise(
                draft: text, instruction: AppSettings.translateInstruction,
                context: "", appName: appName, mode: .message,
                styleHint: settings.styleProfile)
            await deliver(text: english, raw: raw, mode: .dictation,
                          appName: appName, duration: duration)
        } catch {
            logError("translate failed, pasting raw transcript: \(error)")
            notify(title: "Translation unavailable",
                   body: "Pasted the raw transcript instead.")
            await deliver(text: text, raw: raw, mode: .dictation,
                          appName: appName, duration: duration)
        }
    }

    private func openTransform(instruction: String, appName: String) {
        barState = .idle
        let selection = grabbedSelection
        guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            flashError("No text selected")
            return
        }
        let session = ReviewSession(
            rawTranscript: instruction,
            context: "",
            appName: appName,
            mode: .message,
            targetApp: targetApp,
            isTransform: true)
        session.rememberSelection(selection)
        session.draft = selection
        review = session
        reviewWindow.show(session: session, coordinator: self)
        let styleHint = settings.styleProfile
        runReviewTurn(label: "Rewriting…") { [sidecar] in
            try await sidecar.revise(
                draft: selection, instruction: instruction, context: "",
                appName: appName, mode: .message, styleHint: styleHint)
        }
    }

    // MARK: - Review window flow

    private func openReview(transcript: String, appName: String) {
        barState = .idle
        let contextAppName = currentContext.appName.isEmpty ? appName
                                                            : currentContext.appName
        let mode = TargetClassifier.classify(
            bundleID: targetApp?.bundleIdentifier,
            appName: contextAppName,
            windowTitle: currentContext.windowTitle)
        let session = ReviewSession(
            rawTranscript: transcript,
            context: currentContext.text,
            appName: contextAppName,
            mode: mode,
            targetApp: targetApp)
        session.draft = transcript
        review = session
        reviewWindow.show(session: session, coordinator: self)
        let styleHint = settings.styleProfile
        runReviewTurn(label: "Drafting…") { [sidecar] in
            try await sidecar.refine(
                transcript: session.rawTranscript, context: session.context,
                appName: session.appName, mode: session.mode, styleHint: styleHint)
        }
    }

    func reviseReview(instruction: String) {
        guard let session = review else { return }
        let draft = session.draft
        let styleHint = settings.styleProfile
        runReviewTurn(label: "Revising…") { [sidecar] in
            try await sidecar.revise(
                draft: draft, instruction: instruction, context: session.context,
                appName: session.appName, mode: session.mode, styleHint: styleHint)
        }
    }

    func regenerateReview() {
        guard let session = review else { return }
        if session.isTransform {
            let styleHint = settings.styleProfile
            let selection = session.originalSelection ?? session.draft
            let instruction = session.rawTranscript
            let appName = session.appName
            let mode = session.mode
            runReviewTurn(label: "Rewriting…") { [sidecar] in
                try await sidecar.revise(
                    draft: selection, instruction: instruction, context: "",
                    appName: appName, mode: mode, styleHint: styleHint)
            }
            return
        }
        let styleHint = settings.styleProfile
        runReviewTurn(label: "Redrafting…") { [sidecar] in
            try await sidecar.refine(
                transcript: session.rawTranscript, context: session.context,
                appName: session.appName, mode: session.mode, styleHint: styleHint)
        }
    }

    func switchReviewMode() {
        guard let session = review else { return }
        session.mode = session.mode == .prompt ? .message : .prompt
        regenerateReview()
    }

    private func runReviewTurn(label: String,
                               _ turn: @escaping @Sendable () async throws -> String) {
        guard let session = review else { return }
        session.busy = true
        session.busyLabel = label
        session.errorText = nil
        Task {
            do {
                let text = try await turn()
                guard self.review === session else { return }
                session.draft = text
                session.busy = false
            } catch {
                guard self.review === session else { return }
                session.busy = false
                session.errorText =
                    "Claude unavailable — you can edit and insert the text as-is."
                self.logError("review turn failed: \(error)")
                self.sidecarHealthy = await self.sidecar.isHealthy()
            }
        }
    }

    func insertReview() {
        guard let session = review, !session.busy else { return }
        review = nil
        reviewWindow.close()
        let duration = Date().timeIntervalSince(captureStart)
        Task {
            let result = await TextInserter.insert(session.draft, into: session.targetApp)
            if result == .copiedOnly {
                self.notify(title: "Copied to clipboard",
                            body: "A secure field was focused, so SK Voice didn't type into it.")
            }
            let entry = HistoryEntry(mode: .refine, rawTranscript: session.rawTranscript,
                                     finalText: session.draft, appName: session.appName,
                                     durationSeconds: duration)
            try? self.history?.save(entry)
            self.saveAudioIfEnabled(for: entry.id)
            self.historyRevision += 1
            self.recordAcceptedRefine(isTransform: session.isTransform)
        }
    }

    /// Adaptive style learning: every Nth accepted refine, update the style profile from
    /// recent (raw → final) pairs in a background sidecar turn. Transforms are excluded —
    /// their "raw" is an instruction, not the user's dictated voice.
    private func recordAcceptedRefine(isTransform: Bool) {
        guard !isTransform else { return }
        settings.refineInsertCount += 1
        try? settings.save()
        guard settings.autoLearnStyle,
              StyleLearner.shouldLearn(insertCount: settings.refineInsertCount),
              let entries = history?.recent(limit: 30, search: nil) else { return }
        let pairs = StyleLearner.pairs(from: entries)
        guard !pairs.isEmpty else { return }
        let currentProfile = settings.styleProfile
        Task {
            do {
                let updated = try await self.sidecar.learn(
                    pairs: pairs, currentProfile: currentProfile)
                if !updated.isEmpty {
                    self.settings.styleProfile = updated
                    try? self.settings.save()
                }
            } catch {
                self.logError("style learn failed (will retry at next interval): \(error)")
            }
        }
    }

    func discardReview() {
        review = nil
        reviewWindow.close()
        barState = .idle
    }

    private func deliver(text: String, raw: String, mode: CaptureMode,
                         appName: String, duration: Double) async {
        let result = await TextInserter.insert(text)
        if result == .copiedOnly {
            notify(title: "Copied to clipboard",
                   body: "A secure field was focused, so SK Voice didn't type into it.")
        }
        let entry = HistoryEntry(mode: mode, rawTranscript: raw, finalText: text,
                                 appName: appName, durationSeconds: duration)
        try? history?.save(entry)
        saveAudioIfEnabled(for: entry.id)
        historyRevision += 1
        barState = .idle
    }

    /// Persist the capture's audio for playback in History (background; local only).
    private func saveAudioIfEnabled(for entryID: String) {
        guard settings.keepAudioRecordings else { return }
        let samples = capturedSamples.snapshot()
        guard !samples.isEmpty else { return }
        Task.detached {
            AudioStore.save(samples: samples, for: entryID)
        }
    }

    private func cancelCapture() {
        recorder.endCapture()
        Task.detached { [ducker] in ducker.restore() }
        stopLevelTimer()
        contextTask?.cancel()
        if let transcriber {
            self.transcriber = nil
            Task { await transcriber.cancel() }
        }
        barState = .idle
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        inputLevel = 0
    }

    private func flashError(_ message: String) {
        barState = .error(message)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if case .error = self.barState { self.barState = .idle }
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func logError(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let url = AppSettings.supportDirectory.appendingPathComponent("errors.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(line.utf8).write(to: url)
        }
        FileHandle.standardError.write(Data("SKVoice: \(message)\n".utf8))
    }
}

/// Thread-safe accumulator for the current capture's audio samples.
final class SampleAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func reset() {
        lock.lock(); defer { lock.unlock() }
        samples = []
    }

    func append(_ chunk: [Float]) {
        lock.lock(); defer { lock.unlock() }
        samples.append(contentsOf: chunk)
    }

    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }
}

/// Permission checks used by onboarding and startup.
enum Permissions {
    static func microphoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    static func inputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func allGranted() -> Bool {
        microphoneGranted() && accessibilityGranted() && inputMonitoringGranted()
    }
}
