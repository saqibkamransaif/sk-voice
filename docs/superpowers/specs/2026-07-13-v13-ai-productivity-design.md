# SK Voice v1.3 — AI Productivity Features Design

**Date:** 2026-07-13 · **Status:** Autonomous build authorized by Saqib ("think of top
features, design, plan, execute and test yourself").

Four features, chosen for compounding value with the existing pipeline and Saqib's actual
workflow (Claude Code prompting, client messages, recurring phrases):

## F1 — Voice Actions on selected text (hold Fn+Shift)

Select any text in any app → hold **Fn+Shift** → speak an instruction ("make this formal",
"translate to English", "summarize in two lines", "fix the grammar") → the review window
opens with the transformed text → Enter replaces the selection.

- Selection is grabbed at Fn-down via synthesized Cmd+C with full clipboard save/restore
  (`SelectionGrabber`). No selection → error flash "No text selected".
- Reuses the sidecar `revise` request verbatim: draft = selection, instruction = spoken
  transcript. No sidecar changes needed.
- `CaptureMode` gains `.transform`; `HotkeyStateMachine` maps Shift the way it maps Ctrl
  (sticky upgrade; Ctrl wins if both held). Floating bar shows a third accent (purple).

## F2 — Voice commands during dictation (deterministic, zero latency)

Spoken commands handled by a post-processor — no LLM, no added latency:
- "new line" / "new paragraph" → line breaks (inline, any position, case-insensitive,
  tolerant of surrounding punctuation).
- "scratch that" → discards everything dictated before it in this capture (keeps what
  follows: "…wrong text scratch that right text" → "right text").
Applied after vocabulary rules, before pasting. Pure function → TDD.

## F3 — Voice snippets

Settings table of trigger phrase → template ("insert signature" → full signature block,
"insert calendly" → booking link). Spoken trigger matched inline (whole-phrase,
case-insensitive, punctuation-tolerant) and replaced with the template. Deterministic,
same post-processor pass as F2. Multi-line templates supported.

## F4 — Adaptive style profile (the app learns how you write)

After every 10 accepted refines, a background sidecar turn analyzes recent
(raw dictation → final inserted text) pairs and maintains a ~150-word style memo
("prefers short sentences, em-dashes, signs off with 'Cheers', says *pull request* not
*PR*…"). The memo rides along on every refine/revise as a `styleHint` field and shapes
future drafts. Settings shows the learned profile — editable, clearable, and a toggle to
freeze learning. New sidecar request `learn` {pairs, currentProfile} → updated profile.

## Out of scope (considered, rejected for now)

Per-app personas (style profile + screen context already adapt tone), multi-language
auto-detect (locale risk), analytics digests (not productivity).

## Testing

TDD for the post-processor (commands + snippets), state machine shift handling, selection
grabber clipboard logic, protocol additions (Swift + sidecar), style learner scheduling
(every-N logic, injectable). Live: full suites, `skvoice-check` paths, app relaunch, real
refine round-trip.
