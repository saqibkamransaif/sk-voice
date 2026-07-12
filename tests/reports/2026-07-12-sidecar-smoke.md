# Sidecar live smoke test — 2026-07-12

Environment: node v22.22.0, claude CLI 2.1.178 (subscription auth), sidecar dist build.

| Request | Latency | Response |
|---|---|---|
| ping | 0.00s | pong |
| refine "tell john i will be about five minutes late..." (context: "John: Hey, are we still on for 3pm?", app: Messages) | 2.04s | "Hey John — yes, still on for 3pm, but I'll be about 5 minutes late. Sorry about that!" |
| refine "ask sarah if she can review my pull request..." (no context, app: Slack) | 1.36s | "Hey Sarah — could you review my pull request when you get a chance? No rush!" |

Notes:
- Warm streaming-input session: one CLI process across turns; no per-request cold start.
- `settingSources: []` keeps user hooks/CLAUDE.md out of the drafting session (isolation + startup speed).
- esbuild must use `--packages=external`: bundling the SDK breaks its internal cli.js path resolution and the CLI never spawns (silent hang).
