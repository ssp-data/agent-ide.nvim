You are drafting the GitHub release notes for Agent-IDE.nvim {{VERSION}} (a Neovim plugin that manages Claude Code sessions from inside Neovim: a drawer of sessions per repository, a chat in native buffers, git review, search over all sessions, reusable prompts, a statusline and an Omarchy bar widget). Write them to the file RELEASE_NOTES.md in the current directory, overwriting it. Do not commit, do not touch any other file, do not run the test suite.

Sources, in this order of authority:
1. CHANGELOG.md, the `## [Unreleased]` section at the top: everything since the previous release {{PREV}}, under Added, Changed, Fixed and Removed. Each bullet there already explains what changed and why; condense, do not copy.
2. `git log --no-merges --format='%s%n%b' {{PREV}}..HEAD` for anything the changelog missed. Subjects name the part of the plugin first (`queue panel: …`, `drawer: …`); bodies explain the why.
3. README.md, only to phrase a feature the way the documentation does (key names, option names, highlight groups).
4. The current RELEASE_NOTES.md, if it exists, only as a template for shape and tone; its content belongs to the previous release and must be replaced.

Structure (exactly this, Markdown):

## What has changed?

<Two or three sentences a user can read in ten seconds: the one theme of this release and what it means when they work with their sessions in Neovim. No commit hashes, no function names.>

**Highlights**

- 3 to 6 bullets. Each starts with a bold lead phrase, then one or two sentences. User-visible behaviour first; name the key, command or option in backticks when there is one (`gd`, `:AgentsDiff`, `context.large`). Skip internals unless they change what the user sees or configures.

**Fixes**

- Bullets for bugs a user could have hit, phrased as what went wrong and what is true now. Group small related ones into one bullet. Omit test-only, docs-only and refactor work.

<Optional last line: one sentence on how to update, or a pointer to a README section, only if it earns its place.>

Rules: plain English, no marketing adjectives, no exclamation marks, no emoji, no headings other than the one `##` above and the two bold labels. Do not mention this prompt, Claude, or AI. Never put personal paths, private project names or session ids into the notes; the repository is public. If the range since {{PREV}} contains nothing user-visible, say so in the intro and leave the bullet sections short rather than inventing content. Finish by printing the file's first ten lines so the caller can see it was written.
