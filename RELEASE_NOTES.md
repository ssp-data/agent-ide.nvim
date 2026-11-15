## What has changed?

This release turns the full diff into a place to review a session's work. You can comment on any line of a branch's changes, and send all comments in one prompt to the session that wrote them, without leaving Neovim. Comments stay in the plugin's own state folder, never in your repository.

**Highlights**

- **Review comments in the full diff.** `c` on any line opens a small window for a comment, typed as `BUG:`, `ISSUE:`, `NOTE:`, `DESIGN:`, `SUGGESTION:` or `QUESTION:` (your own kinds go under `review.kinds`). Comments show under their line, coloured by kind, in every scope: the uncommitted changes, the branch, its commits, or one commit.
- **Send the review in one prompt.** `gs` in the full diff, `gs` on the drawer's `review (n)` row, or `:AgentsReview` puts every pending comment into the session's prompt, grouped by scope with each path, line and the line's text. The comments stay marked `↑ in prompt` until that prompt is sent, so you can add more first. `<C-CR>` in the comment window sends a single comment at once.
- **Back to the review from anywhere.** `<CR>` on the drawer's `review (n)` row or `<leader>ar` returns to the review, with the cursor on its newest comment. `<leader>ar` in the full diff goes the other way, to the chat of the review's session. `Discard all comments` in the finish dialog asks first.
- **Full diff from the drawer's Commits section.** The `full diff · gd` row is now a fold: `<CR>` lists the files of the branch's commits, and `<CR>` on a file opens the full diff with the cursor on that file. Without changes of its own, the branch lists its recent commits instead.
- **Clearer full diff.** The winbar names the file under the cursor in bold green and follows the cursor as you move. `]r` and `[r` step through the commented lines.

**Fixes**

- A branch with no commit of its own yet showed an empty `Commits on branch (0)`. It now lists `Recent commits` (the last 20), and the full diff's commits scope follows the same list.

The review workflow, and how it compares with other diff review tools, is described in `docs/review.md`.
