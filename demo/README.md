# Demo

`make demo` starts Neovim on synthetic data under `/tmp/agent-ide-demo`, rebuilt on every run. It runs the plugin from this checkout, so whatever you just built is what you see. It opens the drawer, starts the scenario sessions, and then you drive it to take screenshots.

`AGENT_IDE_DEMO_SHOT=chat make demo` (what `scripts/demo-screenshot.sh` uses) and `AGENT_IDE_DEMO_SHOT=graph make demo` set up the README screenshots the same way every time.

## What is in it

| Feature | Where | Keys |
|---|---|---|
| Sessions grouped by repository, branches | `dataflow`, `dataflow-docs`, `neomd`, `ssp-blog` | `<leader>a`, `z9` opens all |
| Waiting for a permission | `Backfill 2025 partitions` (dataflow) | `<CR>` on the row |
| Done, unread | `Fix flaky dbt test on customers` (dataflow) | |
| Failed | `Migrate config to TOML` (neomd) | |
| Running with queued prompts | `Document lineage for the docs site` (dataflow-docs) | `Q` on the row |
| Running elsewhere (busy, idle) | the two `blog` sessions (ssp-blog), from `live.json` | |
| A long chat with tools and tables | `Incremental load for the orders model` (dataflow) | `<CR>` |
| The model in the prompt's winbar | any chat; sessions without a model start with `prefs.json`'s | |
| Uncommitted changes, branch commits, full diff | dataflow on `feat/incremental-orders` | `Changes` rows, `gd` |
| Commit graph with a merged side branch | dataflow | `:AgentsGraph` |
| Prompt library, saved prompts, commands, skills | `prompts/` | `Prompts` in the drawer, `/` in a prompt |
| Quota in the footer | `quota.json`, stamped at start | |

## Adding to it

A new view needs nothing here. Add data only when a feature needs something the data above doesn't have:

- a past session: a `.jsonl` file in `history/<repo>/` (the format of Claude's own transcripts);
- a session that runs when the demo starts: a scenario in `scenarios/<session id>.jsonl` (the steps of `tests/fake_claude.lua`) and an entry in `run_scenarios` in `init.lua`;
- files or commits: `scripts/demo.sh`, which builds the repositories from `repos/`.

Keep everything synthetic: no real paths, projects, session ids or transcripts.
