# SK Voice — Design Spec

**Date:** 2026-07-12
**Status:** Approved (brainstormed with Saqib; ASR engine amended during research — see Decision Log)

## Purpose

A personal macOS voice dictation app replacing Willow Voice. Two modes, both triggered by
global hold-to-talk hotkeys, both "instant":

1. **Dictation (hold Fn):** speak → release → transcript is pasted at the cursor of the
   frontmost app.
2. **Refine (hold Fn+Ctrl):** speak an intent → release → transcript plus on-screen context
   is sent to Claude, and the drafted/refined message is pasted instead.

Zero marginal cost: on-device ASR, and the refine LLM runs through the existing Claude Code
subscription (Agent SDK auth), not a metered API key.

## Feature parity checklist (vs Willow Voice 2.3.0)

- [x] Hold-to-talk dictation on Fn, paste into any app
- [x] Assistant/refine mode on Fn+Ctrl
- [x] Floating screen-edge bar with recording/processing states (right edge, like user's Willow setting)
- [x] Transcript history dashboard
- [x] Custom vocabulary / replacements
- [x] Screen context for refine mode (Scribe-style, via Accessibility text — no screenshots)
- [x] Menu bar app, login item, permission onboarding

## Architecture

```
SK Voice.app (Swift 6, SwiftPM, menu bar)     claude-sidecar (Node 20+, TypeScript)
├── HotkeyMonitor      CGEventTap flagsChanged├── @anthropic-ai/claude-agent-sdk
├── AudioRecorder      pre-warmed AVAudioEngine├── warm long-lived session (streaming input)
├── Transcriber        SpeechAnalyzer/SpeechTranscriber (on-device)
├── VocabularyProcessor find/replace rules    ├── Unix socket ~/.skvoice/sidecar.sock
├── TextInserter       AX paste (Cmd+V synth) └── NDJSON request/response protocol
├── ScreenContext      AX tree of frontmost window
├── FloatingBar        NSPanel edge pill
├── HistoryStore       SQLite (~/Library/Application Support/SKVoice/history.db)
├── Dashboard          SwiftUI window (history + settings)
└── SidecarClient      spawns/monitors sidecar, socket client
```

Targets (SwiftPM, mirrors sk-note-taker layout):
- `SKVoiceCore` (library): hotkey state machine, audio, transcription, vocabulary, inserter,
  screen context, history, sidecar client. Fully unit-testable.
- `SKVoiceApp` (executable): menu bar UI, floating bar, dashboard, onboarding.
- `skvoice-check` (executable): diagnostic CLI — mic → ASR pipeline, sidecar round-trip.
- `SKVoiceCoreTests`: unit tests.

## Dictation flow (hold Fn)

1. `flagsChanged` reports Fn down → HotkeyMonitor state machine arms; FloatingBar → recording;
   AudioRecorder taps the pre-warmed engine immediately (engine started at app launch so
   there is no spin-up latency).
2. Fn up → stop tap. Presses shorter than 0.30 s are discarded (accidental Fn taps).
3. Audio (16 kHz mono Float32) → Transcriber (SpeechTranscriber, volatile results ignored,
   final results concatenated).
4. VocabularyProcessor applies user replacement rules (case-insensitive match, word-boundary
   aware) — e.g. "sk note taker" → "SK Note Taker", client names, jargon.
5. TextInserter pastes: save pasteboard → set transcript → synthesize Cmd+V via CGEvent →
   restore pasteboard after 300 ms. If the focused element rejects paste (secure input),
   leave transcript on the clipboard and notify "Copied to clipboard instead."
6. HistoryStore saves (mode=dictation, raw, final, app bundle id, duration, timestamps).
7. FloatingBar → idle.

## Refine flow (hold Fn+Ctrl)

1. Same recording UX (bar shows "refine" accent color).
2. On key-down, ScreenContext captures the frontmost window's readable text via the AX tree
   (`AXFocusedWindow` → walk static text/text areas, cap ~6 kB). Runs concurrently with
   recording; never blocks. Empty context is fine.
3. On release: local transcription as above → request to sidecar over the Unix socket:
   `{"id":"…","type":"refine","transcript":"…","context":"…","appName":"…"}`.
4. Sidecar holds a warm Agent SDK session (streaming-input mode, so one long-lived CLI
   process serves many requests — no per-request cold start). System prompt: draft polished
   messages from dictated intent, match the tone of the conversation context, output ONLY
   the message text.
5. Response streams back; on completion the draft is pasted via TextInserter.
6. History saves raw transcript + refined draft.
7. **Fallback:** sidecar dead/timeout (8 s)/error → paste the raw transcript and show a
   warning notification, so the user is never blocked mid-message.

## Sidecar lifecycle

- Swift app spawns `node sidecar/dist/index.js` at launch, restarts with backoff if it exits.
- Auth: Agent SDK uses the Claude Code CLI login (subscription). No API key stored.
- Protocol: NDJSON over Unix socket. Requests: `refine`, `ping`. Responses:
  `{"id","type":"result","text"}` or `{"id","type":"error","message"}`.
- Session re-warms after each request (send a no-op or re-create session) so the next
  request is fast.

## UI

- **FloatingBar:** small vertical pill `NSPanel` (non-activating, all-Spaces, status-window
  level) pinned to the right screen edge. States: idle (dim dot) / recording (waveform from
  mic RMS) / transcribing (spinner) / refining (spinner, accent color) / error (red flash).
  Click opens Dashboard.
- **Dashboard (SwiftUI):** History tab — searchable list, each row shows mode badge, text,
  source app, time, copy button (reuse SK Note Taker copy pattern). Settings tab — vocabulary
  editor (table of find→replace), hold-threshold, refine system prompt editor, ASR engine
  picker (Local now; Cloud stub for future), sidecar status indicator, launch-at-login toggle.
- **Menu bar item:** icon reflects state; menu = Open Dashboard, Pause hotkeys, Quit.
- **Onboarding window (first launch):** step-through for Microphone, Accessibility, Input
  Monitoring permissions with live status checks; note about setting the system
  "Press 🌐 key to: Do Nothing" so Fn doesn't also trigger the emoji picker/system dictation.

## Permissions

Microphone (AVCaptureDevice), Accessibility (AXIsProcessTrusted — needed for CGEventTap on
flagsChanged AND for paste + screen context), Input Monitoring (event tap). App is unsandboxed
(personal tool, distributed as a local .app bundle, ad-hoc signed).

## Error handling

- ASR model missing → onboarding triggers `AssetInventory` download (system-managed, small).
- Engine/tap failure → bar error state + notification; hotkeys re-arm automatically.
- Secure-input field → clipboard fallback (above).
- Sidecar failures → raw-transcript fallback (above).
- All errors logged to `logs/errors.log` (rotating, per logging-system protocol).

## Testing

- Unit: HotkeyMonitor state machine (down/up/short-tap/ctrl-added-mid-hold), Vocabulary
  Processor (word boundaries, case, overlaps), NDJSON protocol codec, HistoryStore CRUD,
  ScreenContext truncation.
- Integration: `skvoice-check` — feeds a fixture WAV through the full ASR path and prints
  the transcript; `--sidecar` flag does a live refine round-trip.
- Sidecar: vitest tests for protocol framing + a mock-SDK session test.
- E2E: scripted run that records synthesized speech (say command → virtual playback is not
  reliable headless, so E2E uses the WAV-fixture path) and verifies paste into a test
  TextEdit window via AX.

## Decision log

- **ASR = Apple SpeechAnalyzer/SpeechTranscriber, not whisper.cpp** (amended from the
  originally approved design). Rationale: identical proven code already ships in the user's
  SK Note Taker (macOS 26 target, this machine runs 26.4.1); on-device, no 1.5 GB model
  download, faster-than-realtime, zero dependencies. whisper.cpp rejected: heavier
  integration, model management, slower on short utterances. Cloud ASR remains a settings
  stub for the "hybrid" choice; not wired in v1 (YAGNI until local accuracy disappoints).
- **Refine LLM = Claude Code subscription via Agent SDK sidecar** (user decision — no API cost).
- **Hotkeys = Willow parity:** hold Fn dictate, hold Fn+Ctrl refine (user decision).
- **No VPIO / voice processing on the mic tap** — raw input tap only (lesson from SK Note
  Taker: VPIO without an output chain yields silence; dictation needs no echo cancellation).
