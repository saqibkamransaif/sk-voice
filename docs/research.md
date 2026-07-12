# SK Voice — Technical Research

Date: 2026-07-12. Findings that ground the implementation plan.

## 1. Willow Voice 2.3.0 inspection (feature source of truth)

- Bundle `com.seewillow.WillowMac`: ships `whisper.framework`, `YbridOpus/YbridOgg`
  (compressed audio streaming to their cloud), Sparkle, Sentry.
- `NSAccessibilityUsageDescription`: "Willow needs accessibility access to paste text in
  your applications" → text insertion is Accessibility paste, same as our design.
- Prefs: `hasMigratedAssistantHotkeyToFnCtrl` (assistant = Fn+Ctrl), `barEdgePosition = right`
  (floating edge bar), Scribe = screen-context feature (`posthog.has_captured_scribe_screen_context_grant`).

## 2. ASR engine

- SK Note Taker (this machine, macOS 26.4.1) already uses **Apple SpeechAnalyzer +
  SpeechTranscriber** (`Speech` framework, macOS 26): on-device, faster than realtime,
  volatile+final results, model managed by `AssetInventory` (system-wide download).
  Code to reuse: `app/Sources/SKNoteCore/Transcription/TranscriptionService.swift`,
  `Audio/MicAudioSource.swift`, `Audio/AudioResampler.swift`.
- Key lessons embedded in that code (verified today in SK Note Taker work):
  - Do NOT enable voice processing (VPIO) on an input-only engine — yields silence.
  - Keep ONE persistent `AVAudioConverter` per stream; per-chunk converters corrupt audio.
  - Drain (don't cancel) the results consumer after `finalizeAndFinishThroughEndOfInput()`
    or trailing finals are lost.
- For dictation we consume only **final** results, concatenated in order.

## 3. Claude Agent SDK warm session (sidecar)

- Package: `@anthropic-ai/claude-agent-sdk` (Node ≥18; machine has v22.22.0, CLI 2.1.178).
- Auth: SDK drives the installed Claude Code CLI → uses the existing subscription login
  (Keychain). No API key.
- **Streaming input mode** is the warm-session mechanism: pass an `AsyncIterable` of user
  messages as `prompt`; one CLI process stays alive across turns. We implement a push queue:
  socket request → yield user message → read SDK messages until the turn's `result` message →
  reply on socket.
- Per-turn framing: each refine request is independent — prompt says "New independent
  request; ignore prior turns." Session recycled every 20 requests (or on error) to cap
  context growth. `options`: system prompt via `customSystemPrompt`/`systemPrompt`,
  `allowedTools: []` (pure text drafting, no tool use), default model (subscription);
  settings expose a model override (haiku for max speed).
- v2 `unstable_v2_createSession` exists but is marked unstable — use stable `query()`
  streaming input instead.

## 4. Fn / Fn+Ctrl global hotkey

- Fn is a modifier: listen for `flagsChanged` events (`CGEventTap`, listen-only,
  `.cghidEventTap`). Fn down ⇢ flags gain `.maskSecondaryFn`; release ⇢ flags lose it.
  Ctrl = `.maskControl` while Fn held → refine mode (mode decided at release by whether
  Ctrl was ever held during the press, matching Willow's feel).
- Permissions: listen-only event taps require Input Monitoring; AX paste + screen context
  require Accessibility. Onboarding covers both.
- System conflict: macOS "Press 🌐 key to" setting (emoji picker / system dictation) must be
  set to "Do Nothing" — onboarding instructs (Willow requires the same).
- Tap can be disabled by the system on timeout (`kCGEventTapDisabledByTimeout`) — re-enable
  in the callback.

## 5. Text insertion (paste-at-cursor)

- Save `NSPasteboard.general` string → write transcript → synthesize Cmd+V
  (`CGEvent(keyboardEventSource:virtualKey: 9, keyDown:)` + `.maskCommand`, post to
  `.cghidEventTap`) → restore prior pasteboard after 300 ms.
- Secure input (`IsSecureEventInputEnabled()`): skip synth, leave text on clipboard, notify.

## 6. Screen context (refine mode)

- `AXUIElementCreateSystemWide()` → `kAXFocusedApplicationAttribute` →
  `kAXFocusedWindowAttribute` → breadth-first walk collecting `AXValue`/`AXTitle` of
  StaticText/TextArea/TextField elements; cap at 6 kB; 300 ms time budget; failure → empty
  context (refine still works, just less tailored).

## 7. Packaging

- SwiftPM executable → `.app` bundle assembled by `scripts/build-app.sh` (same approach as
  SK Note Taker v1.4.0), ad-hoc codesign, Info.plist with usage descriptions
  (`NSMicrophoneUsageDescription`, `NSAccessibilityUsageDescription`), `LSUIElement = true`
  (menu bar only, no Dock icon).
- Sidecar bundled at `Contents/Resources/sidecar/` (prebuilt `dist/index.js` +
  `node_modules`), spawned with the user's `node` (resolved via `/usr/bin/env node` with
  nvm-aware PATH fallback).
