# Feedback round 1 (2026-11-10) — to analyse and fix after the final review

Given by the user while testing `full-build` before the drawer polish landed. Their words are quoted; the notes are the first analysis, not decisions. Nothing here is built yet.

## Items

1. **Help searchable.** "can we have `?` with shortcuts being searchable with `/` — e.g. I want to know how to change the model so I hit `?` and then `/` and type model to find it."
   - Note: the help float is a normal buffer, so `/` should already search; check why it does not (focus, `WinLeave` closing it when the command line opens, `nofile` + not modifiable is fine). One help for all panels, grouped, so a search for "model" finds it wherever it lives.

1.2 **Same shortcuts in every panel?** "if I'm on the drawer, wouldn't it be nice to change model too, or should that only be possible in the one box it's allowed?"
   - Note: session actions (model, mode, park, interrupt, answer, native hand-off, raw view) could work from the drawer on the session row under the cursor, and from the diff view for the session it belongs to. Proposal: one set of session keys, valid wherever a session is in focus or under the cursor.

2. **Changing the model, slash commands.** "how do I change model or infer slash commands e.g. `/models` or `/copy`? couldn't find that shortcut."
   - Today: model `<leader>aM`; mode `<S-Tab>`; slash commands by typing `/` on an empty prompt line (menu appears only after the session's first answer, because Claude lists its commands with each turn); `/copy` is replaced by yanking an answer (`yir` / `yar`).
   - Gaps: not discoverable (see 1); the `/` menu is empty in a new session until the first answer; screen-only commands such as `/model` do nothing useful when typed. Idea: map typed `/model` and `/copy` to the plugin's own actions, and fill the menu before the first turn from the last known command list of that project.

3. **Quota in the footer is wrong.** "the bottom bar … does not show the same as my Omarchy agent plugin (the Omarchy plugin was always correct) — it shows three bars with other percentages and a raw window key as label", while the system panel showed lower, current values with proper labels.
   - Measured: the plugin's stored values were about an hour old and predated a change of the limits. The plugin only learns quota from `rate_limit_event`s of turns it runs itself, so after the user's limits were reset it kept showing the old numbers. Omarchy's panel reads usage from another source (to be read from `~/.local/share/omarchy/shell/plugins/agents/`), independent of any session.
   - Also: the plugin shows percent LEFT, Omarchy and Claude show percent USED; `seven_day_overage_included` is a raw key, not a label; a "Fable Weekly" style per-model window exists.
   - To do: same data source as Omarchy (or `claude`'s own usage query) refreshed on a timer; show USED like Claude does; proper labels; mark values learned only from an old event as stale much sooner.

4. **Search preview does not show the match.** "if I search for 'neomd signature' the preview shows me neomd, but I can't see signature; can we toggle through the matches with `]n` `[n`?"
   - To do: preview scrolled to the best match with all query words highlighted; `]n` / `[n` step through matches inside the preview (and after opening the hit in the chat).

4.1 **`]c` / `[c` in the diff view do not jump.**
   - To analyse: the user's gitsigns maps `]c`/`[c` buffer-local on real files (their config falls back to native diff jumps "in diff mode"); the scratch side has no such map. Check which side fails and whether `diffopt`, folds or the mapping are the cause; the diff view must make `]c`/`[c` work on both sides without touching the user's maps elsewhere.

5. **Commit graph.** "one addition for git diff tree (merged branches visually) like GitKraken or SourceTree; that would help navigate the changes easily."
   - New feature: a graph view of branches and merges (`git log --graph` data, drawn with box characters), Enter on a commit opens its files/diff. Needs its own small plan.

6. **Nicer chat header.** "can you show the top name of which model, if auto mode etc., better, e.g. idle with the same colour as we use in the drawer, and model italic or similar."
   - To do: winbar with coloured state (same groups as the drawer), model in italic, mode as a badge; may partly arrive with the drawer polish.

7. **Different font for Claude's output.** "can we use a different font than my default terminal font (Iosevka) that is easier to read … e.g. Atkinson Hyperlegible … if the terminal does not allow, no problem."
   - Answer: not possible in terminal Neovim; a terminal draws every cell with one font. Only a GUI front-end could, and none offers per-window fonts in a useful way. Closest alternatives: wider line spacing / wrap column for the transcript window, or the markdown renderer's styling.

8. **Close sessions that run elsewhere, without jumping there.** "if I run alt-c for the old fuzzy finder I get a ton of idle; if I want to close the idle session (ctrl-c or exit in Claude) with a shortcut without jumping to the session within agents-ide.nvim, that would be great."
   - This reverses an earlier constraint ("the plugin never stops a Claude process it did not start"), now on the user's explicit request. Proposal: a key on a session row that runs in a tmux pane which ends that Claude gracefully (send `/exit` to its pane), only when it is idle, after a confirm; plus "close all idle sessions" with a count in the confirm. Never a kill signal; never on busy or waiting sessions without a second confirm.

9. **Legend for the state dots.** "can we add a legend of what the green round dot means, or yellow, in the bottom right of the drawer? … hide if there is not enough space, or toggle them with a shortcut."
   - To do: a legend line (or two) at the bottom of the drawer, toggle key, hidden when the drawer is too short; also listed in `?`.

99. **Worktrees.** "remove all worktrees that are merged, and keep main only."
   - Done 2026-11-10: the four merged agent worktrees and their branches were removed. Left: `full-build` (95 commits ahead of `main`) and the drawer-polish worktree (in progress, removed after it merges). Merging `full-build` into `main` is the user's step at hand-over.

10. **Misleading "saved" notice.** After `:w` in a session of a project the notice said `Agent-IDE: saved → Saved prompts/<project>/<name>`; the user looked for it in that project's repository. It is not there, and should not be: per-project saved prompts live in the plugin's data folder (`stdpath('data')/agent-ide/prompts/<project>-<hash>/`), only library prompts go to `library_dir`.
   - The notice names the drawer section, which reads like a path. To do: say what and where in words, e.g. `saved as a project prompt of <project>: <name> (e on its drawer row opens the file)`, and for the library `saved to the library: writing/linkedin-post`. README: one sentence on where each kind lives.

11. **`/` menu cannot be filtered.** "writing `/` and then typing `model` gives me `/__remote-workflowmode` instead of `/model` — the list comes up, but the typing does not work, I can't arrow-down the 1000 entries, I need a search."
   - Cause to confirm: the completion inserts the first candidate as soon as the menu opens (the buffer-local `completeopt` was removed in review, so the user's global setting applies), so further typing no longer narrows from `/`. Also `/model` is not in Claude's list at all (screen-only command).
   - To do: the `/` menu must narrow while typing and never insert before the user chooses (`noinsert,noselect` for this completion only, fuzzy matching), or be a small filterable picker; add the plugin's own entries for screen-only commands that have an equivalent (`/model` → model picker, `/copy` → yank last answer, `/clear`/`/resume` → explain or map), marked as plugin actions. See also item 2.

## Appendix: the user's mock compared with the real views (from the drawer polish, 2026-11-10)

The drawer now follows the mock. For the other scenes of `mock.lua`, what the mock shows that the real view lacks or does differently, for the user to choose from:

| Scene | Difference | Size |
|---|---|---|
| g1 chat | Winbar with icon, coloured state icon and key hints on the right (real: plain `project · title · model · mode:x · state`); a winbar on the prompt window with key hints (real: none); richer fold headers: thinking with duration, `Read: file (n lines)`, `Edit: file +4 −1 (<CR> opens the diff)`, `Agent: Explore "…" (n tool calls)`, `● waiting for permission` on the pending fold | winbars small; fold headers medium |
| g2 permission | A centred float with the command, a description and single-letter keys `[a]/[s]/[d]/[e]`, violet border (real: `vim.ui.select` with Allow, Deny, suggestions) | medium |
| g3 slash | A float with description and a kind column (skill, built-in, command) (real: native completion, names only) | medium |
| g4 model/mode | One float listing models and modes with `●` on the current ones (real: model picker `<leader>aM`, mode cycles with `<S-Tab>`) | medium |
| g5 diff | Winbars with icons and key hints (real: `base origin/main (rev) · path · file i/n`, no hints) | small |
| g6 raw | Winbar with project, title, event count and hints; a `gs` "sent text" key (real: `raw · <id8> · >> sent << received · q: back`, no `gs`) | small; `gs` medium |
| g7 running elsewhere | Winbar `running in tmux pane 2.1 · read-only`; a red "sending refused" bar with the `gp` hint in the prompt (real: live state in the winbar, a notice on send) | small to medium |
| g8 prompt library | Prompt winbar showing where the text came from and `:w / ZZ update file · <leader>W save · <C-CR> send` (real: no prompt winbar) | small |
| g9 search | One-line rows: project, state icon, title, age, snippet; no preview (real: kind tags, preview pane, footer) | medium |
| g0 help | One float grouping Drawer, Chat and Anywhere with highlighted keys (real: one help per view) | small |
| footer | Several segments (`● input required (2)`, `◐ 3 running · ✔ 1 done · <leader>an next`) plus quota bars (real: one level text, model, quota) | medium |

Items 1, 1.2, 2, 6 and 11 above overlap with g0, g3, g4 and g1.
