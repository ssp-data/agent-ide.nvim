# Claude Code stream-json protocol (as observed)

Notes from driving real Claude Code **2.1.306** headless, model `haiku`, in a throwaway git
repository, with `ANTHROPIC_API_KEY` removed from the environment. All values below are
invented placeholders (`<sid>`, `<uuid>`, `toolu_X`, `/tmp/x/...`); only the object types,
subtypes and field names are as observed.

## Command line

```
env -u ANTHROPIC_API_KEY claude -p --verbose \
  --input-format stream-json --output-format stream-json \
  --include-partial-messages --replay-user-messages \
  --permission-prompts host --permission-prompt-tool stdio \
  --session-id <uuid>            # or --resume <id>
  [--model haiku] [--permission-mode plan|manual|acceptEdits|...] [--safe-mode]
```

One JSON object per line in both directions. `system/init` is not printed at start-up:
it arrives only when the first prompt is sent (control requests sent before that are
answered with `control_response` and no `init`).
Closing stdin after the last `result` makes the process exit with code 0.

### `--safe-mode`

`--safe-mode` disables CLAUDE.md, personal skills, hooks, MCP servers, custom commands and
agents. Compared with one run without it:

- Hooks, if configured, emit `system/hook_started` and `system/hook_response`; hooks that
  run at session start arrive **before** `system/init`. Under safe mode no hook objects
  appear.
- `init` can carry a `memory_paths` field without safe mode; otherwise the field set is the
  same.
- Permissions are **not** reset by safe mode: a configured default mode and allow rules
  still apply, so `init.permissionMode` may differ from `default` and an allowed tool runs
  without an ask (its `tool_result_meta.permission_decision.source` then names the rule's
  origin, e.g. `user_permanent` or `config`). Pass `--permission-mode` explicitly when a
  known mode matters. Built-in plugins and skills are still listed in `init`.

So hook objects must be expected in real use, possibly before `init`.

## Input lines (stdin)

| purpose | line |
|---|---|
| initialize | `{"type":"control_request","request_id":"i1","request":{"subtype":"initialize"}}` |
| prompt | `{"type":"user","message":{"role":"user","content":"<text>"}}` |
| set model | `{"type":"control_request","request_id":"r1","request":{"subtype":"set_model","model":"sonnet"}}` |
| set mode | `{"type":"control_request","request_id":"r2","request":{"subtype":"set_permission_mode","mode":"plan"}}` |
| interrupt | `{"type":"control_request","request_id":"r3","request":{"subtype":"interrupt"}}` |
| answer an ask | `{"type":"control_response","response":{"subtype":"success","request_id":"<id from Claude>","response":{"behavior":"allow","updatedInput":{...}}}}` |
| deny an ask | same with `"response":{"behavior":"deny","message":"<why>"}` |
| allow and apply a suggestion | `"response":{"behavior":"allow","updatedInput":{...},"updatedPermissions":[<suggestion as received>]}` |

Request ids we send are free-form strings (`r1`, ...; `i1`, ... for `initialize`). Ids Claude
sends are UUIDs. The plugin writes `initialize` as the very first line of every process it
starts, before the first prompt and any deferred setting.

## Output objects (stdout)

### `system`

- `init`: `type, subtype, cwd, session_id, tools[], mcp_servers[], model, permissionMode,
  slash_commands[], terminal_slash_commands[], apiKeySource, claude_code_version,
  output_style, agents[], skills[], plugins[{name,path,source,version}], capabilities[],
  analytics_disabled, product_feedback_disabled, uuid, original_cwd,
  additional_directories[], messaging_socket_path, fast_mode_state,
  fast_mode_disabled_reason, per_turn_effort_active, view_mode` (+ `memory_paths` without
  safe mode). **Sent again at the start of every turn**, not only once. `model` is the full
  id (`claude-haiku-5-5`); `permissionMode` uses Claude's names, so the plugin's `manual`
  comes back as `default` (started with `--permission-mode manual` → `default`).
  `apiKeySource` was `none` (subscription login).
  `slash_commands` names a project command file `.claude/commands/<folder>/<name>.md` as
  `<folder>:<name>` and `.claude/commands/<name>.md` as `<name>` (observed with
  `--setting-sources project` in a temporary folder holding one of each; the drawer's
  Skills & commands use the same rule).
