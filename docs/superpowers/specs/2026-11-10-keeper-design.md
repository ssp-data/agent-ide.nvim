# Keeper: Claude sessions that outlive Neovim (2026-11-10)

**Goal.** Quitting Neovim must not end a Claude process the plugin started, busy or idle. A new Neovim must reattach to it and show the live transcript, state, pending asks and queue, exactly as if it had never left.

**Constraints** (AGENTS.md): rule 9 (never signal a Claude the plugin did not start; never two drivers for one session), rule 5 (subscription only, no API key, no network), rule 8 (writes only in the plugin's runtime/state folders, 0600/0700, atomic), rule 6 (works without the Rust helper), rule 3 (nothing synchronous on a keystroke), rule 1 (fidelity: the reattached transcript equals the one the first Neovim had).

## Shape

One **keeper per Claude process**: a small headless Neovim (`nvim --headless --clean -l lua/agent-ide/keeper/main.lua …`, Lua only, no helper) started detached (own session, survives the parent) that owns the `claude -p` pipes. It is a dumb, faithful pipe owner: every line Claude writes is kept in order (a ring of the last 5000 lines, like the raw view) and forwarded to the one attached Neovim; every line a Neovim sends goes to Claude and into the same log. It never interprets the protocol beyond what the drawer needs (a coarse state) and the queue hand-over below.

```
Neovim A  ──socket──▶  keeper-<session id>  ──pipes──▶  claude -p … --session-id/--resume <id>
   quit                 (keeps running)                     (keeps running)
Neovim B  ──socket──▶  attach: replay, then live
```

**Files, all in `$XDG_RUNTIME_DIR/agent-ide/` (else `stdpath('run')/agent-ide/`, 0700):**

| File | Holds |
|---|---|
| `keeper-<session id>.sock` | the Unix socket (0600) |
| `keeper-<session id>.json` | `version, session_id, cwd, path (transcript), keeper_pid, claude_pid, started, offset (bytes of the transcript when Claude started), state (busy/waiting/idle), attached (true/false), queued (count), updated`; rewritten atomically on every change, so a drawer can show the session without connecting |

Both go when the keeper exits. A file whose `keeper_pid` is not running is stale and ignored (and removed).

**Socket protocol:** newline-delimited JSON, one client at a time (rule 9: a second `attach` is answered `busy` and closed).

| Direction | Message | Meaning |
|---|---|---|
| client → keeper | `{"op":"attach"}` | become the driver |
| keeper → client | `{"op":"hello", …the json file fields…, "queue":[…]}` | accepted; the queue the keeper holds comes back to the Neovim |
| keeper → client | `{"op":"line","dir":"in"|"out","line":"…"}` × n, then `{"op":"synced"}` | the replay: every line sent to and received from Claude since it started, in order; then live lines as they come |
| client → keeper | `{"op":"send","line":"…"}` | one line to Claude's stdin (also logged) |
| client → keeper | `{"op":"queue","items":[…]}` | the prompts queued in Neovim, handed over (sent on detach) |
| client → keeper | `{"op":"stop","now":bool}` | close stdin, SIGTERM after the grace period (park, `x`, interrupt-then-park): the plugin stopping a process it started |
| client → keeper | `{"op":"detach"}` or the socket closing | the Neovim is gone; Claude keeps running |
| keeper → client | `{"op":"exit","code":n,"signal":n,"stderr":"…"}` | Claude ended; the keeper exits right after |

**What the keeper does on its own:** when no Neovim is attached and a turn ends (a `result` line) and it holds queued prompts, it sends the next one, so a queue keeps going through the night; when nothing is attached and Claude has been idle for `keeper.idle_minutes` (default 30; `false`: never), it closes stdin (Claude exits on its own, the session resumes from disk later; nothing is lost); when its socket client dies without `detach` (a crashed Neovim), that is a detach.

## Neovim side

- **Starting** (`claude/process.lua`): with `keeper.enabled`, `process.start` spawns the keeper (the same argv, cwd and API-key-stripped environment as today, plus the socket, json and transcript paths) and attaches; what Session gets back has the same interface as the direct process (`send`, `stop`, `alive`, `pid`), so `session/object.lua` and `actions.lua` do not change for the live case. Without a keeper (disabled, or `nvim` not found on PATH) the direct process is used as today.
- **Quitting:** `VimLeavePre` hands the queue to the keeper and detaches instead of stopping; the quit guard no longer asks (nothing is lost) and says `n session(s) keep running in the background` once.
- **Finding keepers:** `keeper.list()` reads the json files (asynchronously, on the drawer's live poll). The drawer shows such a session with the keeper's state and the dim word `background` (`tmux …`/`elsewhere` are for other Claudes); the footer, `<leader>an` and the status file count it; the Claude pid of a keeper is never `elsewhere` for `_elsewhere()`.
- **Reattaching** (`Session:attach`): opening the session (or sending to it) connects. The transcript before the keeper's Claude started is read from disk up to `offset` bytes (Lua parser; the helper is not involved), then the replay is decoded through the same stream decoder and action handlers the live path uses, in batches of 200 lines per tick (rule 3); sent lines of type `user` become prompt events, sent `control_response` lines settle their asks. The result is the first Neovim's events, streaming text, pending asks, model, mode, commands and state, exactly (fidelity), then live lines continue. Drawer rows of keeper sessions open the chat as any session does.
- **Keeper lost** (socket closes without `exit`): the session is parked with an `error` line `keeper lost`; Claude, without its pipes, exits on its own. **Claude lost:** the `exit` message takes the exact path `on_exit` takes today.
- **Two Neovims:** the second one opening the session sees `busy` from the keeper and is told `another Neovim drives this session` (same words and behaviour as `elsewhere` today); `gT` is not offered.

## Settings

```lua
keeper = { enabled = true, idle_minutes = 30 }  -- enabled = false: Claude is a child of Neovim, as before
```

**Default:** `enabled = true`, approved by the owner on 2026-11-10 together with this plan (the queue hand-over included). With `false` nothing changes.

## Tests (fakes only, no real Claude)

`tests/test_keeper.lua`, with `tests/fake_claude.lua` as the Claude: a session starts through a keeper (json and socket exist, lines stream as before, the chat suite's checks hold); the child Neovim quits with `:qa!` while the fake is mid-turn (`sleep_ms`), the fake's process is still alive; a new child attaches: the transcript shows the earlier prompt and the streamed text, the state is busy, the result arrives and it turns idle; a permission ask raised while no Neovim was attached shows on reattach and is answered; queued prompts handed over are sent by the keeper at the end of the turn and listed again on reattach; a stopped keeper parks the session; the idle timeout ends an idle Claude; `enabled = false` keeps today's behaviour (the process is stopped on quit); stale json files are ignored and removed; a second Neovim is refused. Pure tests for the NDJSON framing and the keeper's state machine.

## Docs

README (a "Background sessions" section: quit behaviour, the `background` word, the settings, the two files in the privacy list), CHANGELOG, AGENTS.md (layout: `keeper/`; rule 9 gains the sentence that a keeper is the plugin's own process, so stopping its Claude is stopping a process the plugin started).

## Not in this round

A status file written by the keeper for the Omarchy bar while no Neovim runs (it would double-count with an attached Neovim's file; needs a merge rule). Keepers for `--resume` of sessions run in native Claude. Tmux-pane Claudes are untouched.
