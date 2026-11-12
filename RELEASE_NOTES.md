## What has changed?

This release is about seeing what a session does and what it costs. The queue panel now shows the size of a conversation, the requests a turn makes, its subagents and its todo list, and a branch's full diff opens in one buffer, so the work of a session can be reviewed without leaving Neovim. Asks from a session get a window of their own, and long conversations are easier to keep cheap.

**Highlights**

- **Full diff of a branch.** `gd` on a git row in the drawer or on a commit in the graph, or `:AgentsDiff`, opens every change of a branch in one read-only buffer, file by file with folds. The scopes are the branch against your working tree, its commits, one commit, and the uncommitted changes. `<CR>` on a line opens the side-by-side diff of that file, and [delta](https://github.com/dandavison/delta) colours the patch when it is installed.
- **The queue panel shows what a turn costs.** `Q` lists the prompts sent, running and queued. Below them it shows the conversation's size (marked `large` from 200 000 tokens on), how long the turn runs, how many requests it made, each subagent with its tool uses, the todo list and the background shells. A line marks a request that had to write the conversation to the cache again, and the turn's cost at API prices is given per model.
- **Queued prompts can be changed.** In the queue panel `e` opens a queued prompt in a buffer and `:w` puts the edited text back in its place, `dd` deletes it, and `J` and `K` move it down or up.
- **Long conversations cost less to continue.** The chat's winbar shows the size of the conversation beside the model. A send that resumes a parked session with a large conversation asks first: Send, Compact first, or Cancel (`context.confirm_resume = false` turns the question off). `<leader>aC` sends `/compact`, and parking offers to compact first.
- **Asks in a window of their own.** Permission requests, questions and plans open with the question on its own rows, the whole command or diff wrapped, then numbered choices. `j`, `k` and `<CR>`, or `1` to `9`, pick one, and `q` cancels. `chat.ask_picker = 'select'` keeps `vim.ui.select` if you prefer it.
- **Names and moves between sessions.** `r` on a session row names it, and the name shows in the drawer, the chat's winbar, buffer names and search results. `]s` and `[s` go to the next or previous session of the same project, and the Omarchy bar widget jumps to the terminal and tmux pane of a session.

**Fixes**

- Picking a model in one session no longer changes the others. A session that has answered before resumes with the model of its own last answer; the model last used is now only what new sessions start with.
- `<leader>ay` opens a pending permission, question or plan again after its window was closed without an answer. Before, the ask stayed blocked until you left the chat and came back.
- `<S-Tab>` no longer gets stuck when a session refuses a mode, for example leaving plan mode during a turn. The cycle skips that mode and stops at the mode in effect.
- Opening a session that another Neovim drives shows the "another Neovim drives this session" warning once and then the transcript from disk. Before, the attach was retried and the warnings piled up over the screen.
- Handing a session over to a tmux pane (`gT`) resolves a bare `claude` through your Neovim's `$PATH`. The pane used to inherit the tmux server's environment, where `claude` could resolve to a different binary that never started.

Plan mode has its own key now, `<leader>am`, which turns it on and back off. `<S-Tab>` cycles manual, acceptEdits and auto; add `'plan'` to `claude.modes` if you want plan mode in that cycle again.