- `status`: `type, subtype, status, session_id, uuid`, optionally `permissionMode`.
  `status` is `"requesting"` when an API request starts (once per model call, so several
  per turn) and `null` on the status objects that announce a mode change
  (`{"status":null,"permissionMode":"plan"}`). No status object marks the end of a turn:
  only `result` does.
- `thinking_tokens`: `estimated_tokens, estimated_tokens_delta` — a running estimate while
  the model thinks. Several per thinking block.
- `hook_started`: `hook_id, hook_name, hook_event`. `hook_response`: `hook_id, hook_name,
  hook_event, outcome, exit_code, output, stdout, stderr` (only without safe mode).
- Background subagent bookkeeping: `background_tasks_changed` (`tasks[{task_id, run_id,
  task_type, subagent_type, description}]`), `task_started` (`task_id, run_id, tool_use_id,
  description, subagent_type, is_backgrounded, spawn_depth, task_type, prompt`),
  `task_updated` (`task_id, run_id, patch{status, end_time}`), `task_notification`
  (`task_id, run_id, tool_use_id, status, output_file, summary, usage{total_tokens,
  tool_uses, duration_ms}`).

### `stream_event`

`{type:"stream_event", event:{...}, session_id, parent_tool_use_id, uuid, api_message_id}`
(`message_start` also carries `ttft_ms`, `thinking_display`). Inner `event.type`:

- `message_start` (`message{model,id,type,role,content[],stop_reason,usage,...}`)
- `content_block_start` (`index, content_block{type:"text",text:""}` or
  `{type:"tool_use",id,name,input:{},caller}` or `{type:"thinking",thinking:"",signature:""}`)
- `content_block_delta` with `delta.type`:
  - `text_delta` (`text`)
  - `input_json_delta` (`partial_json`) for tool input
  - `thinking_delta` (`thinking`, `estimated_tokens`) — **`thinking` was always the empty
    string**: thinking content is not shown in this configuration
    (`thinking_display:"updates"`), only token estimates
  - `signature_delta` (`signature`)
- `content_block_stop` (`index`)
- `message_delta` (`delta{stop_reason,...}, usage, context_management`)
- `message_stop`

### `assistant`

`{type:"assistant", message{model,id,type,role,content[],stop_reason,usage,...},
parent_tool_use_id, session_id, uuid, timestamp, request_id}`; tool calls add
`wire_tool_inputs`, an interrupted message adds `aborted:true`, a failed call adds
`error, is_api_error_message, api_error_status`, a subagent message adds `agent_id,
subagent_type, task_description`, a local slash command adds `local_command_run{command,
args}, local_command_source, context_usage`.

**One `assistant` object per content block**, not per API message: a message with a
thinking block, a text block and a tool call arrives as three `assistant` objects with the
same `message.id`, each with a one-element `content`. Each arrives right **after the
block's last delta and before its `content_block_stop`**. Thinking blocks carry
`thinking:""` plus a signature.

### `user`

- Replayed prompt (from `--replay-user-messages`): `{type:"user", message{role,content:"<the
  prompt text, verbatim string>"}, session_id, parent_tool_use_id:null, uuid, timestamp,
  isReplay:true}`. Told apart from tool results by `isReplay:true` (tool results have no
  `isReplay`) and by string content.
- Tool result: `message.content[{type:"tool_result", tool_use_id, content (string or
  block array), is_error?}]` plus `tool_use_result` (tool-specific object, or a string
  `"Error: ..."` on deny) and `tool_result_meta[{id, permission_decision{decision, source},
  non_execution_kind?}]`. `is_error` is sometimes absent instead of `false`.
- Control-command output: after a `set_model` sent between turns, a **replayed** user
  message (`isReplay:true`) with string content `<local-command-stdout>Set model to
  ...</local-command-stdout>`. (Not emitted for `set_model` before the first prompt.)
- Interrupt marker: `message.content[{type:"text", text:"[Request interrupted by user]"}]`,
  no `isReplay`.

### `rate_limit_event`

`rate_limit_info{status, resetsAt, rateLimitType, overageStatus, overageDisabledReason,
isUsingOverage, unifiedWindows{five_hour{utilization, resetsAt}, seven_day{utilization,
resetsAt}}}, uuid, session_id`. `utilization` is a fraction (0.0–1.0), `resetsAt` epoch
seconds. Sent after each API message, not every turn.

