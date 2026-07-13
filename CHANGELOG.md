# Changelog

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
