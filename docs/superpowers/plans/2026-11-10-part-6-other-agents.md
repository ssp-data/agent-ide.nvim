# Agent-IDE.nvim Part 6: Other Agents (Gemini CLI, opencode; Codex when it speaks ACP) — Implementation Plan

> **Status: being built on branch `acp`** (re-baselined on 2026-11-10 against `dev` at ef2ea4c "keepers"; Task 0 below records what changed). Nothing of it is merged into `dev` or `main` until the owner says so.
>
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Chat with Gemini CLI and opencode (and Codex once an ACP adapter for it exists) from the same drawer, chat view, prompt buffer, permission flow and status footer that Claude Code uses, without changing how Claude Code sessions work.

**Architecture:** Today the Session object talks to Claude through two modules: a process wrapper (`claude/process.lua`, which starts Claude under a keeper or as a child) and a stream decoder (`claude/stream.lua`) that produces a fixed set of Actions handled in `session/actions.lua`. This plan puts a small adapter interface between Session and "whatever runs the agent". The existing Claude path becomes the first adapter, unchanged in behaviour. A second adapter speaks the Agent Client Protocol (ACP: JSON-RPC 2.0 over stdio) and translates ACP messages into the same Actions. Because ACP agents keep their own history in their own formats, the plugin records every session it runs through ACP in its own event log, so the drawer and history view work without asking the agent.

**Tech Stack:** Lua (Neovim 0.12, `vim.system`), mini.test, a scriptable fake ACP agent for tests (same idea as `tests/fake_claude.lua`).

**Spec:** `docs/superpowers/specs/2026-11-10-agents-ide-design.md` section 10 ("Other agents"), plus sections 4, 8 and 9 (deal-breakers: fidelity, speed), 7.8 (never interrupt); `docs/superpowers/specs/2026-11-10-keeper-design.md` for how Claude runs now.

**Written against:** branch `dev` at ef2ea4c ("feat: keepers: Claude sessions outlive Neovim, a new Neovim reattaches"). The original text was written against `full-build` after chat tasks 1–9; Task 0 re-baselined it. Where this plan and the code disagree about an existing interface, the code wins.

## Global Constraints

- Everything in the Global Constraints of the part 1 and part 2 plans and in `AGENTS.md` still holds (module `agent-ide`, no runtime Lua dependencies, synthetic fixtures only, nothing from the user's real sessions in the repo, never change the global working directory, never stop a process the plugin did not start, nothing blocking on the UI thread, never interrupt typing, writes only in the plugin's own folders).
- **Claude Code behaviour must not change.** Every existing test stays green without edits to its assertions, except tests that name moved modules. `make test-real` (real Claude end-to-end) passes before and after.
- **No feature is faked.** A capability an agent does not offer through ACP (model switching, modes, slash commands, resume, quota, the tmux hand-over to a native screen) is absent or greyed in that session's UI, with one line in `g?` help saying why. Never show a control that does nothing.
- **Billing stays the user's choice per agent.** The plugin starts each agent with the user's own login/configuration for that agent and never injects or strips API keys for ACP agents unless a per-agent setting says so. (The Claude adapter keeps its `strip_api_key` rule.)
- Real agents are used only in the capture task and the final real-agent check, with the cheapest model each agent offers, in a temporary git repository outside this one.
- Fidelity: every ACP message is either translated to an Action/Event or shown as an `unknown` fold with its raw JSON. The raw view shows ACP traffic exactly as sent and received.

## What is known (verified on the owner's machine, 2026-11-10)

