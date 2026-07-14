# SK Voice

Personal macOS voice dictation app — a self-hosted replacement for Willow Voice with zero
subscription cost.

- **Hold Fn** → speak → release → your words are typed into whatever app you're using.
- **Hold Fn+Ctrl** → speak your intent → a floating review panel opens with Claude's draft:
  edit it, apply tone chips (shorter/formal/casual/detailed), speak a follow-up adjustment
  by holding Fn, then press Enter to insert into the app you came from.
- **Smart target detection**: dictating into Slack/Mail/Messages drafts a polished message;
  dictating into Claude Code, claude.ai, ChatGPT, or Cursor expands your intent into a
  structured prompt instead. The panel badge shows the detected mode and can be flipped.
- **Hold Fn+Shift on selected text** → speak an instruction ("make this formal",
  "translate to English") → review the rewrite → Enter replaces the selection.
- **Voice commands & snippets**: "new line", "new paragraph", "scratch that", plus your
  own trigger phrases ("insert signature" → full signature block). Zero added latency.
- **Adaptive style**: the app learns how you write from your accepted drafts and applies
  that style to every future draft. Editable in Settings.

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
├── TargetClassifier message vs AI-prompt mode (bundle id + window title)
├── HistoryStore     SQLite
└── UI: floating edge bar · refine review panel · dashboard · onboarding
```

## Build & install

```bash
./scripts/build-app.sh              # builds sidecar + app, assembles + signs dist/SK Voice.app
cp -R "dist/SK Voice.app" /Applications/
open "/Applications/SK Voice.app"
```

Requirements: macOS 26+, Xcode toolchain, Node ≥18, Claude Code CLI logged in,
`brew install whisper-cpp pkgconf` (native Urdu ASR for translation mode).

First launch walks you through: Microphone, Accessibility, Input Monitoring permissions,
plus setting **"Press 🌐 key to" → "Do Nothing"** in Keyboard settings.

## Development

```bash
cd app && swift test                # 83 unit/integration tests
cd sidecar && npx vitest run        # 25 protocol/session tests
cd app && swift run skvoice-check wav|mic|context|sidecar   # pipeline diagnostics
```

Docs: design spec in `docs/superpowers/specs/`, implementation plan in
`docs/superpowers/plans/`, research notes in `docs/research.md`, test reports in
`tests/reports/`.
