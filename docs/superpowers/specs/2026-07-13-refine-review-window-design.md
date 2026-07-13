# SK Voice v1.1 — Refine Review Window Design

**Date:** 2026-07-13
**Status:** Approved by Saqib (dictated feedback after first live use of v1.0) and shipped.

## Motivation

v1.0 refine auto-pasted Claude's draft blind. Saqib wants to *see* the draft first,
steer it, and only insert deliberately. He also wants the app to understand *what* he is
dictating into: a message to a person vs. a prompt for an AI assistant — each needs a
different kind of refinement.

## Behavior

- **Fn dictation is unchanged** — instant paste, no window. Only Fn+Ctrl changes.
- On Fn+Ctrl release: transcribe locally → remember the target app
  (`NSRunningApplication`) → classify mode → open the review panel → request the draft
  from the sidecar.

### Mode classification (`TargetClassifier`)

Deterministic, instant, user-overridable:
1. Messaging app names (Slack, Messages, Mail, Outlook, WhatsApp, Teams, Discord, …)
   → **message** (wins even if the window title mentions AI).
2. AI bundle ids (Anthropic, OpenAI, Cursor) and terminals (Terminal, iTerm2, Warp,
   kitty, Ghostty — where Claude Code lives) → **prompt**.
3. AI markers in the window title (claude, chatgpt, gemini, copilot, perplexity, grok) —
   catches browser tabs → **prompt**.
4. Default → **message**.

The panel's mode badge flips the mode and re-drafts.

- **message** → sidecar drafts the polished message matching conversation tone.
- **prompt** → sidecar expands the intent into a structured prompt (goal, context,
  constraints, expected output; no invented requirements).

### Review panel

Floating glass panel (activating, all-Spaces): editable draft (`TextEditor`), mode badge,
target app label, tone chips (Shorter / More formal / More casual / More detailed),
Regenerate (⌘R), Insert (Enter — reactivates the target app, waits for focus, pastes,
saves history), Discard (Esc), busy/listening indicators.

**Voice follow-up:** while the panel is open, holding Fn records a revision instruction;
on release the transcript goes to the sidecar `revise` request (draft + instruction →
new draft) instead of starting a new capture. Ctrl is irrelevant during review.

**Failure path:** if the sidecar errors/times out, the panel keeps the raw transcript as
the draft with a warning — the user can edit and insert as-is. (Replaces v1.0's
auto-paste-raw fallback.)

### Sidecar protocol additions

- `refine` gains `mode: "message" | "prompt"` (defaults to message for back-compat).
- New `revise`: `{id, type:"revise", draft, instruction, context, appName, mode}` →
  `result`. Same warm session, same serialization and recycling.

## Visual refresh (same release)

Teal = dictation, indigo = refine/prompt, everywhere (bar, badges, panel accents).
Floating bar: `.ultraThinMaterial` capsule with tinted stroke. New app icon:
indigo→teal gradient, light waveform glyph, top-edge highlight.

## Testing

- `TargetClassifierTests` (7 cases incl. browser-tab detection and messaging-beats-AI-title).
- Sidecar: revise parsing/framing + per-mode framing tests (19 total).
- Protocol codec: mode + revise encoding (Swift side).
- Live verification: v1.1 installed, app + sidecar running with permissions intact.
