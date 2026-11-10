# Feedback round 2 (2026-11-10): keys, help, model, graph, drafts

The owner's feedback after using the first version. Their asks are quoted or paraphrased; where a reading had to be chosen, the choice is marked **call**. Built in this round.

## 1. Keys

Every drawer key becomes configurable under `keys.drawer` (a key, a list, or `false`, like every other key option). New defaults:

| Action | Was | Now |
|---|---|---|
| open / toggle | `<CR>`, `o` | same |
| toggle fold | `za` | same |
| collapse all | `zM` | `z0` |
| expand all | `zR` | `z9` |
| refresh | `R` | same |
| to tmux: jump to the pane of a session running elsewhere; a session here: continue it in native Claude in a tmux pane | `gp` (jump), `<leader>at` (native) | `gT`, `<leader>aT` (one key: the row decides) |
| search this project | `s` | `Z`, `<leader>ff`, `<leader>Z` |
| park | `x` | `sP` |
| hide | `H` | same |
| delete (a session: to the trash; a prompt row: its file) | `D` session, `d` prompt | `D` for both |
| lazygit | `glg` | same |
| close drawer | `q` | same |
| help | `?`, `g?` | same |
| commit graph | `gG` | `G` |
| scope: this project / all | `gs` | `S` (**call**: the owner wrote "Shift-Toggle"; `<S-Tab>` is the mode cycle on session rows, so `S` for Scope; `keys.drawer.scope` changes it) |
| legend | `gL` | `gL`, `<leader>aL` |
| close a tmux Claude | `X` | same |
| yank | `y` on prompt rows only | `y` also on a session row: its last prompt (**call**: "the prompt's text" of a session is the last prompt sent in it) |
| saved prompt to the library | `L` | `sL` |
| model (chat and session row) | `<leader>aM` | `<leader>aM`, `<leader>M` |
| native Claude (chat) | `<leader>at` | `gT` (transcript only: the prompt buffer is where the user edits text) and `<leader>aT` |
| search picker: what to search | `<C-t>` | `<C-f>` (`<C-t>` is the owner's tmux prefix) |

Rule change: a provider's row key (edit, rename, delete, yank, to library) runs on its own rows even when a drawer key has the same lhs; elsewhere the drawer key acts. Before, the drawer key always won.

## 1.2 Help you can filter

`?` / `g?` opens a palette: a query line (insert mode) over the list of keys; typing filters fuzzily (`matchfuzzypos`), `<C-n>` / `<C-p>` / `<Down>` / `<Up>` move, `<CR>` closes the help and presses the selected key in the window the help came from, `<Esc>` leaves insert mode, `<Esc>` or `q` in normal mode closes. With an empty query the groups (headings) show as before.

## 1.3 Legend

`gL` (and `<leader>aL`) toggles the legend; the toggle is now remembered across restarts (`prefs.json`). **call**: the owner asked to toggle it, which `gL` did already; remembering it is the missing part.

## 1.4 "done"

Not a change. `done` is Claude's turn ending while the chat was not on screen; looking at the chat makes it `idle`. There is no manual marking; `H` hides a session.

## 2. Model before the first prompt

The winbar (and the footer) show the model a session will start with before any prompt is sent: the model picked for it, else `claude.model` when set, else the last model used in this plugin (the last one picked or reported by Claude, kept in `prefs.json`), else Claude's own default (shown as `default`). New sessions start with that model (`--model` for a new session, a `set_model` request on resume, as the picker already does).

## 3. Graph in the drawer

An expanded `Commits on branch` / `Recent commits` section starts with a dimmed row `commit graph · G`; `<CR>` on it opens the graph. `G` works on every row of a git project as before.

## 4. Drafts never lost

The prompt buffer's text is written to `stdpath('state')/agent-ide/drafts/<session id>.md` (0600 in a 0700 folder, atomic), half a second after it changes and when the window or Neovim is left. The file goes with a successful send, with `:q!` (the explicit discard) and when the session is deleted. Opening a session whose prompt is empty brings the draft back with a notice. `+ New session` in a project takes over the newest draft of an unsent new session of that project that an earlier Neovim left behind. The file holds a small frontmatter (session id, project folder, time) and the text as typed.

## 99. README and hand-over

README: the freeze note moves out (AGENTS.md keeps it), Status and Roadmap merge, keys updated. `HANDOVER.md` is removed; what was still open moves into AGENTS.md.
