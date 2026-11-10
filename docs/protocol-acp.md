# Agent Client Protocol (ACP) as observed

Notes from driving the installed agents in ACP mode with a small script, in throwaway
folders outside this repository, on 2026-11-10. All values below are placeholders (`<sid>`,
`<id>`, `<path>`, `<text>`); only the method names, update kinds and field names are as
observed. Nothing from a real conversation is kept here.

ACP is JSON-RPC 2.0, one object per line over the agent's stdin and stdout. The client
(this plugin) sends requests and notifications; the agent answers, streams
`session/update` notifications, and sends its own requests to the client. Request ids are
free (the plugin uses integers); the agent's ids for its own requests are its own.

| Agent | Version | Start | Status |
|---|---|---|---|
| Gemini CLI | 0.65.0 | `gemini --acp [-m <model>]` (`--experimental-acp` is deprecated) | **supported with limits** (below) |
| opencode | 2.2.7 | `opencode acp` (model and permissions from its own config, e.g. `opencode.json` in the folder) | **supported with limits** (below) |
| Codex | 0.163.0 | none: `codex` has no ACP mode (`codex app-server` speaks its own protocol); no `codex-acp` on PATH | **not supportable yet**; add an entry under `agents` once an ACP adapter for Codex is installed |
| pi | installed | its help names no ACP mode | out of scope |

## Handshake

### `initialize` (client → agent)

```
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,
  "clientCapabilities":{"fs":{"readTextFile":true,"writeTextFile":true},"terminal":false},
  "clientInfo":{"name":"<name>","version":"<v>"}}}
```

Answer: `protocolVersion` (1), `agentInfo{name,version[,title]}`, `authMethods[]`
(`id`, `name`, `description`, optional `_meta`), `agentCapabilities`:

- Gemini: `loadSession: true`, `promptCapabilities{image,audio,embeddedContext}`,
  `mcpCapabilities{http,sse}`. Four auth methods (`oauth-personal`, an API key, Vertex, a
  gateway).
