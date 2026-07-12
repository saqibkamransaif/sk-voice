# SK Voice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Personal macOS dictation app — hold Fn to dictate into any app, hold Fn+Ctrl to have Claude draft/refine the message, both near-instant.

**Architecture:** Swift 6 SwiftPM menu-bar app (`SKVoiceCore` library + `SKVoiceApp` executable + `skvoice-check` diagnostic) with on-device SpeechTranscriber ASR, plus a long-lived Node/TypeScript sidecar exposing a warm Claude Agent SDK session over a Unix socket. Text lands in the frontmost app via Accessibility-synthesized Cmd+V.

**Tech Stack:** Swift 6 / SwiftUI / AppKit / Speech (SpeechAnalyzer) / AVAudioEngine / SQLite3 / CGEventTap · Node 22 / TypeScript / @anthropic-ai/claude-agent-sdk / vitest.

## Global Constraints

- macOS 26 minimum (`platforms: [.macOS("26.0")]`), machine runs 26.4.1.
- Swift tools 6.0; no third-party Swift dependencies (reuse patterns from `~/Sites/sk-note-taker`).
- Sidecar: Node ≥18 (machine: v22.22.0), auth via existing Claude Code CLI login — never an API key.
- Mic capture: raw input tap only — NEVER `setVoiceProcessingEnabled(true)` (silence bug, see docs/research.md §2).
- One persistent `AVAudioConverter` per stream (per-chunk converters corrupt audio).
- Unix socket at `~/.skvoice/sidecar.sock`; NDJSON protocol.
- Hold threshold 0.30 s; sidecar refine timeout 8 s with raw-transcript fallback.
- App is unsandboxed, `LSUIElement=true`, ad-hoc signed.
- Commit after every task (author `Saqib Kamran <github@saqibkamran.com>`, `[Frontend]/[Backend]/[Full-Stack]` scope prefixes).

## File Structure

```
sk-voice/
├── app/Package.swift
├── app/Sources/SKVoiceCore/
│   ├── Models.swift                # CaptureMode, HistoryEntry, Settings
│   ├── HotkeyStateMachine.swift    # pure logic (testable)
│   ├── HotkeyMonitor.swift         # CGEventTap wrapper feeding the state machine
│   ├── Audio/AudioResampler.swift  # adapted from SK Note Taker
│   ├── Audio/MicRecorder.swift     # pre-warmed engine, capture gate
│   ├── DictationTranscriber.swift  # SpeechAnalyzer wrapper (single channel)
│   ├── VocabularyProcessor.swift
│   ├── TextInserter.swift
│   ├── ScreenContext.swift
│   ├── HistoryStore.swift          # sqlite3
│   ├── SidecarProtocol.swift       # NDJSON codec
│   └── SidecarClient.swift         # spawn node + unix socket
├── app/Sources/SKVoiceApp/
│   ├── SKVoiceApp.swift            # @main, menu bar, wiring
│   ├── AppCoordinator.swift        # pipeline orchestration
│   ├── FloatingBar.swift           # NSPanel pill
│   ├── DashboardView.swift         # history + settings tabs
│   ├── OnboardingView.swift
│   └── LoginItem.swift
├── app/Sources/skvoice-check/main.swift
├── app/Tests/SKVoiceCoreTests/     # + Fixtures/hello.wav
├── sidecar/src/index.ts            # socket server
├── sidecar/src/session.ts          # warm Agent SDK session
├── sidecar/src/protocol.ts
├── sidecar/test/*.test.ts          # vitest
├── scripts/build-app.sh
└── docs/, tests/reports/, logs/
```

---

### Task 1: Scaffold SwiftPM project

**Files:** Create `app/Package.swift`, `app/Sources/SKVoiceCore/Models.swift`, stub mains, `app/Tests/SKVoiceCoreTests/ModelsTests.swift`.

**Interfaces — Produces:** `CaptureMode` (`.dictation`/`.refine`), `HistoryEntry` (id: String UUID, mode, rawTranscript: String, finalText: String, appName: String, durationSeconds: Double, createdAt: Date), `AppSettings` (holdThreshold: Double = 0.3, refineSystemPrompt: String default, modelOverride: String? = nil, vocabulary: [VocabRule]), `VocabRule` (find: String, replace: String).

