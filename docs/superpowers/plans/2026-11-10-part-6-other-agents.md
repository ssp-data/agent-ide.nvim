# Agent-IDE.nvim Part 6: Other Agents (Codex, Gemini CLI, opencode) — Implementation Plan

> **Status: deferred on purpose.** The user wants to use and improve the Claude Code experience first. Nothing in this plan is to be built until they say so. It is written now so the work can be picked up at any time.
>
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Chat with Codex, Gemini CLI and opencode from the same drawer, chat view, prompt buffer, permission flow and status footer that Claude Code uses, without changing how Claude Code sessions work.

**Architecture:** Today the Session object talks to Claude through two modules: a process wrapper and a stream decoder that produces a fixed set of Actions. This plan puts a small adapter interface between Session and "whatever runs the agent". The existing Claude path becomes the first adapter, unchanged in behaviour. A second adapter speaks the Agent Client Protocol (ACP: JSON-RPC 2.0 over stdio) and translates ACP messages into the same Actions. Because ACP agents keep their own history in their own formats, the plugin records every session it runs through ACP in its own event log, so the drawer and history view work without asking the agent.

**Tech Stack:** Lua (Neovim 0.12, `vim.system`), mini.test, a scriptable fake ACP agent for tests (same idea as `tests/fake_claude.lua`).

**Spec:** `docs/superpowers/specs/2026-11-10-agents-ide-design.md` section 10 ("Other agents"), plus sections 4, 8 and 9 (deal-breakers: fidelity, speed), 7.8 (never interrupt).

**Written against:** branch `full-build` at the point where chat tasks 1–9 of `docs/superpowers/plans/2026-11-10-part-2-chat.md` were complete. **Before starting, re-read the modules named below; names may have moved.** Where this plan and the code disagree about an existing interface, the code wins and this plan's task text is adjusted first (Task 0).

## Global Constraints

