# Changelog

## [1.3.0] — 2026-07-13

### Added
- **Voice Actions on selected text (hold Fn+Shift)**: select text anywhere, speak an
  instruction ("make this formal", "translate to English", "summarize in two lines",
  "fix the grammar") — the review panel opens with the rewritten text (purple "Rewrite"
  badge) and Enter replaces the selection. Clipboard fully preserved.
- **Dictation voice commands** (deterministic, zero latency): "new line",
  "new paragraph", and "scratch that" (discards everything dictated before it).
- **Voice snippets**: settings-defined trigger phrases expand into templates —
  say "insert signature" or "insert calendly" mid-dictation. Multi-line templates.
- **Adaptive style profile**: after every 10 accepted refines, a background Claude turn
  studies your (raw dictation → final sent) pairs and maintains a ~150-word style memo
  that shapes all future drafts. View/edit/clear it in Settings; toggle to freeze.

### Changed
- Hotkey monitor now tracks Shift; Ctrl outranks Shift when both held.
- Refine/revise requests carry the learned style hint.

### Verified
- 83 Swift + 25 sidecar tests passing; live transform round-trip 2.0s; live learn turn
  produced a correct profile from sample pairs.

## [1.2.0] — 2026-07-13

### Added
- **Audio ducking**: system output volume drops to 10% while you hold Fn and is restored
  to the exact prior level on release — no more competing audio while dictating.
  Automatically skipped when a call app (Zoom, Teams, FaceTime, Slack, Discord, browsers
  running web meetings…) is actively capturing the microphone, so dictating mid-call never
  silences the other participants. Toggle in Settings → General.
- `skvoice-check duck` diagnostic (shows volume, call detection, duck/restore cycle).

### Changed
- Settings decoding is now tolerant: new fields fall back to defaults instead of
  resetting the whole settings file (vocabulary and custom prompts survive upgrades).

## [1.1.0] — 2026-07-13

### Added
- **Refine review window**: Fn+Ctrl no longer auto-pastes. A floating panel shows the
  drafted text with: editable draft, tone chips (Shorter / More formal / More casual /
  More detailed), Regenerate (⌘R), Insert (Enter), Discard (Esc), and voice follow-up —
  hold Fn while the window is open to dictate an adjustment to the current draft.
- **Smart target detection**: each refine is classified as a MESSAGE (Slack, Mail,
  Messages…) or an AI PROMPT (Claude, ChatGPT, Cursor, terminals, AI browser tabs).
  Prompt mode expands dictated intent into a structured, well-specified prompt.
  The mode badge in the review window can be clicked to switch and re-draft.
- Sidecar `revise` request + per-mode prompt framing (19 sidecar tests).
- Auto-registers as a login item on first launch.

### Changed
- Premium visual refresh: glass floating bar with teal (dictate) / indigo (refine)
  accents, refreshed dashboard badges, new indigo–teal waveform app icon.
- Insert refocuses the app you dictated into before pasting.

## [1.0.0] — 2026-07-12

### Added
- Hold-to-talk dictation on **Fn**: pre-warmed mic capture, on-device SpeechTranscriber
  ASR, custom vocabulary replacements, paste-at-cursor with clipboard save/restore and
  secure-field clipboard fallback.
- Refine mode on **Fn+Ctrl**: dictated intent + Accessibility screen context sent to a warm
  Claude Agent SDK session (Claude Code subscription auth — zero marginal cost), drafted
  message pasted in place; falls back to raw transcript if the sidecar is unavailable.
- Floating screen-edge bar (idle/recording waveform/transcribing/refining/error states).
- Dashboard: searchable history with copy/delete + raw-vs-refined view, settings (hold
  threshold, vocabulary editor, refine system prompt, model picker, sidecar status/restart,
  pause hotkeys, launch at login).
- Permission onboarding (mic / accessibility / input monitoring, live status polling,
  🌐-key guidance).
- `skvoice-check` diagnostic CLI (wav / mic / context / sidecar subcommands).
- Packaging script producing a signed `SK Voice.app` with the sidecar bundled.
- Test coverage: 42 Swift tests + 13 sidecar tests, live smoke verification
  (see tests/reports/2026-07-12-initial-verification.md).