- opencode: `loadSession: true`, `promptCapabilities{embeddedContext,image}`,
  `mcpCapabilities{http,sse}`, `sessionCapabilities{additionalDirectories,close,delete,fork,list,resume}`
  (each an empty object), `_meta`. One auth method (`opencode-login`, "run `opencode auth
  login`").

Both agents were already logged in through their own CLIs: `session/new` succeeded without
`authenticate`. What an agent answers when it is **not** logged in was not observed; the
adapter shows the error of `session/new` (with the auth method names) and does not retry.

### `session/new` (client → agent)

`params: {cwd: "<absolute folder>", mcpServers: []}`. The answer carries `sessionId`
(Gemini: a UUID; opencode: `ses_<random>`) and the agent's settings:

- Gemini: `modes{availableModes[{id,name,description}], currentModeId}` (ids `default`,
  `autoEdit`, `yolo`, `plan`) and `models{availableModels[{modelId,name[,description]}],
  currentModelId}`.
- opencode: `configOptions[{id, name, category, type:"select", currentValue,
  options[{value,name[,description]}]}]` with ids `model` (category `model`) and `mode`
  (category `mode`; values are opencode's agents, e.g. `build`, `plan`). No `modes`/`models`
  objects.

Right after the answer both agents send `available_commands_update` (below).

### `session/load` (client → agent)

`params: {sessionId: "<sid>", cwd, mcpServers: []}`. Both agents **replay the whole
conversation** as `session/update` notifications (`user_message_chunk`,
`agent_message_chunk`, `agent_thought_chunk`, `tool_call` with `status: completed`, and for
Gemini a `user_message_chunk` holding its own `<session_context>` preamble and
`[Function Call: …]` / `[Function Response: …]` markers) **before** the response, which has
the same shape as `session/new` without `sessionId`. Then `available_commands_update`
again. A prompt after the load is answered with the earlier context. Because the plugin
keeps its own log of the session, the adapter does not turn the replay into events (it
would double every line); the raw view keeps it.

## Prompting

### `session/prompt` (client → agent)

`params: {sessionId, prompt: [{type: "text", text: "<text>"}]}`. **The request stays open
for the whole turn.** The response is `{stopReason, usage?, _meta?}`:

- `stopReason`: `end_turn` (both), `cancelled` after `session/cancel` (both). Others defined
  by the protocol (`max_tokens`, `max_turn_requests`, `refusal`) were not observed.
- `usage{inputTokens, outputTokens, totalTokens[, cachedReadTokens, thoughtTokens]}` (both;
  absent on a slash-command turn).
- Gemini: `_meta.quota{token_count{input_tokens,output_tokens}, model_usage[{model,
  token_count}]}`.
- A failed turn is a JSON-RPC **error** on the prompt request: Gemini answered
  `{code: 429, message: "<daily quota exhausted on this model>"}` once the model's free
  quota was used up. The adapter ends the turn with an error line holding `message`.

A slash command is sent as a prompt whose text is `/<name>` (`/memory` on Gemini printed
its memory as `agent_message_chunk`; `/init` on opencode ran its command).

### `session/cancel` (client → agent, notification)

`params: {sessionId}`. The open prompt request then returns `stopReason: "cancelled"` (both
agents; Gemini within a second, opencode too). Chunks already streamed stay.

### `session/update` (agent → client, notification)

`params: {sessionId, update: {sessionUpdate: "<kind>", …}}`. Kinds seen:

| kind | fields | notes |
|---|---|---|
| `agent_message_chunk` | `content{type:"text", text}`; opencode adds `messageId` | the answer, streamed in pieces (Gemini: words or sentences; opencode: paragraphs) |
| `agent_thought_chunk` | `content{type:"text", text}` | Gemini only; one chunk per thought, each a whole paragraph with a bold title |
| `user_message_chunk` | `content{type:"text", text}`; opencode adds `messageId` | only during a `session/load` replay |
| `tool_call` | `toolCallId`, `title`, `kind` (`execute`, `edit`, …), `status` (`pending`), `content[]`, `locations[{path}]`; opencode adds `name` (`edit`, `shell`) and `rawInput` (often `{}` at first) | Gemini's `title` is the shell command; opencode's is the tool name |
| `tool_call_update` | `toolCallId`, `status` (`in_progress`, `completed`, `failed`), optional `title`, `kind`, `content[]`, `locations[]`, `rawInput`, `rawOutput` | opencode sends several `in_progress` updates (with `rawInput{command,cwd}` or `{path,oldString,newString[,replaceAll]}`) then `completed`; Gemini sends one `completed` (or `failed` with the cancel text) |
| `plan` | not observed | defined by the protocol (`entries[{content,priority,status}]`) |
| `available_commands_update` | `availableCommands[{name, description[, input]}]` | both, right after `session/new`/`load`; Gemini lists sub-commands as `memory show` (a space in the name) |
| `current_mode_update` | not observed | neither agent announced a mode change after `session/set_mode`; the mode is taken from the request's success |
| `usage_update` | `used`, `size`; opencode adds `cost{amount,currency}` | context window use; several per turn |

`content[]` entries of a tool call are `{type: "content", content: {type: "text", text}}`
or `{type: "diff", path, oldText, newText}` (opencode's `edit` on completion; the adapter
renders it as an `Edit`-like call with `file_path`, `old_string`, `new_string`).

### `session/request_permission` (agent → client, request)

Gemini, for every tool in its default mode:
`params: {sessionId, options: [{optionId, name, kind}], toolCall: {toolCallId, title,
status, content, locations, kind}}` with options of kinds `allow_always` ("Allow for this
session"), `allow_once` ("Allow"), `reject_once` ("Reject"). The answer is
`{outcome: {outcome: "selected", optionId: "<id>"}}` (or `{outcome: {outcome: "cancelled"}}`).
A rejected call comes back as `tool_call_update` with `status: "failed"` and a text saying
the tool was cancelled by the user; the turn goes on (the agent apologises).

**opencode never asked** in these runs: edits and shell commands ran without a
`session/request_permission` (its own permission configuration decides; the ACP server
runs with whatever `permission` its config holds, and the default allowed everything
here). A plugin user who wants asks must configure opencode itself.

### Client-side methods (agent → client)

The script offered `fs.readTextFile` and `fs.writeTextFile` and declined `terminal`.
Neither agent called `fs/read_text_file`, `fs/write_text_file` or any `terminal/*`
method in these runs: both read, write and run commands with their own tools. The
adapter still answers `fs/*` (scoped to the working directory, see the README) and
declines everything else with error `-32601` ("Method not found").

### Settings

| request | Gemini | opencode |
|---|---|---|
| `session/set_mode {sessionId, modeId}` | ok (`{}`) for `plan` and `default`; `autoEdit` and `yolo` are refused with `-32603` "Internal error", `data.details` "Cannot enable privileged approval modes in an untrusted folder" (Gemini's folder trust; the folder was not trusted) | ok (`{}`), with the `mode` option's values |
| `session/set_model {sessionId, modelId}` | ok (`{}`) | not tried (opencode has no `models`; its model is a config option) |
| `session/set_config_option {sessionId, configId, value}` | `-32601` method not found | ok; answers the full `configOptions` list with the new `currentValue` |

### Errors

JSON-RPC errors carry `code`, `message` and optional `data`. Seen: `-32601` (unknown
method, `data.method` on Gemini), `-32603` (internal; `data.details`), `429` (quota, on a
prompt request). An unknown method sent **to** the client is answered the same way.

### Process

Closing stdin after the last response makes both agents exit with code 0. Gemini writes
notices to stderr (untrusted folder, hooks disabled, telemetry); opencode writes nothing
there by default.

## What the plugin does with it

- `init` action from the `session/new`/`load` answer: `model` = `models.currentModelId`
  (Gemini) or the `model` config option's `currentValue` (opencode); `mode` =
  `modes.currentModeId` or the `mode` option's `currentValue`; the lists feed the mode cycle
  and the model picker.
- Capabilities per agent after start: `resume` = `agentCapabilities.loadSession`; `modes` =
  a `modes` object or a `mode` config option; `models` = a `models` object or a `model`
  config option; `commands` = true once `available_commands_update` arrived; `quota` =
  false (the usage numbers are per turn, not windows; they show as a `usage` meta event is
  **not** done: fidelity keeps them in the raw view only).
- Message chunks → `delta` while they stream and one `text` event when the turn ends or a
  tool call starts; thought chunks → one `thinking` event each (they come whole); tool
  calls → `tool_call` when first seen and `tool_result` on `completed`/`failed`.

## Open questions

- What `session/new` answers for an agent that is not logged in (never observed).
- Whether opencode can be made to ask permissions through ACP (its `permission` config
  was not changed for these runs).
- `plan` and `current_mode_update` shapes (defined by the protocol, not seen).
- Whether Gemini's `-m` flag and `session/set_model` agree when the model is not in
  `availableModels`.
