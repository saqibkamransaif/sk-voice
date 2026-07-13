# SK Voice v1.0.0 — Initial verification report

Date: 2026-07-12 · Machine: macOS 26.4.1 (Apple Silicon) · Node v22.22.0 · Claude CLI 2.1.178

## Automated test suites

| Suite | Result |
|---|---|
| Swift (`swift test`, app/) | **42/42 passed** — models, hotkey state machine (10), vocabulary (7), transcriber fixture, text inserter (3), history store (6), sidecar protocol (8), sidecar client integration (5) |
| Sidecar (`npx vitest run`, sidecar/) | **13/13 passed** — protocol parsing (8), warm session behavior (5: framing, process reuse, recycling, failure recovery, serialization) |

## Live end-to-end checks (real services)

| Check | Command | Result |
|---|---|---|
| ASR pipeline | `skvoice-check wav Tests/.../hello.wav` | ✅ "Hello, world. This is a test of dictation." — 2.0 s audio in **0.16 s** |
| Sidecar refine (cold spawn) | `skvoice-check sidecar "let the team know the deploy is done…"` | ✅ "Deploy's complete — everything looks good on our end…" in **2.60 s** incl. spawn |
| Sidecar refine (warm) | smoke client, 2 requests | ✅ **2.04 s / 1.36 s**, context-aware ("Hey John — yes, still on for 3pm, but I'll be about 5 minutes late.") |
| Sidecar ping | smoke client | ✅ < 10 ms |
| App bundle build + codesign | `scripts/build-app.sh` | ✅ signed with Apple Development identity, `codesign --verify` OK |
| App launch | `open dist/SK Voice.app` | ✅ process runs, onboarding window renders (screenshot verified), menu bar item present, notification prompt shown |

## Blocked pending user action (cannot be automated — macOS TCC design)

These need one-time manual grants in System Settings, after which the onboarding
window turns green automatically:

1. **Microphone** — click Grant in onboarding.
2. **Accessibility** — required for paste-into-app and screen context. (`skvoice-check
   context` correctly returned empty text for the untrusted CLI — the graceful-degradation
   path works.)
3. **Input Monitoring** — required for the Fn event tap.
4. **Keyboard → "Press 🌐 key to" → Do Nothing** — so Fn doesn't also trigger the emoji
   picker/Apple dictation.

After granting: hold **Fn** and speak into any text field (dictation), hold **Fn+Ctrl**
(refine). First dictation may take ~1 s extra while the speech model warms.

## Bugs found & fixed during development

1. **Vocabulary re-matching** — shorter rules re-matched inside already-replaced text
   ("note" hit "Note Taker" output). Fixed with single-pass range claiming on the original
   string.
2. **Date round-trip precision** — epoch conversion lost sub-second bits in SQLite; fixed
   by storing `timeIntervalSinceReferenceDate`.
3. **Sidecar silent hang** — esbuild bundling of the Agent SDK broke its internal cli.js
   path discovery, so the CLI never spawned. Fixed with `--packages=external` +
   node_modules shipped in the app bundle.
4. **Stale-reader race** — after session recycle, the old SDK read loop could kill the new
   session's pending turn. Fixed with an active-reader guard.
5. **Unix socket path limit** — test sockets in deep temp dirs exceeded macOS's 104-byte
   `sun_path` cap (`listen EINVAL`); tests now use `/tmp` sockets. Production path
   `~/.skvoice/sidecar.sock` is well under the cap.
6. **CLI semaphore deadlock** — `DispatchSemaphore.wait()` on the main thread starved the
   async work in skvoice-check; rewrote with top-level `await`.
