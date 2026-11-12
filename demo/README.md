# Demo

`make demo` starts Neovim on synthetic data under `/tmp/agent-ide-demo`, rebuilt on every run. It runs the plugin from this checkout, so whatever you just built is what you see. It opens the drawer, starts the scenario sessions, opens every row (`z9`) and the lineage session with its queue panel (`Q`), and then you drive it to take screenshots.

`AGENT_IDE_DEMO_SHOT=chat make demo` (what `scripts/demo-screenshot.sh` uses) and `AGENT_IDE_DEMO_SHOT=graph make demo` set up the README screenshots the same way every time.

## What is in it

| Feature | Where | Keys |
|---|---|---|
| Sessions grouped by repository, branches | `dataflow`, `dataflow-docs`, `neomd`, `ssp-blog` | `<leader>a`, `z9` opens all, `]s` / `[s` between sessions |
| A permission waiting | `Backfill 2025 partitions` (dataflow) | `<CR>` on the row, `<leader>ay` in the chat |
| A question waiting | `Add HTML email preview` (neomd) | same |
| A plan to approve | `Grammar pass on data contracts post` (ssp-blog) | same |
| Done, unread, with a whole turn in the queue panel: cache written again, requests, tokens, cost per model, todos, a finished subagent | `Fix flaky dbt test on customers` (dataflow) | `Q` |
| **Everything in one chat**: a prompt with an `@` file, SQL and a table in the answer, an `Edit` as an inline diff with the changed words marked, coloured `git status` and a delta diff from Bash; running now with queued prompts, todos, a subagent and a background agent, a background shell, thinking; a draft with an attached file in the prompt; uncommitted changes for `gd` | `Document lineage for the docs site` (dataflow-docs) | `<CR>` on the row, `Q`, then `e`, `dd`, `J`, `K` on a queued prompt |
| Failed | `Migrate config to TOML` (neomd) | |
| Running elsewhere (busy, idle) | the two `blog` sessions (ssp-blog), from `live.json` | |
| A large conversation (`▲ large`), the question before a resume | `Explain the DuckDB lineage graph` (dataflow, ~232k) | `Q`; send a prompt |
| A long chat with tools and tables | `Incremental load for the orders model` (dataflow, ~77k) | `<CR>` |
| An `Edit` as an inline diff (added lines, context, the rest counted) | same chat | `gd` on the fold opens the file's diff |
| Bash output in its colours: a diff through delta, a `git log --graph` | same chat | |
| The model and size in the winbars | every chat; sessions without a model start with `prefs.json`'s | |
| Names | any session row | `r` |
| Uncommitted changes, branch commits, full diff | dataflow on `feat/incremental-orders` | `Changes` rows, `gd`, `:AgentsDiff` |
| Commit graph with a merged side branch | dataflow | `:AgentsGraph`, `gd` on a commit |
| Prompt library, saved prompts, commands, skills | `prompts/` | `Prompts` in the drawer, `/` in a prompt |
| Quota in the footer | `quota.json`, stamped at start | |

Every past session has a size (the usage of its last answer in `history/`). The sessions above that run start a few seconds after Neovim; the done one finishes after about five seconds.

## Adding to it

A new view needs nothing here. Add data only when a feature needs something the data above doesn't have:

- a past session: a `.jsonl` file in `history/<repo>/` (the format of Claude's own transcripts);
- a session that runs when the demo starts: a scenario in `scenarios/<session id>.jsonl` (the steps of `tests/fake_claude.lua`) and an entry in `run_scenarios` in `init.lua`;
- files or commits: `scripts/demo.sh`, which builds the repositories from `repos/`.

Keep everything synthetic: no real paths, projects, session ids or transcripts.