### `result`

`type, subtype, is_error, result, stop_reason, num_turns, duration_ms, duration_api_ms,
total_cost_usd, usage, modelUsage, permission_denials[{tool_name, tool_use_id,
tool_input}], terminal_reason, fast_mode_state, subagent_stats, safety_stops,
api_error_status, queued_turn_count, result_index, session_id, uuid` (+ timing fields).
Subtypes seen: `success`, `error_during_execution`. **`subtype` does not tell success:**
a failed API call came as `subtype:"success", is_error:true`. Use `is_error`.
`error_during_execution` has no `result` but `errors[]` (strings). A local slash command's
result adds `local_command`. A turn started by a background task adds `origin{kind:
"task-notification", ...}`.

### `control_request` (from Claude)

Only `subtype:"can_use_tool"` was seen:
`{type:"control_request", request_id:"<uuid>", request{subtype:"can_use_tool", tool_name,
display_name, input, tool_use_id, description?, permission_suggestions?, blocked_path?,
requires_user_interaction?}}`.

- File tools: `description` is the file name, `permission_suggestions[{type:"setMode",
  mode:"acceptEdits", destination:"session"}]`.
- Bash: `description` is the command's description, suggestions `{type:"addRules",
  rules[{toolName, ruleContent}], behavior:"allow", destination:"localSettings"}` and
  `{type:"addDirectories", directories[], destination:"session"}`, plus `blocked_path`.
- `AskUserQuestion` and `ExitPlanMode`: no `description`, no suggestions,
  `requires_user_interaction:true` (see scenarios).

#### Applying a suggestion: `updatedPermissions`

A suggestion takes effect when it is sent back, unchanged, in the allow answer's
`updatedPermissions` array (next to `updatedInput`). A plain allow applies nothing.

- `addRules` (`rules[{toolName, ruleContent}]`, `behavior:"allow"`, `destination`): the rule is
  applied at once and saved according to `destination`. With `destination:"localSettings"`
  Claude wrote `{"permissions":{"allow":["<toolName>(<ruleContent>)"]}}` to
  `<project>/.claude/settings.local.json`; no file outside the project changed. The
  `ruleContent` of a Bash suggestion was the exact command. Proof: the same command asked
  again after a plain allow, and ran without an ask after an allow with the rule. Other
  destinations (`session`, `projectSettings` = `<project>/.claude/settings.json`,
  `userSettings` = the user's own settings file) were not exercised.
- `setMode` (`mode`, `destination:"session"`): Claude switches the mode right away:
  `system/status{status:null, permissionMode:"<mode>"}` follows the answer, the next `init`
  carries the mode, and a second Write in `acceptEdits` ran without an ask. This replaces a
  plain allow followed by `set_permission_mode`.
- `addDirectories` was not exercised.

### `control_response` (from Claude)

- To our requests: `{type:"control_response", response{subtype:"success", request_id,
  response?}}` or `{response{subtype:"error", request_id, error, error_code}}`.
- **Echo of our answers:** every `control_response` we send for a `can_use_tool` ask is
  printed back verbatim on stdout (same `request_id`, Claude's UUID), shortly after.

## Scenarios

Sequences list object types; `…` is a run of deltas. "A(text)" = `assistant` with one text
block. Every turn starts `system/init`, `system/status(requesting)`, `user(isReplay)`.

### Plain answer

`init, status, user(replay), stream_event{message_start, content_block_start(text),
content_block_delta(text_delta)…}, A(text), stream_event{content_block_stop,
message_delta, message_stop}, rate_limit_event, result(success)`.
A second prompt on the same process works the same way (a new `init` first).

### Bash under `acceptEdits`

`... content_block_start(tool_use), input_json_delta…, A(tool_use), content_block_stop,
message_delta(stop_reason tool_use), message_stop, rate_limit_event, user(tool_result),
status(requesting), message_start, text…, A(text), ..., result`. No ask in this run,
because an allow rule covered the command; a command no rule covers produces a
`can_use_tool` ask (seen in the plan scenario).

### Write under `manual`, allowed

`... A(tool_use Write), content_block_stop, control_request(can_use_tool)`, we answer
allow, `control_response(echo of ours), message_delta, message_stop, rate_limit_event,
user(tool_result; tool_result_meta.permission_decision{decision:"accept",
source:"user_temporary"}), status, ... text ..., result(permission_denials:[])`.
The ask can arrive before or after `content_block_stop`/`message_stop`.

### Write under `manual`, denied

Same up to the ask; we answer `deny` with a message. Then `control_response(echo),
user(tool_result{is_error:true, content:"<our message>"}, tool_use_result:"Error: <our
message>", permission_decision{decision:"reject", source:"user_reject"},
non_execution_kind:"permission-rule")`, then Claude continues (a thinking block, then text)
and `result(is_error:false, permission_denials[{tool_name, tool_use_id, tool_input}])`.

### `set_model`, `set_permission_mode`

- `set_model` → `control_response{subtype:"success", request_id}` (no `response`).
  Takes effect on the next turn's `init.model`. Between turns it also yields a replayed
  `<local-command-stdout>` user message. Unknown model name → `control_response{subtype:
  "error", error:"Model '<name>' not found", error_code:"not_found"}` and the model is
  unchanged.
- `set_permission_mode` → `system/status{status:null, permissionMode:"<new>"}` and
  `control_response{subtype:"success", response{mode:"<new>"}}`. Sending `default` gives
  mode `default`. Invalid mode → `control_response{subtype:"error", error,
  error_code:"invalid_mode"}`. The status object can arrive after our next request was
  already sent (it is asynchronous).

### `initialize`

Answered at once, without a prompt or a turn (no usage): `system/hook_started`,
`system/hook_response` may come first, then `control_response{subtype:"success", request_id,
pending_permission_requests, pending_user_dialog_requests, response{…}}`. Observed with
2.1.306 alone on stdin (then EOF; Claude exits), keys of `response`: `account, agents,
analytics_disabled, available_output_styles, capabilities, claude_code_version, commands,
current_permission_mode, fast_mode_disabled_reason, fast_mode_state, feedback_mode,
ide_rc_auto_enable_gate, models, output_style, pid, remote_control_auto_connect_default,
remote_control_auto_enable, remote_control_auto_on_by_default, remote_control_available,
session_state, user_output_styles_dir`.

- `models[]`: `value, resolvedModel, displayName, description, supportedEffortLevels?,
  supportsEffort?, supportsAdaptiveThinking?, supportsAutoMode?, supportsThinkingOff,
  supportsFastMode?`. 14 entries, in this order: `default` (its `resolvedModel` the
  default model, its `displayName` `Default (recommended)`), the aliases and newest models
  (`opus`, `claude-fable-5-2`, `sonnet`, `haiku`, `fable`), then older models by full id
  (some with a date suffix). `value` is what `set_model` and `--model` take; two entries can
  resolve to the same model (`default` and `fable`).
- `commands[]`: `name, description, argumentHint` (`name` without the `/`), about 100 entries.
- `account` holds the login; the plugin reads nothing from it.

The plugin keeps `value, displayName, description, resolvedModel` of each model (as `value,
name, description, resolved` in `models.json`) and the command names for the `/` menu before
the first `init`. An error answer is ignored. Not verified: whether `initialize` after the
first prompt is accepted (the plugin never sends it later), and with `--resume` (the Agent
SDK sends it first in both cases).

### `claude agents --json` and processes started headless

A `claude -p` session started this way is listed while its process runs:
`{sessionId, pid, cwd, kind, name, startedAt, status}` with `kind:"interactive"`. The listed
`pid` is the pid of the process that was spawned, also when `claude` is a wrapper script that
`exec`s the real binary (a wrapper that forks instead would list a different pid). `status`
stayed `idle` during a turn in the sample taken, so the plugin's own state, not the list,
says whether one of its sessions is busy. The entry disappears when the process exits.

### `--resume <id>`

A process started with `--resume <id>` (after the session's earlier process exited) answers
from the earlier turns: asked for the first prompt of the session, it repeated it. `init`
arrives with the first prompt as usual.

### Interrupt during a long answer

After the first text deltas we sent `interrupt`:
`control_response{subtype:"success", response{still_queued:[]}}`, then
`A(text: the partial text so far, aborted:true)`, `user(content[{type:"text",
text:"[Request interrupted by user]"}])`, `content_block_stop, message_delta,
message_stop`, `result{subtype:"error_during_execution", is_error:true, result absent,
errors[...], terminal_reason:"aborted_streaming"}`. No `rate_limit_event`. The process
stays alive and the next prompt is answered normally.

### Failed turn

`set_model` to a nonsense name is rejected up front (see above), so a failed turn was
produced by starting with `--model <nonsense>` instead: `init(model:"<nonsense>")`,
`status`, a line on **stderr** (`[claude-code:unrecognized_model] {...}`), `user(replay)`,
then **no stream events** but `A(text: "There's an issue with the selected model ...",
message.model:"<synthetic>", error:"model_not_found", is_api_error_message:true,
api_error_status:404)` and `result{subtype:"success", is_error:true, result:<same text>,
api_error_status:404, terminal_reason:"api_error"}`. After `set_model haiku` the next
prompt worked.

### Second prompt while a turn is running

Sent during the first turn's deltas: it is **queued**. Nothing is printed for it while
the first turn runs (no replay yet). After the first `result` (`result_index:0`) the queued
prompt starts a normal turn (`init, status, user(replay of it), ..., result(result_index:1)`).
The replay is therefore the "turn started" signal for that prompt, not an
acknowledgement of receipt. (`interrupt`'s `still_queued` lists queued prompts.)

### Slash command (`/context`)

Sent as a normal prompt with text `/context`: `init`, then **no status and no replay**,
`A(message.model:"<synthetic>", content[{type:"text", text:"<markdown output>"}],
local_command_run{command:"context", args:""}, local_command_source:
"<local-command-stdout>...</local-command-stdout>", context_usage{...})`,
`result{subtype:"success", is_error:false, num_turns:0, result:<same text>,
local_command:"context"}`. No stream events.

### Transcript records for commands and interrupts

What Claude writes to the transcript file, compared with what the stream shows (the plugin's
history view must equal the live view):

- `set_model` between turns: three `user` records: `isMeta:true` with string content
  `<local-command-caveat>...</local-command-caveat>`, then `<command-name>/model</command-name>
  <command-message>model</command-message> <command-args><name></command-args>`, then
  `<local-command-stdout>Set model to ...</local-command-stdout>`. The stream shows only the
  last one (as a replayed user message). A `set_model` sent while a turn runs is applied, and
  recorded, after that turn's `result`. Before the first prompt it writes and prints nothing.
- `set_permission_mode`: no conversation records.
- A local slash command sent as a prompt (`/context`): the caveat record, the
  `<command-name>/context</command-name>` record, then `{type:"system",
  subtype:"local_command", content:"<local-command-stdout><output>\n\n</local-command-stdout>",
  level:"info"}`. The stream's `assistant` text (with `local_command_run`) equals `<output>`
  without the trailing blank lines.
- Interrupt: the aborted `assistant` text block (same text as streamed), then a `user` record
  with `content[{type:"text", text:"[Request interrupted by user]"}]` and no `isMeta`.
- `@` mentions: a mentioned file adds an `attachment` record `{type:"file", filename, content}`
  after the prompt.

The parser therefore drops the caveat records, reads `system/local_command` output as
`command output`, and reads the interrupt marker as `meta`; the Session records a
`/model <name>` prompt before the output of its own `set_model`.

### `@` mentions with spaces

`@my notes.txt` attaches nothing (the mention ends at the space; Claude answered that no
file was attached), and neither does `@my\ notes.txt`. `@"my notes.txt"` attaches the file
(an `attachment` record of type `file` follows the prompt). The plugin's `[attach] <path>`
line becomes `@"<path>"` when the path holds whitespace. A path that itself contains `"`
was not tried.

