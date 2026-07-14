import SwiftUI
import AppKit
import AVFoundation
import SKVoiceCore

struct DashboardView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        TabView {
            HistoryTab(coordinator: coordinator)
                .tabItem { Label("History", systemImage: "clock") }
            SettingsTab(coordinator: coordinator)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .frame(minWidth: 620, minHeight: 460)
    }
}

// MARK: - History

struct HistoryTab: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var search = ""
    @State private var entries: [HistoryEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search history…", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding([.horizontal, .top], 12)

            if entries.isEmpty {
                Spacer()
                Text(search.isEmpty ? "No dictations yet — hold Fn and speak."
                                    : "No matches.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(entries) { entry in
                    HistoryRow(entry: entry) {
                        try? coordinator.history?.delete(id: entry.id)
                        AudioStore.delete(for: entry.id)
                        reload()
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: search) { reload() }
        .onChange(of: coordinator.historyRevision) { reload() }
    }

    private func reload() {
        entries = coordinator.history?
            .recent(limit: 200, search: search.isEmpty ? nil : search) ?? []
    }
}

/// Urdu model status/download UI inside the language section.
struct UrduModelSection: View {
    @ObservedObject private var downloader = WhisperModelDownloader.shared
    @State private var installed = WhisperTranscriber.modelInstalled

    var body: some View {
        if installed {
            Label("Urdu speech model installed — dictation is transcribed natively, then translated to English by Claude.",
                  systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        } else if downloader.downloading {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: downloader.progress)
                Text("Downloading Urdu speech model… \(Int(downloader.progress * 100))% of ~574 MB")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: downloader.progress) {
                if downloader.progress >= 1 { installed = WhisperTranscriber.modelInstalled }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("For real Urdu understanding, download the on-device Whisper model (~574 MB, one time). Until then, Urdu is approximated through the English recognizer — expect poor accuracy on pure Urdu.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = downloader.errorText {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button("Download Urdu Model") { downloader.start() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Shared playback so starting one recording stops the previous.
@MainActor
final class AudioPlayback {
    static let shared = AudioPlayback()
    private var player: AVAudioPlayer?

    func play(entryID: String) {
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: AudioStore.url(for: entryID))
        player?.play()
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    let onDelete: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if AudioStore.hasAudio(for: entry.id) {
                    Button {
                        AudioPlayback.shared.play(entryID: entry.id)
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Play what you actually said")
                }
                Text(entry.mode == .refine ? "REFINE" : "DICTATE")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .foregroundStyle(entry.mode == .refine ? Color.indigo : Color.teal)
                    .background(entry.mode == .refine ? Color.indigo.opacity(0.15)
                                                      : Color.teal.opacity(0.15),
                                in: Capsule())
                Text(entry.appName).font(.caption).foregroundStyle(.secondary)
                Text(entry.createdAt, style: .relative).font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.finalText, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy text")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete entry")
            }
            Text(entry.finalText)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(4)
            if entry.mode == .refine, entry.rawTranscript != entry.finalText {
                Text("Raw: \(entry.rawTranscript)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings

struct SettingsTab: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var newFind = ""
    @State private var newReplace = ""
    @State private var newTrigger = ""
    @State private var newTemplate = ""

    var body: some View {
        Form {
            Section("Dictation language") {
                Picker("Language", selection: binding(\.dictationLanguage)) {
                    Text("English (US)").tag("en-US")
                    Text("English (India)").tag("en-IN")
                    Text("Urdu / Mixed — translate to English").tag("urdu-mixed")
                }
                if coordinator.settings.dictationLanguage == "urdu-mixed" {
                    UrduModelSection()
                } else {
                    Toggle("Polish dictation through Claude before pasting",
                           isOn: binding(\.translateToEnglish))
                    Text("Adds ~2 s per dictation; useful for cleaning up rough speech.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Hotkeys") {
                Toggle("Pause hotkeys", isOn: binding(\.hotkeysPaused))
                VStack(alignment: .leading) {
                    Text(String(format: "Hold threshold: %.2f s",
                                coordinator.settings.holdThreshold))
                    Slider(value: binding(\.holdThreshold), in: 0.15...0.6, step: 0.05)
                }
                Text("Hold **Fn** to dictate · hold **Fn + Ctrl** to refine with Claude")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Vocabulary") {
                ForEach(coordinator.settings.vocabulary) { rule in
                    HStack {
                        Text(rule.find)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(rule.replace).bold()
                        Spacer()
                        Button {
                            coordinator.settings.vocabulary.removeAll { $0.id == rule.id }
                            coordinator.applySettingsChange()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("heard text", text: $newFind)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("replace with", text: $newReplace)
                    Button("Add", action: addVocabRule)
                        .buttonStyle(.bordered)
                        .disabled(newFind.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newReplace.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Snippets — say the trigger, get the template") {
                ForEach(coordinator.settings.snippets) { snippet in
                    HStack(alignment: .top) {
                        Text("“\(snippet.trigger)”").font(.callout)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(snippet.template).font(.caption)
                            .foregroundStyle(.secondary).lineLimit(3)
                        Spacer()
                        Button {
                            coordinator.settings.snippets.removeAll { $0.id == snippet.id }
                            coordinator.applySettingsChange()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                TextField("Spoken trigger (e.g. insert signature)", text: $newTrigger)
                    .onSubmit(addSnippet)
                TextField("Template text (multi-line supported)",
                          text: $newTemplate, axis: .vertical)
                    .lineLimit(2...5)
                HStack {
                    Text("Also built in: “new line”, “new paragraph”, “scratch that”.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Snippet", action: addSnippet)
                        .buttonStyle(.borderedProminent)
                        .disabled(trimmedTrigger.isEmpty || trimmedTemplate.isEmpty)
                }
            }

            Section("Your writing style (learned automatically)") {
                Toggle("Keep learning from my accepted drafts",
                       isOn: binding(\.autoLearnStyle))
                if coordinator.settings.styleProfile.isEmpty {
                    Text("No profile yet — it builds itself after every \(StyleLearner.interval) accepted refines.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextEditor(text: binding(\.styleProfile))
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    Button("Clear learned profile") {
                        coordinator.settings.styleProfile = ""
                        coordinator.applySettingsChange()
                    }
                }
            }

            Section("Refine (Claude)") {
                HStack {
                    Circle()
                        .fill(coordinator.sidecarHealthy ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(coordinator.sidecarHealthy ? "Sidecar connected"
                                                    : "Sidecar unavailable")
                        .font(.caption)
                    Spacer()
                    Button("Restart sidecar") { coordinator.restartSidecar() }
                }
                Picker("Model", selection: binding(\.modelOverride)) {
                    Text("Subscription default").tag(String?.none)
                    Text("Haiku (fastest)").tag(String?.some("haiku"))
                    Text("Sonnet").tag(String?.some("sonnet"))
                }
                VStack(alignment: .leading) {
                    Text("System prompt").font(.caption)
                    TextEditor(text: binding(\.refineSystemPrompt))
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 110)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(.quaternary))
                }
            }

            Section("General") {
                Toggle("Keep audio recordings", isOn: binding(\.keepAudioRecordings))
                Text("Each capture's audio is saved locally for playback in History (auto-deleted after 30 days).")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Duck other audio while dictating", isOn: binding(\.duckWhileDictating))
                Text("Lowers system volume to 10% while you hold Fn and restores it after — including other voices on a call, so only you are heard while recording.")
                    .font(.caption).foregroundStyle(.secondary)
                LaunchAtLoginToggle()
            }
        }
        .formStyle(.grouped)
    }

    private var trimmedTrigger: String {
        newTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedTemplate: String {
        newTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addSnippet() {
        guard !trimmedTrigger.isEmpty, !trimmedTemplate.isEmpty else { return }
        coordinator.settings.snippets.append(
            SnippetRule(trigger: trimmedTrigger, template: trimmedTemplate))
        newTrigger = ""
        newTemplate = ""
        coordinator.applySettingsChange()
    }

    private func addVocabRule() {
        let find = newFind.trimmingCharacters(in: .whitespaces)
        let replace = newReplace.trimmingCharacters(in: .whitespaces)
        guard !find.isEmpty, !replace.isEmpty else { return }
        coordinator.settings.vocabulary.append(VocabRule(find: find, replace: replace))
        newFind = ""
        newReplace = ""
        coordinator.applySettingsChange()
    }

    /// Two-way binding into settings that persists + applies on change.
    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { coordinator.settings[keyPath: keyPath] },
            set: { newValue in
                coordinator.settings[keyPath: keyPath] = newValue
                coordinator.applySettingsChange()
            })
    }
}
