# SK Voice v1.3 Implementation Plan

> Executed inline by the building agent (autonomous session). Spec:
> `docs/superpowers/specs/2026-07-13-v13-ai-productivity-design.md`

**Goal:** Voice actions on selected text, dictation commands, voice snippets, adaptive
style profile — tested, shipped as v1.3.0.

## Tasks

1. **TranscriptPostProcessor (TDD)** — `Sources/SKVoiceCore/TranscriptPostProcessor.swift`
   - `init(snippets: [SnippetRule])`, `func apply(_ text: String) -> String?`
   - Commands: "new line"→`\n`, "new paragraph"→`\n\n` (inline, case-insensitive,
     strips adjacent commas/periods); "scratch that" keeps only text after the last
     occurrence; nil when the result is empty (whole capture scratched).
   - Snippets: whole-phrase case-insensitive trigger → template.
   - `SnippetRule {id, trigger, template}` added to Models + AppSettings (tolerant decode).
   - Tests: inline commands, punctuation adjacency, scratch-that variants, snippet
     multi-line, snippet+command combined, no-op passthrough.

2. **HotkeyStateMachine shift/transform (TDD)** — `CaptureMode.transform`;
   `handle(fn:ctrl:shift:at:)`; shift at down or mid-hold → transform (sticky), ctrl
   priority over shift. Update HotkeyMonitor (`.maskShift`) and existing tests
   (default `shift: false` param keeps old call sites compiling).

3. **SelectionGrabber** — `Sources/SKVoiceCore/SelectionGrabber.swift`: save pasteboard →
   synthesize Cmd+C → poll changeCount (≤500 ms) → read string → restore pasteboard.
   Returns "" without selection. Testable pieces reuse TextInserter save/restore.

4. **Style profile plumbing**
   - Sidecar: `learn` request `{id, type:"learn", pairs:[{raw,final}], currentProfile}` →
     result = updated profile; `refine`/`revise` gain optional `styleHint` appended to
     framing ("Match the user's known style: …"). Vitest coverage.
   - Swift: protocol + client `learn(pairs:currentProfile:)`, `styleHint` on refine/revise.
   - `StyleLearner` (Core, TDD): `shouldLearn(insertCount:)` every 10th; assembles pairs
     from HistoryStore refine entries where raw ≠ final.
   - AppSettings: `styleProfile: String = ""`, `autoLearnStyle: Bool = true`.
   - Coordinator: after insertReview, bump counter, fire background learn, save profile.
   - Settings UI: profile TextEditor + Clear + toggle; snippets table editor.

5. **Coordinator transform flow** — on `.start(.transform)`: grab selection (async, before
   speech ends); on finish: no selection → flashError; else revise(selection, instruction,
   styleHint) → review window (badge shows "Rewrite", purple); insert replaces selection
   (paste over selection). Floating bar purple accent for transform.

6. **Ship** — bump 1.3.0, full `swift test` + vitest, build-app.sh, reinstall, relaunch,
   verify sidecar, live transform round-trip via skvoice-check revise-style call,
   CHANGELOG + README, commit, push.
