# Pi SessionStart context compatibility

## Contract

Firstmate owns Pi startup-context parity in `.pi/extensions/fm-primary-session-context.ts`.
Pi loads this project extension only after project trust, or through an explicit `-e` path used for secondmate launches.
The extension runs supported CLI context producers in deterministic order with a 10-second timeout per command, bounded output, control-character cleanup, and per-command failure isolation.
It injects one hidden persistent model-context message per Pi session and does not reinject that message on `/reload`.
Session replacement creates a new extension instance and receives a fresh context message after the previous instance handles `session_shutdown`.
The context is guidance for Pi's built-in `bash` tool and does not register the CLIs as first-class Pi tools or MCP servers.
Codex MCP servers, plugins, skills, and built-in capabilities are separate from `~/.codex/hooks.json` and are not inherited by Pi.

## Compatibility matrix

| Component | Audited `origin/main` | Pi integration | Verified interface |
| --- | --- | --- | --- |
| `tasks-axi` | `78389b5b87ebf3db805a4e873fcd03f71a084e09` | Startup context | No-argument CLI through Pi `bash` |
| `quota-axi` | `187a9bc7b5125e68c9d3abab2e25ebb393e78ddf` | On demand | `quota-axi --help` through Pi `bash` |
| `lavish-axi` | `ab31405882f950696a2ddc79deb90d4caada7543` | Startup context | No-argument CLI through Pi `bash` |
| `chrome-devtools-axi` | `cc740e87c02590fdb63b235f2dc584801f514e8c` | Startup context | No-argument CLI and documented commands through Pi `bash` |
| `axi` | `d51c90b2efaed48eed9a6a9e876afc940571ec0c` | Shared runtime only | `axi-sdk-js` used by the named Node CLIs, with no `axi` executable |
| `gh-axi` | `e8533b554e3a64fdabc6090ac61507e6c654a914` | Startup context | No-argument CLI through Pi `bash` |
| `treehouse` | `81cc00172b3615cde67ff6fb0f99679a1274210e` | On demand | `treehouse --help` through Pi `bash` |

`quota-axi` deliberately has no SessionStart hook because its `origin/main` contract is read-only quota data requested on demand.
The shared `axi` repository is an SDK and specification repository rather than a user-facing executable.
Treehouse remains a separate lifecycle CLI governed by Firstmate's worktree safety rules.
No external tool repository required a compatibility patch for this integration.

## Evidence recorded 2026-07-12

The installed Pi version was `0.80.6`.
The remote audit command was `git -C <repo> ls-remote origin refs/heads/main` for every matrix row.
Local `origin/main` matched for `tasks-axi` and `quota-axi`.
Read-only temporary shallow clones of remote `main` were used for the other five repositories because their local remote-tracking refs were stale.
Each audit read the repository instructions, README, executable entrypoint, help and SessionStart contract, environment detection, and relevant tests from the audited commit.
The active Codex hook audit command was `jq '{SessionStart: [.hooks.SessionStart[]? | {matcher, hooks: [.hooks[]? | {type, command, timeout}]}]}' ~/.codex/hooks.json`.
That audit found 10-second no-argument SessionStart commands for `tasks-axi`, `gh-axi`, `lavish-axi`, and `chrome-devtools-axi`, plus an unrelated local Herdr state hook.
The pre-change isolated Pi probe used `PI_CODING_AGENT_DIR`, `FM_HOME`, `PI_OFFLINE=1`, `--approve`, `--no-session`, and explicit `-e` paths for the tracked Firstmate extensions.
The probe observed all four dynamic Codex hook payload signatures absent from the Pi model prompt while normal project context was present.
The post-change probe observed all four dynamic payload signatures in the model-visible injected context without launching the Codex harness or loading Codex hooks.
The exact post-change model response was `tasks yes,github yes,lavish yes,chrome yes,quota-role yes,axi-runtime-role yes,treehouse-role yes`.
`tests/fm-pi-session-context.test.sh` covers ordering, once-per-session injection, timeout and failure isolation, truncation, reload deduplication, session replacement, missing binaries, and current output headings.
`tests/fm-pi-primary-types.test.sh` covers strict TypeScript compatibility against the installed Pi package when `tsc` is installed.
The live interface checks were `tasks-axi`, `quota-axi --help`, `lavish-axi`, `chrome-devtools-axi`, `gh-axi`, and `treehouse --help` from the Pi environment.
The Pi model used its built-in `bash` tool for that combined interface check and returned `INTERFACES_OK` with no stderr.
The `axi` interface check was its audited root `package.json`, which has no `bin` entry, and `packages/axi-sdk-js`, which owns the shared SessionStart hook implementation.