### User question (AskUserQuestion)

Prompt asking for one multiple-choice question: `... A(tool_use AskUserQuestion,
input{questions[{question, header, options[{label, description}], multiSelect}]})`,
`control_request(can_use_tool, tool_name:"AskUserQuestion", input{questions[...]},
tool_use_id, requires_user_interaction:true)`. Answer it with **allow** and
`updatedInput` = the input plus `answers{"<question text>":"<chosen label>"}`. Then
`control_response(echo)`, `user(tool_result content:"Your questions have been answered:
\"<q>\"=\"<label>\". ...", tool_use_result{questions, answers})`, and the turn continues.

For `multiSelect:true` the answer is the chosen labels joined by `", "` in one string
(`answers{"<question>":"A, C"}`); Claude read both choices. An array of labels was accepted
too but shown to the model joined by `","`. The plugin sends the `", "` string.

### Plan approval (`--permission-mode plan`)

`init(permissionMode:"plan")`. Claude thinks, writes the plan with the Write tool to a
file under the user's Claude config directory (`<config>/plans/<name>.md`, allowed in plan
mode without an ask — note: a real side effect outside the project), loads the
`ExitPlanMode` tool through `ToolSearch`, then calls it:
`A(tool_use ExitPlanMode, input{plan:"<markdown>", planFilePath})`,
`control_request(can_use_tool, tool_name:"ExitPlanMode", input{plan, planFilePath},
tool_use_id, requires_user_interaction:true)`.

