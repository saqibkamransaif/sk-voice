# SK Voice

Personal macOS voice dictation app — a self-hosted replacement for Willow Voice with zero
subscription cost.

- **Hold Fn** → speak → release → your words are typed into whatever app you're using.
- **Hold Fn+Ctrl** → speak your intent → Claude drafts the polished message and types that
  instead, matching the tone of the conversation on screen.

Both feel instant: on-device Apple SpeechTranscriber ASR (a 2-second utterance transcribes
in ~0.16 s) and a pre-warmed Claude session (refines in ~1.5–2.5 s).

## How it stays free

- Transcription is 100% on-device (Apple Speech framework, macOS 26+).
- The refine mode runs through your existing **Claude Code subscription** via the Agent SDK —
  a small Node sidecar keeps one warm session alive; no API key, no per-token billing.

## Architecture

```
SK Voice.app (Swift 6, menu bar)          claude-sidecar (Node, bundled in Resources)
├── HotkeyMonitor    CGEventTap Fn/Fn+Ctrl ├── @anthropic-ai/claude-agent-sdk
├── MicRecorder      pre-warmed AVAudioEngine  (streaming-input warm session)
├── DictationTranscriber  SpeechAnalyzer   ├── Unix socket ~/.skvoice/sidecar.sock
├── VocabularyProcessor   custom replacements  (NDJSON: ping / refine)
├── TextInserter     AX Cmd+V + clipboard restore
├── ScreenContext    AX tree of frontmost window (no screenshots)
├── HistoryStore     SQLite
└── UI: floating edge bar · dashboard (history + settings) · onboarding
```

## Build & install

```bash
./scripts/build-app.sh              # builds sidecar + app, assembles + signs dist/SK Voice.app
cp -R "dist/SK Voice.app" /Applications/
open "/Applications/SK Voice.app"
```

Requirements: macOS 26+, Xcode toolchain, Node ≥18, Claude Code CLI logged in.

First launch walks you through: Microphone, Accessibility, Input Monitoring permissions,
plus setting **"Press 🌐 key to" → "Do Nothing"** in Keyboard settings.

## Development

```bash
cd app && swift test                # 42 unit/integration tests
cd sidecar && npx vitest run        # 13 protocol/session tests
cd app && swift run skvoice-check wav|mic|context|sidecar   # pipeline diagnostics
```

Docs: design spec in `docs/superpowers/specs/`, implementation plan in
`docs/superpowers/plans/`, research notes in `docs/research.md`, test reports in
`tests/reports/`.