- [ ] Write `Package.swift` mirroring sk-note-taker (products SKVoiceCore lib, SKVoiceApp exe, skvoice-check exe, test target with Fixtures resources; zero deps).
- [ ] Write `Models.swift` with the types above (all `Codable, Sendable, Equatable`); `AppSettings.load()/save()` via JSON at `~/Library/Application Support/SKVoice/settings.json`.
- [ ] Test: settings round-trip encode/decode; default prompt non-empty. Run `swift test` → PASS.
- [ ] Commit `[Full-Stack] [Scaffold] SwiftPM project skeleton`.

### Task 2: HotkeyStateMachine (TDD, pure logic)

**Files:** Create `HotkeyStateMachine.swift`, `Tests/.../HotkeyStateMachineTests.swift`.

**Interfaces — Produces:**
```swift
public enum HotkeyAction: Equatable, Sendable {
    case start(CaptureMode)      // begin recording
    case upgradeToRefine         // ctrl pressed mid-hold: bar switches accent
    case finish(CaptureMode)     // release ≥ threshold: process
    case cancel                  // release < threshold: discard
}
public struct HotkeyStateMachine {
    public init(holdThreshold: TimeInterval = 0.3)
    public mutating func handle(fn: Bool, ctrl: Bool, at t: TimeInterval) -> HotkeyAction?
    public var isActive: Bool { get }
}
```
Semantics: fn↓ → `.start(ctrl ? .refine : .dictation)`; ctrl↓ while active & mode==dictation → `.upgradeToRefine` (mode is sticky refine once seen); fn↑ → `.finish(mode)` if held ≥ threshold else `.cancel`. Ctrl release mid-hold does NOT downgrade.

- [ ] Write failing tests: dictation start/finish; short tap cancel; ctrl-at-down = refine; ctrl-mid-hold upgrade + sticky; ctrl-release keeps refine; repeated flags no-ops; second fn↓ while active ignored.
- [ ] Run `swift test --filter HotkeyStateMachine` → FAIL (type missing).
- [ ] Implement (~50 lines). Run → PASS.
- [ ] Commit `[Backend] [Hotkey] State machine with TDD`.

### Task 3: VocabularyProcessor (TDD)

**Files:** Create `VocabularyProcessor.swift`, tests.

**Interfaces — Produces:** `public struct VocabularyProcessor { init(rules: [VocabRule]); func apply(_ text: String) -> String }` — case-insensitive whole-word/phrase replacement, longest-rule-first, preserves surrounding punctuation.

- [ ] Failing tests: case-insensitive match ("sk note taker"→"SK Note Taker"), word boundary ("cat" rule must not hit "concatenate"), multi-word phrases, longest-first when overlapping, punctuation adjacency ("saqib," → "Saqib,").
- [ ] Implement with `NSRegularExpression` per rule: `\b` + escaped pattern + `\b`, options `.caseInsensitive`; sort rules by find.count descending. Run → PASS.
- [ ] Commit `[Backend] [Vocab] Vocabulary processor with TDD`.

### Task 4: Audio capture + transcription + skvoice-check

**Files:** Create `Audio/AudioResampler.swift` (copy from sk-note-taker, drop channel tagging), `Audio/MicRecorder.swift`, `DictationTranscriber.swift`, `Sources/skvoice-check/main.swift`, test `DictationTranscriberTests.swift` + `Fixtures/hello.wav` (generate: `say -o hello.aiff "hello world this is a test" && afconvert -f WAVE -d LEI16@16000 -c 1 hello.aiff hello.wav`).

**Interfaces — Produces:**
```swift
public final class MicRecorder: @unchecked Sendable {
    public init()
    public func prewarm() throws              // start engine at app launch
    public var inputLevel: Float { get }      // RMS for waveform UI
    public func beginCapture(onChunk: @escaping @Sendable ([Float]) -> Void)
    public func endCapture()
}
public actor DictationTranscriber {
    public init(locale: Locale = .init(identifier: "en-US"))
    public static func ensureModel() async throws
    public func start() async throws           // create analyzer (call at fn-down)
    public func feed(_ samples: [Float])        // 16 kHz mono
    public func finish() async -> String        // concatenated final results
}
```
MicRecorder: engine runs continuously from `prewarm()`; permanent tap resamples to 16 kHz mono and forwards only while capturing (atomic gate). Transcriber: SpeechAnalyzer + SpeechTranscriber, finals only, drain-don't-cancel (research §2).

