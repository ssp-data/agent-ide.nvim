# Drawer polish: right-aligned columns, state words, nerd-font icons

Goal: the drawer looks like the user's mock (state icon on the left, state words and ages
right-aligned in colour, a header line, nerd-font icons by default) without changing keys or
behaviour, and the README lists the prerequisites.

## Changes

1. `lua/agent-ide/ui/layout.lua` (new, pure): display width with an ASCII fast path,
   `truncate(text, width)` that never splits a character (`…` at the end), and
   `row(left, right, width)` that pads the right part to the right edge and shrinks the
   pieces flagged `fit` (last first) so the right part stays visible. Without a width the right
   part follows the left after two spaces (pure tests stay readable).
2. `lua/agent-ide/ui/icons.lua` (new): `nerd` and `plain` sets, `resolve(style, overrides)`,
   `prefix(icon)` (`icon .. ' '`, or nothing for an empty icon).
3. `config.lua`: `icons_style = 'nerd'` (default) or `'plain'`; `icons` holds overrides of
   single entries; `config.get().icons` is the resolved table.
4. `tree.lua`: rows as left/right; session rows carry a state word (from `note_of`) and the
   age on the right; project rows carry `input (n)` / `review (n)` plus the age; labels
   `(folder missing)` and `<subpath>/ · <title>`; optional header row (`opts.header`);
   provider rows may carry `right`; ages up to months and years.
5. `drawer_model.lua`: `note_of(id, state)` -> `{ text, group }` (permission/question/plan,
   done, failed with reason, native, tmux pane, elsewhere).
6. `tmux.lua`: async cached pid -> `window.pane` labels, refreshed with each live poll.
7. `drawer.lua`: header line from the drawer's own key table, re-render on resize
   (debounced), cursor below the header on open, tmux label refresh on poll.
8. `git_sections.lua`, `prompt_sections.lua`: `right` for `+a −d`, commit ages and the
   `project` tag; section, worktree and entry icons.
9. `highlights.lua`, `git_hl.lua`: failed red with its own colour, waiting bold, git status
   colours from the mock.
10. Tests: `test_layout.lua` (new; widths, umlauts, CJK, emoji, 300-char titles, width 24),
    `test_icons.lua` (new; nerd set covers plain keys, no empty or wide values), state words,
    ages, header; updated expected strings; deterministic fixture order (fixture copies with
    fixed mtimes); one budget case with 60 projects and 300 visible rows.
11. README: Prerequisites table, settings block, configuration and status lines.

## Not in scope

The differences between the mock's other scenes and the real views are listed in the report
for the user to choose from; only trivial wording falls out of this work.