- Approve and choose the next mode: add `updatedPermissions:[{type:"setMode",
  mode:"acceptEdits", destination:"session"}]` to the allow answer. Plan mode then ends in
  `acceptEdits` (`system/status{status:null, permissionMode:"acceptEdits"}`) and the
  implementing Write ran without an ask. The ask itself carries no `permission_suggestions`.
- Approve: answer `allow` with `updatedInput` = input. Then `control_response(echo)`,
  `system/status{status:null, permissionMode:"default"}` (plan mode ends, back to manual),
  `user(tool_result "User has approved your plan. ...", tool_use_result{plan, isAgent,
  filePath})`, and Claude starts implementing in the same turn (further asks come as
  ordinary `can_use_tool`).
- Reject: answer `deny` with a message. `control_response(echo)`, `user(tool_result
  is_error:true, content:<message>)`, Claude replies with text, `result(is_error:false,
  permission_denials[{tool_name:"ExitPlanMode", ...}])`. Mode stays `plan`.

### Subagent (Agent tool)

`A(tool_use Agent, input{description, subagent_type, prompt})`,
`system/background_tasks_changed`, `system/task_started`, `user(tool_result: "Async agent
launched ...", tool_use_result{isAsync:true, status:"async_launched", agentId, ...})`, the
main turn continues, the subagent's messages arrive as `assistant` with
`parent_tool_use_id:"<the Agent tool_use id>"` and **no stream events at all** for them,
then `task_updated`, `task_notification`, `background_tasks_changed`, the main `result`,
and then **a new turn starts on its own** (no prompt, no replay): `init, status, ...,
result{origin{kind:"task-notification"}}`.

