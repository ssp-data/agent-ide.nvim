# Hand-over: other agents (branch `acp`)

State of the other-agents work as of 2026-11-11, for whoever picks it up. The owner's focus is Claude Code on `dev`; this branch is parked on purpose: **not merged, not to be continued until the owner asks.** Rules and layout are in `AGENTS.md`; what was observed of each agent's protocol is in `docs/protocol-acp.md`; the plan with its re-baseline and the calls made is `docs/superpowers/plans/2026-11-10-part-6-other-agents.md`.

## Where things are

- Branch `acp` = `dev` as of 2026-11-11 (88a86b6) plus the other-agents work, with the merge conflicts already resolved at that point.
- `dev` has moved on since then (parked on 2026-11-11, `dev` at 1cad28d): the red and green lines in `Edit` folds (`AgentIdeDiffAdd`, `AgentIdeDiffDel`), the Omarchy widget jumping to a session's tmux pane, and a fix for the hand-off's `claude` lookup. A trial merge of `dev` into `acp` conflicts in `lua/agent-ide/transcript/live.lua`, `lua/agent-ide/transcript/render.lua` and `lua/agent-ide/ui/highlights.lua`. Both sides changed how folds are rendered, so resolve those by hand and keep both behaviours: the diff colours, and the agent-name heading on answers. CHANGELOG and README merged cleanly in that trial.
- `make test` on this branch: green, except that the budget case "cold Lua scan never blocks the UI longer than 16 ms" fails by about 1 ms while the machine is under load (it does so on old commits too; rerun when idle).
- `make test-real-acp` drives the real agents through the plugin's Session; it is not part of `make test`.

## What works

| Agent | State |
|---|---|
| Claude Code | unchanged; it is now the first adapter (`lua/agent-ide/agents/claude.lua`) |
| Gemini CLI (`gemini --acp`) | passed every real check on 2026-11-11: answer, allowed and denied edit, interrupt, park, log round trip, resume through `session/load` |
| opencode (`opencode acp`) | driven successfully during the protocol capture; the last real run was skipped because its provider was not logged in. The owner does not need it: `agents = { opencode = false }` removes it from the picker |
| Codex | **not wired up**, see below |

In the UI: `A` in the drawer and `:AgentsNew [agent]` start a session with a configured agent; rows read `gemini · <title>`; the chat header and the answer heading name the agent (`## Gemini`); mode, model and `/` commands follow what the agent offers; permission asks use the same never-interrupt flow; the plugin logs these sessions itself under `stdpath('state')/agent-ide/sessions/<agent>/`.

## Codex: install Zed's adapter first

The `codex` CLI (0.163) has no ACP mode; `codex app-server` speaks its own protocol. Other plugins (agentic.nvim, for one) run Codex through Zed's adapter **codex-acp**, a separate program:

```sh
npm i -g @zed-industries/codex-acp      # or pnpm add -g …, or a binary from
                                        # https://github.com/zed-industries/codex-acp/releases
```

Nothing was installed so far (the owner's go-ahead is needed for installs). Once `codex-acp` is on PATH:

```lua
agents = { codex = { kind = 'acp', cmd = { 'codex-acp' }, label = 'Codex' } }
```

Then, in this order: capture its protocol as was done for the others (add a section to `docs/protocol-acp.md`: capabilities, modes and models, permission options, what it calls on the client), add `codex` to `tests/real/acp.lua` and run `REAL_ACP_AGENTS=codex make test-real-acp`, fix what differs with a fake-based regression test, and only then make it a default entry in `config.lua` and the README table.

## Known limits and open items

- Other agents run as children of Neovim: no keepers, so they end when Neovim quits. Background sessions are Claude-only.
- A session belongs to the agent that started it; there is no way to continue a Claude session with another agent (each agent only loads its own conversations).
- `D` on another agent's row deletes nothing and names the plugin's log file; search does not index these sessions; the footer shows no quota for them.
- Gemini CLI refuses to work in a folder it does not trust and, in ACP mode, says so only on its error output. A turn that hears nothing for 30 s now adds a line to the transcript with that output. On 2026-11-11 Gemini's own CLI also stopped answering altogether for a while (service or quota), which looks the same from the plugin: check with `gemini -p "say pong"` in a shell first.
- Not observed, so not handled beyond showing the agent's error: an agent that is not logged in; `plan` and `current_mode_update` updates; opencode asking for permissions through ACP.
- Client-side terminal methods are declined; file reads and writes for the agent are limited to the session's folder (`fs = 'cwd'`).

## If this branch is taken up again

1. Rebase or merge `dev` in first; run `make test` when the machine is idle.
2. Codex, as above, if the owner wants it.
3. Keepers for ACP agents (the keeper is a dumb pipe owner, so it should fit; the replay needs the adapter's translator instead of Claude's decoder).
4. Search over the plugin's own session logs.