- [ ] Generate WAV fixture; failing test: feed fixture through `DictationTranscriber` (start/feed/finish), assert lowercased result contains "hello".
- [ ] Implement resampler+recorder+transcriber. Run `swift test` → PASS (requires model; `ensureModel()` in test setup).
- [ ] `skvoice-check`: subcommands `wav <path>`, `mic [seconds]`, `context`, `sidecar <text>` (last two wired in later tasks; print "not wired" for now). Verify `swift run skvoice-check wav Tests/.../hello.wav` prints transcript.
- [ ] Commit `[Backend] [ASR] Mic recorder + SpeechTranscriber pipeline + diagnostic CLI`.

### Task 5: TextInserter

**Files:** Create `TextInserter.swift`, tests for pasteboard save/restore logic.

**Interfaces — Produces:** `public enum InsertResult { case pasted, copiedOnly }`; `public struct TextInserter { static func insert(_ text: String) async -> InsertResult }` — saves `NSPasteboard.general` string, writes text, posts Cmd+V (`CGEvent` vk 9 + `.maskCommand` to `.cghidEventTap`) unless `IsSecureEventInputEnabled()`, restores prior string after 300 ms (only if pasteboard unchanged by others — compare changeCount).

- [ ] Test (logic-level): save/restore helper preserves prior string; secure-input path returns `.copiedOnly` (inject `isSecure` flag for testability).
- [ ] Implement. Run → PASS. Manual check deferred to Task 13 E2E.
- [ ] Commit `[Backend] [Paste] Accessibility paste with clipboard restore`.

### Task 6: HistoryStore (sqlite3, TDD)

**Files:** Create `HistoryStore.swift`, tests.

**Interfaces — Produces:** `public final class HistoryStore: @unchecked Sendable { init(path: String) throws; func save(_ e: HistoryEntry) throws; func recent(limit: Int, search: String?) -> [HistoryEntry]; func delete(id: String) throws; func count() -> Int }` — raw sqlite3 C API, WAL mode, table `entries(id TEXT PK, mode TEXT, raw TEXT, final TEXT, app TEXT, duration REAL, created_at REAL)`.

- [ ] Failing tests (temp-dir db): save+recent roundtrip, search filters on final text, delete, ordering desc by created_at.
- [ ] Implement (~140 lines). Run → PASS.
- [ ] Commit `[Backend] [History] SQLite history store with TDD`.

### Task 7: Sidecar (TypeScript, vitest)

**Files:** Create `sidecar/package.json` (deps: `@anthropic-ai/claude-agent-sdk`; dev: typescript, vitest, esbuild), `sidecar/src/protocol.ts`, `sidecar/src/session.ts`, `sidecar/src/index.ts`, `sidecar/test/protocol.test.ts`, `sidecar/test/session.test.ts`.

**Interfaces — Produces:** NDJSON over `SKVOICE_SOCKET` (default `~/.skvoice/sidecar.sock`):
- → `{"id":"u1","type":"ping"}` ⇢ `{"id":"u1","type":"pong"}`
- → `{"id":"u2","type":"refine","transcript":"...","context":"...","appName":"Slack"}` ⇢ `{"id":"u2","type":"result","text":"..."}` | `{"id":"u2","type":"error","message":"..."}`

`session.ts`: `class WarmSession { constructor(opts: {systemPrompt: string, model?: string, queryFn?: typeof query}); async refine(req): Promise<string>; }` — push-queue async generator as `prompt` (streaming input, one CLI process), each turn framed "New independent request — ignore all previous turns."; collects assistant text until `result` message; recycle session after 20 turns or on stream error; `queryFn` injectable for tests.
`index.ts`: unlink stale socket, `net.createServer`, per-connection readline, serialize refines (queue), SIGTERM cleanup, heartbeat log to stderr.