- `gemini` 0.65.0: `gemini --acp` "Starts the agent in ACP mode" (`--experimental-acp` is deprecated).
- `opencode` v2.2.7: `opencode acp` "Start an Agent Client Protocol server" (`--login` runs auth login instead).
- `codex` 0.163.0: **no ACP mode.** It has `codex app-server` (its own JSON-RPC protocol, not ACP); no `codex-acp` binary is on PATH. Codex is "not supportable yet" until an ACP adapter for it is installed; nothing is installed by this plan.
- `pi` is installed but prints nothing about ACP in its help; it is out of scope.
- ACP (as documented upstream, verified in Task 1): JSON-RPC 2.0, one object per line over stdio. The client sends `initialize` (protocol version, client capabilities: `fs.readTextFile`, `fs.writeTextFile`, `terminal`), optionally `authenticate`, then `session/new` (`cwd`, `mcpServers`) or `session/load` (`sessionId`), then `session/prompt` (`sessionId`, `prompt` content blocks); the request stays open until the turn ends and returns `stopReason` (`end_turn`, `cancelled`, `refusal`, `max_tokens`, ...). The agent streams `session/update` notifications (`agent_message_chunk`, `agent_thought_chunk`, `user_message_chunk`, `tool_call`, `tool_call_update`, `plan`, `available_commands_update`, `current_mode_update`) and sends requests to the client: `session/request_permission` (with `options[]` of `kind` `allow_once|allow_always|reject_once|reject_always`), `fs/read_text_file`, `fs/write_text_file`, `terminal/*`. `session/cancel` is a notification that interrupts; `session/set_mode` switches the mode. Exact field names per agent are recorded in `docs/protocol-acp.md` by Task 1.

## Decisions taken in the re-baseline (Task 0)

1. **ACP agents run as direct children of Neovim, not under a keeper.** The keeper (`keeper/main.lua`, `keeper/state.lua`) is a dumb pipe owner by design, but what little it interprets is Claude's wire: a `user` line means busy, `control_request/can_use_tool` means waiting, `result` ends a turn and lets the keeper send the next queued prompt in Claude's `{type="user"}` shape. For ACP the prompt is a JSON-RPC *request* whose id the Neovim side allocates, the turn ends with that request's *response*, and the agent's own session id (from `session/new`) must be recovered from a replay. Teaching the keeper a second protocol is more than this round needs to show that other agents work; the adapter handle has the same interface for both, so a keeper for ACP can be added later without touching Session. Consequence: quitting Neovim stops an ACP agent (the quit guard asks when it is working, as it did for Claude before keepers), and its session resumes through `session/load` where the agent supports it, else as a new agent session with the history from the plugin's log.
2. Client-side file access defaults to the session's working directory tree (`fs = 'cwd'`); `'any'` and `false` are settings. Terminal methods are declined (`terminal` capability false in `initialize`; a call is answered with "method not found").
3. `replay_context` is off by default and stays a per-agent setting.
4. No Codex adapter is installed; Codex gets a config example only, marked unsupported in the docs until an ACP adapter exists.

## Review Focus

1. **An agent that requires client-side file or terminal methods the plugin declined** stalls or fails: the session shows a clear error naming the missing capability, not a hang. → Task 4.
2. **An ACP agent exits or the JSON-RPC stream breaks mid-turn:** partial text is kept, an error line is added, state returns to idle or failed, the next prompt starts a new process and, where the agent supports it, loads the same session. → Task 4, Task 5.
3. **Permission request arrives while the user types elsewhere:** same never-interrupt behaviour as Claude sessions, through the same code path. → Task 6.
4. **Two agents in one project, same drawer:** rows are unambiguous (agent name shown), opening one never sends to the other, status counts include both. → Task 7.
5. **A session started through ACP is reopened after Neovim restarts** when the agent cannot load it: history still shows from the plugin's own log, and sending explains that a new agent session will be started with no memory of the old one (and can paste the previous conversation as context — off by default). → Task 5, Task 7.

## File Structure

```
lua/agent-ide/agents/init.lua          registry: name -> adapter; reads config.agents; default_agent
lua/agent-ide/agents/claude.lua        adapter wrapping today's claude/process + claude/stream (+ keeper attach)
lua/agent-ide/agents/acp/client.lua    JSON-RPC 2.0 over stdio: requests, responses, notifications
lua/agent-ide/agents/acp/translate.lua pure: ACP updates/requests -> Actions (per-turn state)
lua/agent-ide/agents/acp/adapter.lua   start/handshake, handle (prompt, cancel, answer, modes), client-side methods
lua/agent-ide/agents/acp/fs.lua        client file read/write handlers (scoped to the working directory)
lua/agent-ide/agents/log.lua           plugin-owned event log for sessions without a readable transcript
tests/fake_acp.lua                     scriptable fake ACP agent (run with `nvim -l`)
tests/acp.lua                          test helper: writes a scenario, returns the cmd and log path (as tests/fake.lua)
tests/test_agents.lua, test_acp_client.lua, test_acp_adapter.lua, test_agent_log.lua, test_agent_ui.lua
tests/real/acp.lua                     real-agent check (`make test-real-acp`, not part of `make test`)
docs/protocol-acp.md                   observed ACP shapes per agent (field names only)
```
Modified: `lua/agent-ide/session/` (use an adapter instead of calling `claude/process` and `claude/stream` directly), `lua/agent-ide/config.lua`, `lua/agent-ide/ui/drawer.lua`, `drawer_model.lua` and `tree.lua` (agent label, agent picker, sessions from the log), `lua/agent-ide/ui/chat*.lua`, `mode.lua`, `permission.lua`, `prompt.lua` (capability-driven controls and wording), `lua/agent-ide/status.lua`, `lua/agent-ide/index/init.lua` (merge logged sessions into the scan), `plugin/agent-ide.lua` (`:AgentsNew`), `README.md`, `CHANGELOG.md`, `AGENTS.md`.

