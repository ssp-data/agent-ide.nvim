-- Where a review goes and how: which session (asked once per review, at its first comment),
-- the done step (`gs`, the drawer's `review (n)` row, `:AgentsReview`: the comments as one text
-- into the session's prompt above the draft or replacing it, or to the clipboard), and the
-- direct send of one comment (`<C-CR>` in the editor) through the chat's send path. Comments
-- put into a prompt stay in the review, marked, until that prompt is sent (or they are copied,
-- sent at once, or deleted); `gs` again rebuilds the whole text. The full
-- diff keeps its window throughout: the prompt opens below it, the chat is never opened here.
local api = vim.api
local config = require('agent-ide.config')
local review = require('agent-ide.review')
local review_text = require('agent-ide.review_text')

local M = {}

local function notify(msg, level) vim.notify('Agent-IDE: ' .. msg, level or vim.log.levels.INFO) end
local function select(items, prompt, done) require('agent-ide.ui.ask_select').select(items, prompt, done, { title = 'Review' }) end
local function session_mod() return require('agent-ide.session') end
local function fulldiff() return package.loaded['agent-ide.ui.fulldiff'] end
local function drawer() return package.loaded['agent-ide.ui.drawer'] end

-- The sessions of `project` as the drawer lists them now (newest first); a project made from a
-- root alone has none of its own, the drawer's entry with the same key or root does.
local function sessions_of(project)
  local d = drawer()
  local st = d and d.state()
  for _, p in ipairs(st and st.projects or {}) do
    if p.key == project.key or (p.root and p.root == project.root) then return p.sessions or {} end
  end
  return project.sessions or {}
end

local function meta_of(list, id)
  for _, m in ipairs(list) do
    if m.id == id then return m end
  end
end

local function name_of(id, title)
  return require('agent-ide.names').get(id) or title or 'new session'
end

-- `<name> (<state>, <age>)` of a drawer session entry.
local function label(m)
  local state = require('agent-ide.ui.drawer_model').state_of(m.id)
  local age = require('agent-ide.ui.tree').ago(m.activity or 0, os.time())
  return ('%s (%s, %s)'):format(name_of(m.id, m.title), state, age)
end

---The stored session of the review of `root` when it still exists (listed for the project, or
---loaded here): `{ id, title, cwd?, path? }`, else nil. With `opts.drop`, a stored id that is
---gone is forgotten, but only once the drawer has scanned (before that the list is empty and
---says nothing); a read from a winbar never drops anything.
---@param root string
---@param project table
---@param opts? { drop?: boolean }
---@return table|nil
function M.valid_session(root, project, opts)
  local id = review.session(root)
  if not id then return nil end
  local m = meta_of(sessions_of(project), id)
  if m then return { id = id, title = m.title, cwd = m.cwd, path = m.path } end
  local s = session_mod().get(id)
  if s then return { id = id, title = s.title, cwd = s.cwd, path = s.path } end
  local d = drawer()
  if opts and opts.drop and d and d.state().scanned then review.set_session(root, nil) end
  return nil
end

---The name of the review's session, for a winbar; nil when none is chosen.
---@param root string
---@param project table
---@return string|nil
function M.target_name(root, project)
  local t = M.valid_session(root, project)
  return t and name_of(t.id, t.title) or nil
end

---The choices of the session question: the chat the full diff was opened over when it is of
---this project, else the project's most recent session; a new session; another session.
---@param root string
---@param project table
---@return { kind: 'session'|'new'|'other', id?: string, label: string }[]
function M.candidates(root, project)
  local list = sessions_of(project)
  local out = {}
  local fd = fulldiff()
  local v = fd and fd.state()
  local chat = v and v.root == root and v.prev and v.prev.chat or nil
  if chat then
    local m = meta_of(list, chat.id)
    out[1] = { kind = 'session', id = chat.id, label = m and label(m) or name_of(chat.id, chat.title) }
  elseif list[1] then
    out[1] = { kind = 'session', id = list[1].id, label = label(list[1]) }
  end
  out[#out + 1] = { kind = 'new', label = '+ new session' }
  out[#out + 1] = { kind = 'other', label = 'another session…' }
  return out
end

---Ask which session the review of `root` goes to and store the answer; `cb(ok)` (false when
---cancelled). A new session is created in `root` (not opened); the drawer lists it.
---@param root string
---@param project table
---@param cb fun(ok: boolean)
function M.ask_session(root, project, cb)
  local name = project.name or vim.fs.basename(root)
  select(M.candidates(root, project), ('Review of %s: send the comments to which session?'):format(name), function(choice)
    if not choice then return cb(false) end
    if choice.kind == 'session' then
      review.set_session(root, choice.id)
      return cb(true)
    end
    if choice.kind == 'new' then
      local s = session_mod().open({ cwd = root })
      require('agent-ide.ui.drawer_model').add_unsaved(s.id, project.key or root)
      if drawer() then drawer().refresh() end
      review.set_session(root, s.id)
      return cb(true)
    end
    local rows = {}
    for _, m in ipairs(sessions_of(project)) do rows[#rows + 1] = { id = m.id, label = label(m) } end
    if #rows == 0 then
      notify('no sessions in ' .. name)
      return cb(false)
    end
    select(rows, ('Review of %s: which session?'):format(name), function(c2)
      if not c2 then return cb(false) end
      review.set_session(root, c2.id)
      cb(true)
    end)
  end)
end

---The review's session, asked for when none is stored (or the stored one is gone); `cb(ok)`.
---@param root string
---@param project table
---@param cb fun(ok: boolean)
function M.ensure_session(root, project, cb)
  if M.valid_session(root, project, { drop = true }) then return cb(true) end
  M.ask_session(root, project, cb)
end

local function cfg()
  local r = config.get().review
  r = type(r) == 'table' and r or {}
  return { kinds = type(r.kinds) == 'table' and r.kinds or review.DEFAULT_KINDS,
    intro = type(r.intro) == 'string' and r.intro or review_text.DEFAULT_INTRO }
end

---The lines of the review text of `comments` for the review's session.
---@param root string
---@param project table
---@param comments table[]
---@return string[]
function M.text(root, project, comments)
  local t = M.valid_session(root, project)
  local c = cfg()
  return review_text.build(comments, { project = project.name or vim.fs.basename(root), root = root, cwd = t and t.cwd or nil,
    kinds = c.kinds, intro = c.intro })
end

-- The Session object of the review's target.
local function target_session(root, project)
  local t = M.valid_session(root, project)
  if not t then return nil end
  return session_mod().open({ id = t.id, cwd = t.cwd or root, path = t.path, title = t.title }), name_of(t.id, t.title)
end

local function ids_of(comments)
  local ids = {}
  for i, c in ipairs(comments) do ids[i] = c.id end
  return ids
end

-- The review changed: the full diff and the drawer show it.
local function changed()
  local fd = fulldiff()
  if fd then fd.redraw_marks() end
  if drawer() then drawer().refresh() end
end

-- The comments left the review.
local function cleared(root, comments)
  review.clear(root, ids_of(comments))
  changed()
end

-- A review that went out as a whole (the prompt sent, or the text copied) is over: an emptied
-- review forgets its session, so the next comment asks again. A comment sent at once keeps it.
local function ended(root, comments)
  review.clear(root, ids_of(comments))
  if review.count(root) == 0 then review.set_session(root, nil) end
  changed()
end

---The prompt that held a review was sent (ui/chat_send.lua): its comments leave the review.
---@param mark { root: string, ids: integer[] } what `put` left on the prompt buffer
function M.sent_from_prompt(mark)
  local list = {}
  for i, id in ipairs(mark.ids) do list[i] = { id = id } end
  ended(mark.root, list)
end

---Jump between the review of `root` and its session (the global key): from the full diff of
---`root` to the chat of the review's session (else the chat the diff was opened over), the
---prompt focused; from anywhere else back to the review (`M.resume`).
---@param root string
---@param project table
function M.toggle(root, project)
  local fd = fulldiff()
  local v = fd and fd.state()
  if not (v and v.root == root and v.buf == api.nvim_get_current_buf()) then return M.resume(root, project) end
  local s = target_session(root, project) or (v.prev and v.prev.chat) or nil
  if not s then return notify('no session for this review yet: comment first, or open a chat') end
  local chat = require('agent-ide.ui.chat')
  chat.open(s, chat.project_of(s))
end

---Resume the review of `root`: the full diff of the scope of its newest comment, the cursor on
---that comment (`<CR>` on the drawer's `review (n)` row, the global key from outside the diff).
---@param root string
---@param project table
function M.resume(root, project)
  local comments = review.list(root)
  local c = comments[#comments]
  if not c then return notify('no review comments for ' .. (project.name or vim.fs.basename(root))) end
  local sc = c.scope
  local scope = { kind = sc.kind }
  if sc.kind == 'commit' then scope.commit = { hash = sc.hash, short = sc.short, subject = sc.subject } end
  require('agent-ide.ui.fulldiff').open({ root = root, project = project, scope = scope, focus_comment = c.id })
end

local function has_text(lines)
  for _, l in ipairs(lines) do
    if l:find('%S') then return true end
  end
  return false
end

-- Put `lines` into the prompt of `s` and show that prompt below the main window. The comments
-- are marked as in the prompt and the buffer remembers them (`agent_ide_review`), so a send
-- of that prompt clears them (chat_send.deliver → `M.sent_from_prompt`).
local function put(s, project, root, comments, lines, how)
  local chat = require('agent-ide.ui.chat')
  local _, pbuf = chat.ensure(s, project)
  require('agent-ide.ui.prompt').put(pbuf, lines, how)
  local ids = ids_of(comments)
  review.mark(root, ids, { in_prompt = true })
  vim.b[pbuf].agent_ide_review = { root = root, ids = ids, intro = lines[1] }
  local windows = require('agent-ide.ui.chat_win')
  local win = windows.show_prompt(pbuf, windows.transcript())
  api.nvim_set_current_win(win)
  pcall(api.nvim_win_set_cursor, win, { 1, 0 })
  require('agent-ide.ui.prompt_label').refresh()
end

---The done step for the review of `root`: the comments as one text into the prompt of the
---review's session (above the draft, or replacing it), or to the clipboard; asked how.
---@param root string
---@param project table
function M.done(root, project)
  local name = project.name or vim.fs.basename(root)
  local comments = review.list(root)
  if #comments == 0 then return notify('no review comments for ' .. name) end
  M.ensure_session(root, project, function(ok)
    if not ok then return end
    local s, target = target_session(root, project)
    if not s then return end
    -- the prompt buffer first: a draft kept on disk comes back into it (ui/drafts.lua)
    local _, pbuf = require('agent-ide.ui.chat').ensure(s, project)
    local draft = pbuf ~= nil and has_text(api.nvim_buf_get_lines(pbuf, 0, -1, false))
    local in_prompt = 0
    for _, c in ipairs(comments) do
      if c.in_prompt then in_prompt = in_prompt + 1 end
    end
    local items = {}
    if draft and in_prompt > 0 then -- the draft holds an earlier text of this review: replace it
      items[#items + 1] = { label = 'Replace the draft', how = 'replace' }
      items[#items + 1] = { label = 'Insert above the draft', how = 'above' }
    elseif draft then
      items[#items + 1] = { label = 'Insert above the draft', how = 'above' }
      items[#items + 1] = { label = 'Replace the draft', how = 'replace' }
    else
      items[#items + 1] = { label = 'Put in the prompt', how = 'replace' }
    end
    items[#items + 1] = { label = 'Copy to clipboard', copy = true }
    items[#items + 1] = { label = 'Another session…', other = true }
    items[#items + 1] = { label = 'Discard all comments', discard = true }
    items[#items + 1] = { label = 'Cancel' }
    local n = #comments
    local what = n .. (n == 1 and ' comment' or ' comments')
    local state = what .. (in_prompt > 0 and (', ' .. in_prompt .. ' in the prompt') or '')
    select(items, ('Review of %s: %s, to "%s"'):format(name, state, target), function(choice)
      if not choice then return end
      if choice.other then
        return M.ask_session(root, project, function(ok2) if ok2 then M.done(root, project) end end)
      end
      if choice.discard then -- the review is over without going anywhere; asks first
        if vim.fn.confirm(('Discard the %s of this review?'):format(what), '&Discard\n&Keep', 2) ~= 1 then return end
        ended(root, comments)
        return notify(('review of %s discarded: %s'):format(name, what))
      end
      if not (choice.how or choice.copy) then return end
      local lines = M.text(root, project, comments)
      if choice.copy then
        local text = table.concat(lines, '\n')
        vim.fn.setreg('"', text)
        pcall(vim.fn.setreg, '+', text)
        ended(root, comments)
        return notify(('review of %s: %s copied'):format(name, what))
      end
      put(s, project, root, comments, lines, choice.how)
      changed()
      notify(('review of %s: %s in the prompt of "%s"; they leave the review when it is sent'):format(name, what, target))
    end)
  end)
end

---Send comment `c` of the review of `root` at once, as a review text of its own, through the
---chat's send path (queued behind a running turn, else started). It leaves the review once sent.
---@param root string
---@param project table
---@param c table
function M.send_now(root, project, c)
  M.ensure_session(root, project, function(ok)
    if not ok then return end
    local s, target = target_session(root, project)
    if not s then return end
    local lines = M.text(root, project, { c })
    local chat = require('agent-ide.ui.chat')
    if not chat.send_text then return notify('sending a comment at once comes with a later task') end
    chat.send_text(s, project, table.concat(lines, '\n'), function(sent)
      if not sent then return end
      cleared(root, { c })
      notify(('sent to "%s": [%s] %s'):format(target, c.kind, review_text.reference(c)))
    end)
  end)
end

return M