- [ ] `npm init` + tsconfig (ES2022, NodeNext) + failing vitest: protocol encode/decode/invalid-json error reply; session test with fake `queryFn` yielding scripted SDK messages (assert framing text, result extraction, recycle-after-error creates second query call).
- [ ] Run `npx vitest run` → FAIL, implement, → PASS.
- [ ] Build `npm run build` (esbuild bundle → `dist/index.js`, external: none — bundle SDK).
- [ ] Live smoke (requires CLI login): `node dist/index.js` + `echo '{"id":"1","type":"refine","transcript":"tell John ill be five minutes late","context":"","appName":"Messages"}' | nc -U ~/.skvoice/sidecar.sock` → polished message text. Record output in tests/reports.
- [ ] Commit `[Backend] [Sidecar] Warm Claude Agent SDK session over unix socket`.

### Task 8: SidecarProtocol.swift + SidecarClient.swift

**Files:** Create both + `SidecarProtocolTests.swift`, `SidecarClientTests.swift`.

**Interfaces — Produces:**
```swift
public enum SidecarRequest: Encodable { case ping(id: String); case refine(id: String, transcript: String, context: String, appName: String) }
public enum SidecarResponse: Decodable, Equatable { case pong(id: String); case result(id: String, text: String); case error(id: String, message: String) }
public actor SidecarClient {
    public init(socketPath: String, nodePath: String?, sidecarDir: String)
    public func start()                       // spawn node + connect w/ retry+backoff
    public func refine(transcript: String, context: String, appName: String) async throws -> String  // 8 s timeout
    public func isHealthy() async -> Bool     // ping round-trip
    public func stop()
}
```
POSIX unix-socket client (Darwin `socket/connect/read/write` on a background queue), newline framing, single in-flight request. Process supervision: relaunch with 1→2→4→8 s capped backoff.

- [ ] Failing protocol codec tests (encode/decode all variants). Implement, PASS.
- [ ] Client integration test: test spawns a tiny Node echo script (fixture `Tests/.../fake-sidecar.js` responding pong/result) → assert refine round-trip + timeout error when script sleeps.
- [ ] Wire `skvoice-check sidecar <text>` to real sidecar. Run against Task 7 build → prints refined text.
- [ ] Commit `[Full-Stack] [Sidecar] Swift client with process supervision`.

### Task 9: ScreenContext

**Files:** Create `ScreenContext.swift`.

**Interfaces — Produces:** `public enum ScreenContext { static func capture(maxBytes: Int = 6144, budget: TimeInterval = 0.3) -> (appName: String, text: String) }` — AX systemwide → focused app → focused window → BFS collecting `AXValue`/`AXTitle`/`AXDescription` of text-ish roles; join with newlines, truncate to cap; any failure ⇒ `("", "")`.

- [ ] Implement; wire `skvoice-check context` to print result. Manual verify: run while a Notes window frontmost → captures its text. (Pure AX — no reliable unit test; verified in E2E.)
- [ ] Commit `[Backend] [Context] Frontmost-window text capture via AX`.

### Task 10: HotkeyMonitor (CGEventTap) + AppCoordinator pipeline

**Files:** Create `HotkeyMonitor.swift` (Core), `SKVoiceApp/AppCoordinator.swift`.

**Interfaces:**
- Consumes: everything above.
- Produces: `HotkeyMonitor` — `init(onAction: @escaping @Sendable (HotkeyAction) -> Void)`, `func start() -> Bool` (creates listen-only `CGEventTap` for `.flagsChanged`, re-enables on `tapDisabledByTimeout`, reads `.maskSecondaryFn`/`.maskControl`, drives `HotkeyStateMachine`); `AppCoordinator: ObservableObject` — `@Published var barState: BarState` (`idle/recording(level:Float)/transcribing/refining/error(String)`), owns MicRecorder/Transcriber/VocabularyProcessor/SidecarClient/HistoryStore, implements the two flows from the spec §Dictation/§Refine incl. refine fallback-to-raw and clipboard-only path notifications (UserNotifications).