### Thinking

Seen inside other scenarios: `content_block_start(thinking)`, `system/thinking_tokens`,
`thinking_delta(thinking:"")`…, `signature_delta`, `A(thinking:"", signature)`,
`content_block_stop`. No thinking text is ever delivered.

## Decoder mapping

`lua/agent-ide/claude/stream.lua`: `stream.new()` → decoder; `decoder:feed(obj, raw)` →
Action list (see the Action table in the plan). It never raises: a handler error or a
non-table object gives `unknown`.

| observed object | Action |
|---|---|
| `system/init` | `init{session_id, model, mode (permissionMode, default→manual), slash_commands, version (claude_code_version)}` |
| `system/status` | `status{mode? (default→manual), busy = true when status == "requesting"}` |
| `system/thinking_tokens`, `system/background_tasks_changed` | nothing (a token estimate; the task list repeats the task_* objects) |
| `system/task_started` | `is_backgrounded:false` (a foreground task, shown by its own tool call): nothing, and nothing for that task's later objects. Otherwise `event{meta, label "task started: <description>", text "<subagent_type or task_type> (<task_type>, in the background)", "prompt: …", "task <id>, run <id>, tool call <id>"}` |
| `system/task_updated` | `event{meta, label "task <patch.status>: <description or task id>", text: the other patch fields as "key: value"}`; nothing for a foreground task |
| `system/task_notification` | `event{meta, label "task <status>: <description or task id>", text: summary, "<n> tokens, <n> tool uses, <duration>", "output: <output_file>"}`; nothing for a foreground task |
| `system/hook_started`, `system/hook_response` | nothing; if `outcome == "error"`, a non-zero `exit_code` or an `error` field: `event{meta, label "hook", text "<hook_name>: <stderr or output or error>"}` |
| any other `system/<subtype>` | `unknown{label "system/<subtype>", raw}` |
| `stream_event` text_delta, main thread | `delta{text}`; marks the current content block as streamed |
| `stream_event` text_delta whose `parent_tool_use_id` is a string | nothing (dropped). Not observed: subagent messages came only whole. Main-thread blocks were always followed by their full `assistant` object, so the full message is expected to follow; see Open questions |
| `stream_event` content_block_start | nothing; a main-thread one resets the streamed mark (a subagent's does not) |
| `stream_event` message_start, content_block_stop, message_delta, message_stop; deltas input_json, thinking, signature | nothing (the full `assistant` object carries the same content) |
| `stream_event` other inner type / delta type | `unknown{label "stream_event/<type>" or "stream_event/content_block_delta/<delta type>", raw}` |
| `assistant` | `event` per content block through `transcript/parse.lua` block rules (`text`, `thinking` if non-empty, `tool_call`, `image` as `meta{label "image"}`, `unknown`). A `text` event whose block was streamed carries `streamed = true` on the action. A `tool_use` id already reported is not reported again. `parent_tool_use_id` a string → `sidechain = true`. With `local_command_run` (slash command output) the text becomes `event{meta, label "command output"}`. API error messages (`error` field) are plain `text` events; the failure is in `result.is_error` |
| `user` with `isReplay:true`, not command output | `echo{text}` |
| `user` with string content `<local-command-stdout>…` (replayed or not) | `event{meta, label "command output", text}` with `command_stdout = true` on the action (the Session puts a `/model <name>` prompt before it when its own `set_model` is pending) |
| `user` tool results | `event{tool_result}` (sidechain when `parent_tool_use_id` is a string) |
| `user` other text (interrupt marker) | `event{meta, label "meta", text}` — never `prompt` |
| `control_request/can_use_tool` (incl. AskUserQuestion, ExitPlanMode) | `permission{request_id, tool_name, input, description, suggestions (permission_suggestions)}` |
| other `control_request/<subtype>` | `unknown{label "control_request/<subtype>", raw}` |
| `control_response` success | `control_ok{request_id, response}` — also for Claude's echo of our permission answers |
| `control_response` error | `control_error{request_id, error}` |
| `rate_limit_event` | `quota{windows = name → {utilization, resets_at}}` from `unifiedWindows`; without it `unknown` |
| `result` | `result{is_error, text (result, else errors joined)}`; resets the streamed mark |
| anything else | `unknown{label "<type>" or "<type>/<subtype>", raw}` |

The sidechain test is `type(parent_tool_use_id) == "string"`: JSON `null`, whether decoded
as an absent key or as `vim.NIL`, means the main thread.

A failed hook's text falls back to the original line (`raw`) when it has no non-empty
`stderr`, `output` or `error`.

User questions and plan approvals both arrive as `can_use_tool`, so they are `permission`
actions; the Session tells them apart by `tool_name` (`AskUserQuestion`, `ExitPlanMode`).

### Silent by design

`feed` returns no action for:

- `assistant` thinking blocks with empty `thinking` (all thinking seen here), and
  `assistant` / `user` messages whose `content` is an empty array. (Other non-string
  content is not silent: for `assistant` it becomes an `unknown` event, as in the
  transcript parser; for `user` an `unknown` action.)
- `stream_event` `content_block_start` of any block type (text, tool_use, thinking);
  `message_start`, `content_block_stop`, `message_delta`, `message_stop`.
- `content_block_delta` of kinds `input_json_delta`, `thinking_delta`, `signature_delta`.
- `text_delta` from a subagent (string `parent_tool_use_id`).
- `system/thinking_tokens`.
- `system/hook_started` and `system/hook_response` without an error.
- A `tool_use` block whose id was already reported.

## Open questions

- Whether subagent (`parent_tool_use_id`) messages can ever stream deltas; none did here,
  so dropping them is safe only if their full `assistant` object always follows.
- Exact values of `hook_response.outcome` (only the field names were looked at); the
  decoder treats `"error"` or a non-zero `exit_code` as a failure.
- How an AskUserQuestion "Other / free text" answer is expected (only option labels were
  tried).
- `addRules` with destinations other than `localSettings`, `addDirectories`, and rules with
  `behavior:"deny"`.
- Thinking text: always empty here (`thinking_display:"updates"`); whether another
  setting delivers thinking text was not explored.
- Other `control_request` subtypes from Claude (hooks, MCP) were not seen.