- Everything in the Global Constraints of the part 1 and part 2 plans still holds (module `agent-ide`, no runtime Lua dependencies, synthetic fixtures only, nothing from the user's real sessions in the repo, never change the global working directory, never stop a process the plugin did not start, nothing blocking on the UI thread, never interrupt typing).
- **Claude Code behaviour must not change.** Every existing test stays green without edits to its assertions, except tests that name moved modules. `make test-real` (real Claude end-to-end, if present) passes before and after.
- **No feature is faked.** A capability an agent does not offer through ACP (model switching, modes, slash commands, resume, quota) is absent or greyed in that session's UI, with one line in `?` help saying why. Never show a control that does nothing.
- **Billing stays the user's choice per agent.** The plugin starts each agent with the user's own login/configuration for that agent and never injects or strips API keys for ACP agents unless a per-agent setting says so. (The Claude adapter keeps its `strip_api_key` rule.)
- Real agents are used only in the capture task and the final real-agent check, with the cheapest model each agent offers, in a temporary git repository.
- Fidelity: every ACP message is either translated to an Action/Event or shown as an `unknown` fold with its raw JSON. The raw view shows ACP traffic exactly as sent and received.

## What is known and what is not

Known from the design work so far:
- All three CLIs are installed on the user's machine (`codex`, `gemini`, `opencode`; also `pi`).
- ACP is JSON-RPC 2.0 over stdio. In broad strokes: the client sends `initialize`, optionally `authenticate`, then `session/new` (with a working directory) or `session/load`, then `session/prompt`; the agent streams `session/update` notifications (message chunks, thought chunks, tool calls and their updates, plans, available commands, mode changes) and may send requests to the client such as `session/request_permission`, file read/write, and terminal operations; `session/cancel` interrupts.

**Not verified. Task 1 exists to verify all of it against the installed versions, and nothing after Task 1 may assume it:**
- The exact command that starts each agent in ACP mode (believed: `gemini --experimental-acp`; `opencode acp`; Codex through a separate adapter binary such as `codex-acp`, which may need installing).
- Method names, field names and capability flags for the protocol version each agent speaks; which optional parts each implements (`session/load`, modes, model selection, commands, images).
- Whether the client must implement file-system and terminal methods for the agent to function, or may decline them at `initialize`.
- How each agent reports usage/quota, if at all.
- How authentication behaves when the user is already logged in through the CLI.

## Review Focus

1. **An agent that requires client-side file or terminal methods the plugin declined** stalls or fails: the session shows a clear error naming the missing capability, not a hang. → Task 4.
2. **An ACP agent exits or the JSON-RPC stream breaks mid-turn:** partial text is kept, an error line is added, state returns to idle or failed, the next prompt starts a new process and, where the agent supports it, loads the same session. → Task 4, Task 5.
3. **Permission request arrives while the user types elsewhere:** same never-interrupt behaviour as Claude sessions, through the same code path. → Task 6.
4. **Two agents in one project, same drawer:** rows are unambiguous (agent name shown), opening one never sends to the other, status counts include both. → Task 7.
5. **A session started through ACP is reopened after Neovim restarts** when the agent cannot load it: history still shows from the plugin's own log, and sending explains that a new agent session will be started with no memory of the old one (and offers to paste the previous conversation as context — off by default). → Task 5, Task 7.

## File Structure

```
lua/agent-ide/agents/init.lua        registry: name -> adapter; config.agents
lua/agent-ide/agents/claude.lua      adapter wrapping today's claude/process + claude/stream
lua/agent-ide/agents/acp/client.lua  JSON-RPC 2.0 over stdio: requests, responses, notifications
lua/agent-ide/agents/acp/adapter.lua ACP messages <-> Actions; client-side methods
lua/agent-ide/agents/acp/fs.lua      optional client file read/write handlers
lua/agent-ide/agents/log.lua         plugin-owned event log for sessions without a readable transcript
tests/fake_acp.lua                   scriptable fake ACP agent (run with `nvim -l`)
tests/fixtures/acp/*.jsonl           synthetic ACP scenarios
docs/protocol-acp.md                 observed ACP shapes per agent (field names only)
```
Modified: `lua/agent-ide/session/` (use an adapter instead of calling `claude/process` and `claude/stream` directly), `lua/agent-ide/config.lua`, `lua/agent-ide/ui/drawer_model.lua` and `tree.lua` (agent label, sessions from the log), `lua/agent-ide/ui/chat*.lua` and `mode.lua` (capability-driven controls), `lua/agent-ide/index/` (merge logged sessions into the scan), `README.md`.

## Shared Types (additions)

**Adapter** (what Session needs from any agent):

| member | meaning |
|---|---|
| `name` | `'claude'`, `'codex'`, `'gemini'`, `'opencode'`, or a user-defined name |
| `capabilities` | table of booleans, filled after start: `resume`, `modes`, `models`, `commands`, `interrupt`, `quota`, `images` |
| `start(opts, sink) -> handle` | `opts`: `cwd`, `session_id` (nil for new), `model`, `mode`; `sink(action, raw)` receives Actions (the part 2 Action table) in order; `sink` also receives `{ type = 'exit', code, stderr_tail }` |
| `handle:prompt(text)` | send one user prompt |
| `handle:interrupt()` | stop the current turn |
| `handle:answer(request_id, allow, opts)` | answer a permission ask |
| `handle:set_mode(mode)`, `handle:set_model(model)` | only called when the capability is true |
| `handle:stop(cb, now)` | end the process |
| `handle:alive()`, `handle:pid()` | |
| `history(session, cb)` | events for a past session: Claude reads the transcript file; ACP reads the plugin's log |

**Action** gains nothing new. ACP specifics map onto existing types: message chunk → `delta` then a `text` event when the block ends; thought chunk → `thinking` event; tool call + updates → `tool_call` and `tool_result` events; plan → a `meta` event labelled `plan`; permission request → `permission`; available commands → `init`-style update of `slash_commands`; mode change → `status`; usage → `quota` when the agent reports comparable windows, otherwise a `meta` event labelled `usage`; anything else → `unknown`.

**SessionMeta** gains `agent` (string; `'claude'` for all existing sessions).

---

### Task 0: Re-baseline

- [ ] Read `lua/agent-ide/session/{init,object,actions}.lua`, `lua/agent-ide/claude/{process,stream,version}.lua`, `lua/agent-ide/ui/{chat,chat_keys,mode,permission,drawer_model,tree}.lua`, `lua/agent-ide/status.lua`, `docs/protocol.md`, and the "Interface as built" notes that exist in the repo. List every place Session reaches into Claude-specific modules.
- [ ] Update this plan's Adapter table and task text where reality differs. Commit the updated plan before any code.

### Task 1: Capture ACP from the three real agents

**Files:** create `docs/protocol-acp.md`; scratch captures stay outside the repo.

- [ ] For each of Codex, Gemini CLI and opencode: find the documented way to start it as an ACP agent with the installed version (its `--help`, its docs). If Codex needs a separate adapter program, record its name, source and how it is installed; do not install anything without the user's go-ahead — stop and ask.
- [ ] With a small driver script in a temporary git repository, run: initialize and capability exchange; new session; a plain prompt; a prompt that makes the agent edit a file (permission ask: allow once, deny once); cancel during a long answer; a second prompt in the same session; restart the process and try to load the session; a model or mode change if offered; whatever the agent uses for slash commands. Use the cheapest model.
- [ ] Record per agent in `docs/protocol-acp.md`: start command, protocol version, capability flags, the method and notification names seen, the fields that matter for each (placeholders for values), which client-side methods the agent calls and what happens when the client declines them, how errors and auth problems look, and an "Open questions" list. No real ids, paths or content.
- [ ] Decide and write down, per agent: supported in this plan / supported with stated limits / not supportable yet, with the reason. **If none of the three works acceptably, stop here and report.**

### Task 2: Adapter interface and Claude adapter (pure refactor)

**Files:** create `lua/agent-ide/agents/init.lua`, `lua/agent-ide/agents/claude.lua`; modify `lua/agent-ide/session/`; test `tests/test_agents.lua`.

- [ ] Failing tests: `agents.get('claude')` returns an adapter whose `start` produces, against the fake Claude and the existing stream fixtures, exactly the Action sequence the current code produces (record the current sequence first as the golden); capabilities for Claude are all true; `agents.get('nope')` returns nil and a clear error string; a session opened with `agent = 'claude'` behaves as today.
- [ ] Move the calls Session makes to `claude/process` and `claude/stream` behind the adapter. No behaviour change. Sessions carry `agent` (default `'claude'`).
- [ ] Whole suite green with no assertion edits. `make test-real` green if present.
- [ ] Commit `refactor: agent adapter interface with Claude as first adapter`.

### Task 3: JSON-RPC client and fake ACP agent

**Files:** create `lua/agent-ide/agents/acp/client.lua`, `tests/fake_acp.lua`, `tests/fixtures/acp/`; test `tests/test_acp_client.lua`.

**Interfaces:** `client.start(cmd, opts) -> c`; `c:request(method, params, cb(err, result))`; `c:notify(method, params)`; `c:on_request(method, fn(params, respond))`; `c:on_notification(method, fn(params))`; `c:stop(cb, now)`; every line sent and received is passed to `opts.on_raw(dir, line)`.

- [ ] Failing tests against the fake: request/response matched by id out of order; a notification; an agent→client request answered; a JSON-RPC error response surfaces as `err`; an unknown method from the agent gets a "method not found" error response and is reported to a catch-all handler; malformed line reported and skipped; request timeout (default 120 s, configurable; long because prompts are requests that stay open for a whole turn — confirm in Task 1 whether the prompt request returns only at turn end); process exit fails all pending requests exactly once; no process left behind.
- [ ] Implement with the shared line splitter (`lua/agent-ide/util/lines.lua`) and the stop/SIGTERM pattern used by the Claude process wrapper.
- [ ] Commit `feat: JSON-RPC client and scriptable fake ACP agent`.

### Task 4: ACP adapter

**Files:** create `lua/agent-ide/agents/acp/adapter.lua`, `lua/agent-ide/agents/acp/fs.lua`; modify `lua/agent-ide/config.lua`; test `tests/test_acp_adapter.lua`.

Config:

```lua
agents = {
  claude   = { },                                   -- built in
  gemini   = { kind = 'acp', cmd = { 'gemini', '--experimental-acp' } },   -- command per Task 1
  opencode = { kind = 'acp', cmd = { 'opencode', 'acp' } },                -- command per Task 1
  codex    = { kind = 'acp', cmd = { 'codex-acp' } },                      -- command per Task 1
},
default_agent = 'claude',
```
Users can add any ACP agent by name with `kind = 'acp'` and a `cmd`.

- [ ] Failing tests against the fake ACP agent, using synthetic scenarios shaped like Task 1's captures: start performs initialize → (authenticate if required) → new session, and fills `capabilities` from the agent's flags; message chunks become `delta`s and one `text` event equal to their concatenation; thought chunks become one `thinking` event; a tool call with later updates becomes one `tool_call` event and one `tool_result` event with the final content (intermediate updates do not create extra events); diff-type tool content renders as an `Edit`-like tool call (old/new text) so the existing fold body rules apply; a plan becomes a `meta` event; a permission request becomes a `permission` action and `answer` sends the option id the agent offered for allow/deny (agents send their own option lists: map `allow_once`-like and `reject_once`-like options to Allow/Deny and pass any other options through as extra choices with the agent's labels); `interrupt` sends cancel and the turn ends with an idle state; end of the prompt request ends the turn with a `result` action (`is_error` from the stop reason); an unknown update type becomes `unknown` with raw JSON; a client-side method the plugin does not implement is declined with a proper error and, if the agent then fails the turn, the error text names the method (Review Focus 1); process exit mid-turn yields the `exit` action (Review Focus 2).
- [ ] Client-side file methods: implement read and write only if Task 1 shows an agent needs them; reads are limited to the session's working directory tree unless the user allows more (`agents.<name>.fs = 'cwd' | 'any' | false`); a write goes through the same permission flow as a tool call when the agent did not already ask. Terminal methods are declined unless Task 1 shows they are required; if required, stop and re-plan that part with the user.
- [ ] Commit `feat: ACP adapter translating to the shared action model`.

### Task 5: Plugin-owned session log and history

**Files:** create `lua/agent-ide/agents/log.lua`; modify `lua/agent-ide/index/`, `lua/agent-ide/session/`; test `tests/test_agent_log.lua`.

- [ ] Sessions run through an ACP adapter append their Events (the stored form, without `live_only` ones) as JSON lines to `stdpath('state')/agent-ide/sessions/<agent>/<session id>.jsonl`, with a first line `{ "agent", "id", "agent_session_id", "cwd", "title", "created" }`. Writes are asynchronous and ordered; a crash loses at most the last event.
- [ ] `adapter.history` for ACP reads that file. The scan merges these sessions into the index with `agent` set, `title` = first prompt (ACP agents rarely supply titles), `activity` from the last event.
- [ ] Resume: on send to a parked ACP session, start the agent and call load with `agent_session_id` when `capabilities.resume`; otherwise start a new agent session, add a visible `meta` event `New <agent> session: the agent cannot reload the earlier conversation`, and continue in the same transcript (Review Focus 5). A setting `agents.<name>.replay_context = false` may, when true, send the earlier conversation as the first prompt of the new agent session; off by default because it costs tokens and changes what the agent sees.
- [ ] Tests: log round trip equals the live buffer (history equals live for ACP sessions); merge into scan; both resume paths; a corrupt last line is skipped.
- [ ] Commit `feat: event log and history for agents without a readable transcript`.

### Task 6: Session and chat UI driven by capabilities

**Files:** modify `lua/agent-ide/session/`, `lua/agent-ide/ui/{chat,chat_keys,mode,permission}.lua`, `lua/agent-ide/status.lua`; test `tests/test_agent_ui.lua`.

- [ ] Session uses `agents.get(s.agent)`; nothing in Session or the UI names Claude outside the Claude adapter and the version notice.
- [ ] Controls follow `capabilities`: the mode key, the model picker, `/` completion and the escape hatch to the native program are active only when supported; otherwise the key shows a one-line notice `Agent-IDE: <agent> does not offer <feature> through ACP` and the winbar omits that segment. `?` help lists unsupported features for the current session's agent.
- [ ] Winbar starts with the agent name for non-Claude sessions. Status levels and the status file count sessions of every agent; the status file's session rows gain `agent`.
- [ ] Permission asks from ACP sessions go through the existing never-interrupt flow unchanged (Review Focus 3): re-run the part 2 never-interrupt tests with an ACP session as the asking session.
- [ ] Footer quota shows only when the focused session's agent reports it.
- [ ] Commit `feat: capability-driven chat controls for any agent`.

### Task 7: Drawer: choosing an agent, labelling sessions

**Files:** modify `lua/agent-ide/ui/{tree,drawer,drawer_model}.lua`, `lua/agent-ide/config.lua`; test `tests/test_tree.lua`, `tests/test_agent_ui.lua`.

- [ ] `+ New session` uses `default_agent`. A second key on that row (and `:AgentsNew <agent>`) opens a picker of configured agents; agents whose command is not on `PATH` are listed as unavailable.
- [ ] Session rows of non-Claude agents show a short agent tag before the title. With only Claude configured or used, the drawer looks exactly as before (assert unchanged lines on the existing fixtures).
- [ ] Search (if the search feature exists by then) includes logged sessions; verify or note as a follow-up.
- [ ] Review Focus 4 test: two agents in one project.
- [ ] Commit `feat: start sessions with any configured agent from the drawer`.

### Task 8: Real-agent check and docs

**Files:** create `tests/real/acp.lua` (`make test-real-acp`, not part of `make test`); modify `README.md`, `docs/protocol-acp.md`.

- [ ] For each agent marked supported in Task 1: in a temporary git repository with its cheapest model, through the real plugin headless: a plain answer renders; an edit asks permission and allow applies it; deny leaves the file; interrupt ends the turn and a new prompt works; park and reopen (load or the documented new-session notice); history equals live from the plugin's log; raw view shows the JSON-RPC traffic. Print pass/fail per check and per agent, no content.
- [ ] Fix failures in the owning module with a fake-based regression test. Update `docs/protocol-acp.md` where reality differed.
- [ ] README: an "Other agents" section with a per-agent table of what works and what does not (resume, modes, models, commands, quota), how to add another ACP agent, and the billing note.
- [ ] Whole suite, `make test-helper`, `make test-real` (Claude) and `make test-real-acp` pass.
- [ ] Commit `feat: real-agent checks and documentation for ACP agents`.

## Not in this plan

- Listing sessions that were started outside the plugin in Codex, Gemini or opencode (each has its own storage; the drawer shows only sessions the plugin ran). A later, per-agent reader could add them.
- Live state of non-Claude sessions running in tmux panes.
- The `pi` agent, unless Task 1 finds it speaks ACP, in which case it is one more config entry.
- Images and other non-text prompt content.

## Things to decide with the user when this is picked up

1. Whether installing a separate Codex ACP adapter is acceptable, if Codex needs one.
2. Whether client-side file access for agents that require it should default to the working directory only (this plan's default).
3. Whether `replay_context` should ever default to on for agents that cannot reload a session.