- [ ] Implement both; `swift build` clean.
- [ ] Commit `[Full-Stack] [Pipeline] Event tap and end-to-end coordinator`.

### Task 11: UI — FloatingBar, Dashboard, Onboarding, menu bar

**Files:** Create `FloatingBar.swift`, `DashboardView.swift`, `OnboardingView.swift`, `LoginItem.swift` (copy pattern from sk-note-taker), `SKVoiceApp.swift`.

- [ ] FloatingBar: non-activating `NSPanel` (`.statusBar` level, all Spaces, ignores mouse except click-to-open-dashboard), 14×64 pt pill on right edge, SwiftUI content switching on `BarState` (dim dot / animated level bars / spinner / orange spinner for refine / red flash).
- [ ] Dashboard `NSWindow` with `TabView`: **History** (searchable `List`, mode badge, source app + relative time, copy button per row, delete swipe) · **Settings** (Form: hold threshold slider 0.15–0.6 s, vocabulary table editor add/remove rows, refine prompt `TextEditor`, model picker [Default/Haiku/Sonnet], sidecar status dot + restart button, launch-at-login toggle, pause-hotkeys toggle).
- [ ] Onboarding: 3-step permission walkthrough (mic → `AVCaptureDevice.requestAccess`; accessibility → `AXIsProcessTrustedWithOptions` prompt; input monitoring → `IOHIDCheckAccess`/open System Settings pane) + "Set 🌐 key to Do Nothing" instruction with deep link `x-apple.systempreferences:com.apple.Keyboard-Settings.extension`; shown until all green.
- [ ] `SKVoiceApp.swift`: `@main`, `MenuBarExtra` (icon reflects state; Open Dashboard / Pause Hotkeys / Quit), starts prewarm + tap + sidecar at launch, shows onboarding when permissions missing.
- [ ] `swift build` clean; commit `[Frontend] [UI] Floating bar, dashboard, onboarding, menu bar`.

### Task 12: Packaging

**Files:** Create `scripts/build-app.sh`, `app/Resources/Info.plist`, app icon placeholder.

- [ ] `build-app.sh`: swift build -c release → assemble `dist/SK Voice.app` (MacOS/SK Voice, Info.plist with `LSUIElement`, `NSMicrophoneUsageDescription`, `NSAccessibilityUsageDescription`, min system 26.0, bundle id `com.saqib.skvoice`) → copy `sidecar/dist` + `node_modules`-free bundle into `Contents/Resources/sidecar/` → `codesign --force --deep -s -` → optional `cp -R` to `/Applications`.
- [ ] Run script; verify `codesign -v` passes and app launches (open, then pkill).
- [ ] Commit `[Full-Stack] [Build] App bundle packaging script`.

### Task 13: Full verification + docs

**Files:** Create `README.md`, `CHANGELOG.md`, `tests/reports/2026-07-12-initial.md`, `logs/` bootstrap.

- [ ] `swift test` full suite → all PASS; `npx vitest run` → all PASS.
- [ ] `skvoice-check wav` fixture → transcript OK; `skvoice-check sidecar "draft a thank you note to the team"` → refined text OK; `skvoice-check context` with TextEdit frontmost → text captured.
- [ ] E2E paste test: open TextEdit, run a harness that calls `TextInserter.insert("e2e test 123")`, read back the document text via AX, assert match, screenshot.
- [ ] Write test report (all commands + outputs), README (features, permissions, build, architecture diagram), CHANGELOG v1.0.0.
- [ ] Commit; create GitHub repo `saqibkamransaif/sk-voice` (`gh auth switch` → create+push → switch back to the work account).

## Self-Review

- Spec coverage: dictation flow (T2,4,5,10), refine (T7,8,9,10), floating bar/history/vocab/context (T11,6,3,9), onboarding+permissions (T11), packaging (T12), fallbacks (T8,10), diagnostics+E2E (T4,13). Cloud-ASR stub = settings picker note only (YAGNI, per spec).
- No placeholders: interfaces carry exact signatures; UI tasks specify concrete controls and behaviors.
- Type consistency: `CaptureMode`, `HotkeyAction`, `BarState`, `SidecarRequest/Response`, `HistoryEntry` names match across tasks.
