# Changelog

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