## Shared Types (as the code has them now)

**Session fields that exist today and matter here:** `id` (the plugin's UUID), `cwd`, `path` (transcript file; for ACP the log file), `title`, `state` (`idle|busy|waiting|done|failed|parked`), `events`, `streaming`, `turn_start`, `pending_permissions[] { request_id, tool_name, input, description, suggestions }`, `queue`, `raw[] { dir, line }`, `raw_dropped`, `unread`, `owned`, `visible`, `proc` (the handle), `requests` (Claude: control requests in flight), `deferred` (settings sent at the next start), `model`, `models`, `mode`, `mode_requested`, `model_requested`, `model_chosen`, `slash_commands`, `sent_before`, `parking`, `park_cbs`, `attaching`, `replaying`, `pid`, `loaded_key`, `echo_expected`, `interrupted`.

**New Session fields:** `agent` (string, `'claude'` default), `adapter` (the adapter), `capabilities` (table, copied from the adapter at open and refined at start), `agent_session_id` (ACP: the agent's own id), `log` (ACP: the open event log).

**Adapter** (what Session needs from any agent):

| member | meaning |
|---|---|
| `name` | `'claude'`, `'gemini'`, `'opencode'`, or a user-defined name |
| `label` | what the UI calls it (`Claude`, `Gemini`, `opencode`, …) |
| `capabilities` | booleans: `resume`, `modes`, `models`, `commands`, `interrupt`, `quota`, `images`, `native` (tmux hand-over), `live` (`claude agents` / keepers apply), `transcript` (history is Claude's file); refined per session after start |
| `start(s, sink) -> handle, err` | starts the process for Session `s`; `sink.action(a)` receives Actions (the part 2 Action table) in order, `sink.raw(dir, line)` every wire line, `sink.garbage(line)` a non-JSON line, `sink.exit(code, tail)` once, `sink.pid(pid)` when known |
| `handle:prompt(text) -> boolean` | send one user prompt (Claude: the `user` line; ACP: a `session/prompt` request) |
| `handle:interrupt() -> boolean` | stop the current turn |
| `handle:answer(p, allow, opts) -> boolean` | answer the pending ask `p` (as stored in `pending_permissions`) |
| `handle:set_mode(mode)`, `handle:set_model(model)` | only called when the capability is true |
| `handle:send(obj)` | Claude only: one raw object (tests use `Session:_write`) |
| `handle:stop(cb, now)`, `handle:alive()`, `handle.pid`, `handle.keeper` | as `claude/process` today |
| `history(s, cb)` | events for a past session: Claude reads the transcript file (today's `Session:load` body); ACP reads the plugin's log |
| `attach(s, cb)` | Claude only: reattach to a keeper (today's `session/attach.lua`) |
| `confirm_stop_text` | the park question (`Claude is still working…`) |

**Action** gains nothing new. ACP specifics map onto existing types: `agent_message_chunk` → `delta` then one `event{text}` when the turn (or a tool call) ends the block; `agent_thought_chunk` → one `event{thinking}`; `tool_call` + `tool_call_update` → one `event{tool_call}` (when first seen) and one `event{tool_result}` (when `status` is `completed` or `failed`, with the final content); `plan` → `event{meta, label "plan"}`; `session/request_permission` → `permission{request_id, tool_name, input, description, suggestions = the agent's options}`; `available_commands_update` → `init`-style `commands{slash_commands}`; `current_mode_update` → `status{mode}`; the `session/prompt` response → `result{is_error = stopReason not in (end_turn, cancelled), text}`; `session/new` → `init{session_id, model, mode, slash_commands = {}}`; anything else → `unknown`.

**SessionMeta** gains `agent` (string; absent or `'claude'` for all existing sessions) and `agent_session_id`.

---

### Task 0: Re-baseline

- [x] Read `lua/agent-ide/session/{init,object,actions,attach}.lua`, `lua/agent-ide/claude/{process,stream,version}.lua`, `lua/agent-ide/keeper/`, `lua/agent-ide/ui/{chat,chat_keys,mode,permission,drawer_model,tree,drawer,prompt}.lua`, `lua/agent-ide/status.lua`, `lua/agent-ide/index/`, `docs/protocol.md`, the keeper design. Every place Session (and the UI it feeds) reaches into Claude-specific modules or wire shapes:
  - `session/object.lua`: requires `claude.process` and `claude.stream`; `_start_process` (argv, keeper, `initialize` as the first line, `claude.version.check`, deferred settings); `_control` (ids `r<n>`/`i<n>`, `s.requests`); `_start_turn` writes the `user` line; `interrupt`, `set_mode`, `set_model` send control requests; `answer` writes `control_response` (`behavior`, `updatedInput`, `updatedPermissions`); `park` asks "Claude is still working"; `needs_start`, `_elsewhere`, `attach` consult keepers and the `claude agents` map; `load` reads the transcript through `index.history`.
  - `session/actions.lua`: `control_ok`/`control_error` by `s.requests` (initialize → `claude.models`, set_model, set_permission_mode); `init` records prefs and `session/commands`; `echo`; `on_exit` says "Claude exited".
  - `session/attach.lua`: keeper replay through `claude.process` and `claude.stream`.
  - `session/init.lua`: `_reset` resets `claude.models`.
  - `ui/mode.lua`: `claude.models`, `claude.models_fetch`, `claude.version`, `config.claude.modes/default_mode/models`. `ui/chat.lua`: live check through `live.query` before a start, hand-over (`ui/handoff.lua`, `claude --resume`), "running in another Claude". `ui/chat_keys.lua`: help texts, mode/model/native keys mapped unconditionally. `ui/permission.lua`: "Claude wants to use", Claude's suggestion shapes, `AskUserQuestion`/`ExitPlanMode`. `ui/prompt.lua`: `/` menu from `s.slash_commands`, `commands.json`, skills on disk; `/model`. `ui/tree.lua`: "No Claude sessions found". `status.lua`: session rows without an agent; quota from Claude's windows. `index/`: scans `projects_dir` only. `keeper/state.lua`: Claude's wire. `prefs.start_model`: `config.claude.model`. `ui/quit_guard.lua`: `s.proc.keeper`.
- [x] Update this plan's Adapter table and task text where reality differs (above and below). Commit the updated plan before any code.

### Task 1: Capture ACP from the real agents

**Files:** create `docs/protocol-acp.md`; scratch captures stay outside the repo.

- [ ] For Gemini CLI and opencode: with a small driver script in a temporary git repository (outside this repo), run: initialize and capability exchange; new session; a plain prompt; a prompt that makes the agent edit a file (permission ask: allow once, deny once); cancel during a long answer; a second prompt in the same session; restart the process and try to load the session; a mode change if offered; whatever the agent uses for slash commands. Use the cheapest model. If an agent needs authentication that is not set up, note it and move on; never store credentials.
- [ ] Record per agent in `docs/protocol-acp.md`: start command, protocol version, capability flags, the method and notification names seen, the fields that matter for each (placeholders for values), which client-side methods the agent calls and what happens when the client declines them, how errors and auth problems look, and an "Open questions" list. No real ids, paths or content. Record Codex as not supportable yet (no ACP mode in 0.163.0) and `pi` as out of scope.
- [ ] Decide and write down, per agent: supported in this plan / supported with stated limits / not supportable yet, with the reason. **If neither Gemini nor opencode works acceptably, stop here and report.**

### Task 2: Adapter interface and Claude adapter (pure refactor)

**Files:** create `lua/agent-ide/agents/init.lua`, `lua/agent-ide/agents/claude.lua`; modify `lua/agent-ide/session/{object,actions,attach,init}.lua`; test `tests/test_agents.lua`.

- [ ] Failing tests: `agents.get('claude')` returns an adapter named `claude` with every capability true (except `images`); `agents.get('nope')` returns nil and a clear error string; a Session opened without `agent` has `agent = 'claude'` and the Claude adapter; against the fake Claude the session produces the same events, raw lines and sent lines as before (the existing `tests/test_session.lua` is the golden: it must pass untouched).
- [ ] Move what `Session` does with `claude/process`, `claude/stream` and Claude's wire into `agents/claude.lua`: `start(s, sink)` (today's `_start_process` body, returning a handle that wraps the process or the keeper client and implements `prompt`, `interrupt`, `answer`, `set_mode`, `set_model` on top of `Session:_write`), `history(s, cb)` (today's `load` body), `attach(s, cb)` (calls `session/attach.lua`, which wraps the keeper client in the same handle). `Session:_write(obj)` stays (records the raw line; tests use it). `s.requests`, the `r<n>`/`i<n>` counters and `_bump_ids` stay where they are (the Claude adapter and `actions.lua` use them; they are inert for other agents). Sessions carry `agent` (default `'claude'`), `adapter`, `capabilities`.
- [ ] No behaviour change: whole suite green with no assertion edits. `make test-real` green.
- [ ] Commit `refactor: agent adapter interface with Claude as first adapter`.

### Task 3: JSON-RPC client and fake ACP agent

**Files:** create `lua/agent-ide/agents/acp/client.lua`, `tests/fake_acp.lua`, `tests/acp.lua`; test `tests/test_acp_client.lua`.

**Interfaces:** `client.start(cmd, opts) -> c, err` (`opts`: `cwd`, `env`, `on_raw(dir, line)`, `on_garbage(line)`, `on_exit(code, signal, stderr_tail)`, `timeout_ms` default 60 000 for requests that have no own timeout); `c:request(method, params, cb(err, result), timeout_ms|false)` (`false`: no timeout; the prompt request stays open for a whole turn); `c:notify(method, params)`; `c:on_request(method, fn(params, respond(result, err)))`; `c:on_notification(method, fn(params))`; `c:on_unhandled(fn(msg))`; `c:stop(cb, now)`; `c:alive()`; `c.pid`.

- [ ] Fake (`tests/fake_acp.lua`, run with `nvim -l`, scenario of JSON lines as `fake_claude.lua`): `expect` (a substring; remembers the id of the request matched), `respond` (result to that id), `respond_error`, `update` (a `session/update` notification with the session id the fake gave), `request` (an agent→client request; blocks until its response arrives and logs it), `emit`, `emit_raw`, `sleep_ms`, `exit`, `ignore_stdin`; env `FAKE_ACP_LOG` logs argv, cwd and every input line. `tests/acp.lua` writes scenarios and reads the log.
- [ ] Failing tests against the fake: request/response matched by id out of order; a notification; an agent→client request answered; a JSON-RPC error response surfaces as `err`; an unknown method from the agent gets a "method not found" (-32601) error response and reaches `on_unhandled`; an unknown notification reaches `on_unhandled`; a malformed line is reported (`on_garbage`) and skipped; request timeout; process exit fails all pending requests exactly once (`err.code = 'exit'`); no process left behind after `stop`.
- [ ] Implement with the shared line splitter (`lua/agent-ide/util/lines.lua`) and the stop/SIGTERM pattern of `claude/process.lua`. All callbacks on the main loop, in arrival order.
- [ ] Commit `feat: JSON-RPC client and scriptable fake ACP agent`.

### Task 4: ACP adapter

**Files:** create `lua/agent-ide/agents/acp/translate.lua`, `lua/agent-ide/agents/acp/adapter.lua`, `lua/agent-ide/agents/acp/fs.lua`; modify `lua/agent-ide/config.lua`, `lua/agent-ide/agents/init.lua`; test `tests/test_acp_adapter.lua`.

Config:

```lua
agents = {
  claude   = { },                                            -- built in, the Claude adapter
  gemini   = { kind = 'acp', cmd = { 'gemini', '--acp' }, fs = 'cwd', replay_context = false },
  opencode = { kind = 'acp', cmd = { 'opencode', 'acp' }, fs = 'cwd', replay_context = false },
  -- codex: no ACP mode in codex 0.163.0; add { kind = 'acp', cmd = { '<an ACP adapter for Codex>' } } once one exists
},
default_agent = 'claude',
```
Users can add any ACP agent by name with `kind = 'acp'` and a `cmd`; `env` (a table) adds variables, `fs = 'cwd' | 'any' | false`, `replay_context = true` pastes the earlier conversation into a new agent session.

- [ ] Failing tests against the fake ACP agent, using synthetic scenarios shaped like Task 1's captures: start performs initialize → (authenticate when `authMethods` is non-empty and the agent refuses `session/new` with the auth error: then the error is shown, not retried) → `session/new`, and fills `capabilities` from the agent's flags (`loadSession` → `resume`; `modes` present → `modes`; `models` present → `models`); message chunks become `delta`s and one `text` event equal to their concatenation; thought chunks become one `thinking` event; a tool call with later updates becomes one `tool_call` event and one `tool_result` event with the final content (intermediate updates do not create extra events); `diff`-type tool content renders as an `Edit`-like tool call (`file_path`, `old_string`, `new_string`) so the existing fold body rules apply; a plan becomes a `meta` event; a permission request becomes a `permission` action and `answer` sends the option id the agent offered for allow/deny (`allow_once`-like and `reject_once`-like kinds map to Allow/Deny; other options pass through as extra choices with the agent's labels); `interrupt` sends `session/cancel` and the turn ends idle with the prompt response; the prompt response ends the turn with a `result` action (`is_error` from the stop reason); an unknown update type becomes `unknown` with raw JSON; a client-side method the plugin does not implement is declined with a proper error and, if the agent then fails the turn, the error text names the method (Review Focus 1); process exit mid-turn yields the `exit` path (Review Focus 2).
- [ ] Client-side file methods (`fs/read_text_file`, `fs/write_text_file`): implemented, scoped to the session's working directory tree unless `fs = 'any'`; a write outside the scope or with `fs = false` is refused with an error the agent sees. Terminal methods are declined (capability false; "method not found").
- [ ] Commit `feat: ACP adapter translating to the shared action model`.

### Task 5: Plugin-owned session log and history

**Files:** create `lua/agent-ide/agents/log.lua`; modify `lua/agent-ide/index/init.lua`, `lua/agent-ide/session/{init,object}.lua`, `lua/agent-ide/agents/acp/adapter.lua`; test `tests/test_agent_log.lua`.

- [ ] Sessions run through an ACP adapter append their Events (the stored form, without `live_only` ones) as JSON lines to `stdpath('state')/agent-ide/sessions/<agent>/<session id>.jsonl` (0600 in 0700 folders), with a first line `{ "version": 1, "agent", "id", "cwd", "title", "created" }` and, once known, a line `{ "agent_session_id": "…" }` (lines without `kind` are header lines, merged in order). Writes are asynchronous and ordered (one write chain per file); a crash loses at most the last event.
- [ ] `adapter.history` for ACP reads that file (`load` keeps the mtime/size key so an unchanged file is not read again). `index.scan` merges these sessions into its result with `agent`, `agent_session_id`, `path` (the log), `cwd`, `title` (the header's, else the first prompt, else `(untitled)`), `activity` (the file's mtime); `session.open` takes `agent` and `agent_session_id`. The drawer's rows open them through the ACP adapter.
- [ ] Resume: on send to a parked ACP session, start the agent and call `session/load` with `agent_session_id` when `capabilities.resume`; otherwise (or when the load fails) start a new agent session, add a visible `meta` event `New <agent> session: the agent cannot reload the earlier conversation`, and continue in the same transcript (Review Focus 5). `agents.<name>.replay_context = true` sends the earlier conversation as a preamble of the next prompt; off by default because it costs tokens and changes what the agent sees.
- [ ] Tests: log round trip equals the live events (history equals live for ACP sessions); merge into scan; both resume paths; a corrupt last line is skipped.
- [ ] Commit `feat: event log and history for agents without a readable transcript`.

### Task 6: Session and chat UI driven by capabilities

**Files:** modify `lua/agent-ide/session/object.lua`, `lua/agent-ide/ui/{chat,chat_keys,mode,permission,prompt}.lua`, `lua/agent-ide/status.lua`; test `tests/test_agent_ui.lua`.

- [ ] Session uses `s.adapter`; nothing in Session or the UI names Claude outside the Claude adapter, `claude/`, the version notice and the Claude-only texts guarded by `s.agent == 'claude'` (hand-over, "another Claude").
- [ ] Controls follow `s.capabilities`: the mode key, the model picker (and `/model`), the native hand-over are active only when supported; otherwise the key shows a one-line notice `Agent-IDE: <agent> does not offer <feature> through ACP`. The `/` menu lists the agent's commands when it reported some (and the plugin's `/copy`; `/model` only with `models`). `g?` help lists the features the current session's agent does not offer.
- [ ] Winbar starts with the agent's label for non-Claude sessions. The permission picker says `<Agent> wants to use …`. The pre-send live check (`claude agents`) and the keeper paths run only when `capabilities.live`. Status levels and the status file count sessions of every agent; the status file's session rows gain `agent`. Footer quota shows only when the focused session's agent reports it (`capabilities.quota`).
- [ ] Permission asks from ACP sessions go through the existing never-interrupt flow unchanged (Review Focus 3): a test with an ACP session as the asking session, typing in the prompt, no popup; the answer key opens it.
- [ ] Commit `feat: capability-driven chat controls for any agent`.

### Task 7: Drawer: choosing an agent, labelling sessions

**Files:** modify `lua/agent-ide/ui/{tree,drawer,drawer_model,drawer_legend}.lua`, `lua/agent-ide/config.lua`, `plugin/agent-ide.lua`; test `tests/test_tree.lua`, `tests/test_agent_ui.lua`.

- [ ] `+ New session` uses `default_agent`. `keys.drawer.agent` (default `A`) on that row, and `:AgentsNew <agent>`, pick a configured agent (`vim.ui.select`); agents whose command is not on `PATH` are listed as unavailable and cannot be picked.
- [ ] Session rows of non-Claude agents show a short agent tag before the title (`gemini · <title>`, highlight `AgentIdeAgent`). With only Claude configured or used, the drawer looks exactly as before (the existing tree fixtures assert unchanged lines).
- [ ] Search does not index the plugin's logs yet: noted as a follow-up in the README.
- [ ] Review Focus 4 test: two agents in one project, both rows labelled, each chat sends to its own process, the status file lists both with their `agent`.
- [ ] Commit `feat: start sessions with any configured agent from the drawer`.

### Task 8: Real-agent check and docs

**Files:** create `tests/real/acp.lua` (`make test-real-acp`, not part of `make test`); modify `README.md`, `AGENTS.md`, `CHANGELOG.md`, `docs/protocol-acp.md`.

- [ ] For each agent marked supported in Task 1: in a temporary git repository with its cheapest model, through the real plugin headless: a plain answer renders; an edit asks permission and allow applies it; deny leaves the file; interrupt ends the turn and a new prompt works; park and reopen (load or the documented new-session notice); history equals live from the plugin's log; raw view shows the JSON-RPC traffic. Print pass/fail per check and per agent, no content.
- [ ] Fix failures in the owning module with a fake-based regression test. Update `docs/protocol-acp.md` where reality differed.
- [ ] README: an "Other agents" section with a per-agent table of what works and what does not (resume, modes, models, commands, quota, background), how to add another ACP agent, the billing note, the privacy row for the log folder; the configuration block; AGENTS.md layout and rules; CHANGELOG.
- [ ] Whole suite, `make test-helper`, `make test-real` (Claude) and `make test-real-acp` pass.
- [ ] Commit `feat: real-agent checks and documentation for ACP agents`.

## Not in this plan

- Listing sessions that were started outside the plugin in Gemini CLI, opencode or Codex (each has its own storage; the drawer shows only sessions the plugin ran). A later, per-agent reader could add them.
- Keepers (background sessions) for ACP agents; live state of non-Claude sessions running in terminals.
- The `pi` agent (no ACP mode found).
- Images and other non-text prompt content; `@file` mentions are sent as plain text to ACP agents (the agent reads files through `fs/read_text_file` if it wants them).
- Search over the plugin's own session logs.

## Decided without the owner (the owner was not available; see "Decisions taken in the re-baseline")

1. No Codex ACP adapter is installed; Codex is documented as not supportable yet.
2. Client-side file access defaults to the working directory only.
3. `replay_context` stays off by default.
4. ACP agents run as children of Neovim, not under keepers, in this round.
