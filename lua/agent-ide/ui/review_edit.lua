-- The comment editor of the full diff: a small window under the cursor line where a review
-- comment is typed (`KIND: text`, several lines allowed). Save (`<CR>` in normal mode, `:w`)
-- stores it in the review (ui/review_marks.lua shows it); send (`<C-CR>`) stores it and sends
-- that one comment to the review's session at once; cancel (`q`, `<Esc><Esc>`) asks when the
-- text changed. The first comment of a review asks which session it is for.
local api = vim.api
local config = require('agent-ide.config')
local keys = require('agent-ide.util.keys')
local review = require('agent-ide.review')

local M = {}

local MIN_HEIGHT, MAX_HEIGHT = 3, 8

local E -- the open editor: { win, buf, opts, origin, opened = string }

---Help of the editor's keys (name, what it does).
M.HELP = {
  { 'save', 'save the comment' },
  { 'send', 'save and send this one comment to Claude now' },
  { 'cancel', 'cancel (asks when the text changed)' },
}

local function notify(msg, level) vim.notify('Agent-IDE: ' .. msg, level or vim.log.levels.INFO) end

local function cfg_kinds()
  local r = config.get().review
  return type(r) == 'table' and type(r.kinds) == 'table' and r.kinds or review.DEFAULT_KINDS
end

local function editor_keys()
  local k = config.get().keys
  return type(k) == 'table' and type(k.review) == 'table' and k.review or {}
end

---Map the editor's keys on `buf`: `actions[name]` runs for each (`send` in insert mode too).
---@param buf integer
---@param actions table<string, fun()>
function M.map(buf, actions)
  local k = editor_keys()
  for _, h in ipairs(M.HELP) do
    local fn = actions[h[1]] or function() end
    local modes = h[1] == 'send' and { 'n', 'i' } or 'n'
    for _, lhs in ipairs(keys.list(k[h[1]])) do
      vim.keymap.set(modes, lhs, function()
        local ok, err = pcall(fn)
        if not ok then vim.notify('Agent-IDE: comment: ' .. tostring(err), vim.log.levels.ERROR) end
      end, { buffer = buf, nowait = true, silent = true, desc = 'Agent-IDE: ' .. h[2] })
    end
  end
end

local function winbar(opts)
  local names = {}
  for _, k in ipairs(cfg_kinds()) do names[#names + 1] = k[1] end
  local k = editor_keys()
  local hints = {}
  for _, h in ipairs(M.HELP) do
    local label = keys.label(k[h[1]])
    if label then hints[#hints + 1] = label .. ' ' .. ({ save = 'save', send = 'send now', cancel = 'cancel' })[h[1]] end
  end
  local text = table.concat(names, ' · ') .. ' — ' .. table.concat(hints, ' · ')
  local target = require('agent-ide.ui.review_send').target_name(opts.root, opts.project)
  if target then text = text .. ' → ' .. target end
  return '%#AgentIdeAskMore#' .. text:gsub('%%', '%%%%') .. '%*'
end

-- The text as typed: lines joined, trailing blank lines dropped.
local function text_of(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  while #lines > 0 and not lines[#lines]:find('%S') do lines[#lines] = nil end
  return table.concat(lines, '\n')
end

local function close()
  if not E then return end
  local e = E
  E = nil
  if api.nvim_win_is_valid(e.win) then pcall(api.nvim_win_close, e.win, true) end
  if api.nvim_buf_is_valid(e.buf) then pcall(api.nvim_buf_delete, e.buf, { force = true }) end
  if api.nvim_win_is_valid(e.origin) then api.nvim_set_current_win(e.origin) end
end

-- Which session the review of `root` goes to, asked when none is chosen yet; `cb(ok)`.
local function ensure_session(root, project, cb) require('agent-ide.ui.review_send').ensure_session(root, project, cb) end

-- Save what the editor holds; `cb(comment|nil)` once stored (nil: nothing to save, or cancelled).
local function save(cb)
  local e = E
  if not e then return end
  local text = text_of(e.buf)
  if text == '' then
    close()
    return cb(nil)
  end
  local kind, rest = review.kind_of(text, cfg_kinds())
  local o = e.opts
  if o.existing then
    review.update(o.root, o.existing.id, { kind = kind, text = rest })
    o.existing.kind, o.existing.text = kind, rest
    close()
    o.on_change()
    return cb(o.existing)
  end
  ensure_session(o.root, o.project, function(ok)
    if not ok or E ~= e then return cb(nil) end -- the editor stays open: the comment is not lost
    local a = o.anchor
    local c = review.add(o.root, { kind = kind, text = rest, scope = o.scope, path = a.path, side = a.side, line = a.line,
      code = a.code })
    close()
    o.on_change()
    cb(c)
  end)
end

local function cancel()
  local e = E
  if not e then return end
  if text_of(e.buf) ~= e.opened then
    if vim.fn.confirm('Discard this comment?', '&Discard\n&Keep editing', 2) ~= 1 then return end
  end
  close()
end

local function send_now()
  local e = E
  if not e then return end
  if api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd('stopinsert') end
  local o = e.opts
  save(function(c)
    if not c then return end
    local ok, send = pcall(require, 'agent-ide.ui.review_send')
    if ok and send.send_now then return send.send_now(o.root, o.project, c) end
    notify('sending a comment at once comes with a later task')
  end)
end

local function fit(e)
  if not (E == e and api.nvim_win_is_valid(e.win)) then return end
  local n = api.nvim_buf_line_count(e.buf)
  api.nvim_win_set_config(e.win, { height = math.max(MIN_HEIGHT, math.min(MAX_HEIGHT, n)) })
end

---Open the editor for a comment at `opts.anchor` of the full diff (`opts.root`, `opts.scope`
---as `fulldiff.scope_of`), or for `opts.existing` (its text in the window). `opts.on_change`
---runs after a save. The window sits under the cursor line of the current window, the text
---width of that window wide, and is the current window afterwards, in insert mode.
---@param opts { root: string, scope: table, anchor: table, existing?: table, project: table, on_change: fun() }
---@return integer win
function M.open(opts)
  if E then close() end
  local origin = api.nvim_get_current_win()
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.b[buf].agent_ide_kind = 'review'
  require('agent-ide.ui.bufname').set(buf, 'agents://review comment')
  local opened = ''
  if opts.existing then
    opened = opts.existing.kind .. ': ' .. opts.existing.text
    api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opened, '\n', { plain = true }))
  end
  vim.bo[buf].modified = false
  vim.bo[buf].filetype = 'markdown'
  local info = vim.fn.getwininfo(origin)[1]
  local width = math.max(20, api.nvim_win_get_width(origin) - (info and info.textoff or 0) - 2)
  local below = vim.fn.winline() + MAX_HEIGHT + 3 <= api.nvim_win_get_height(origin)
  local win = api.nvim_open_win(buf, true, {
    relative = 'cursor', row = below and 1 or 0, col = 0, anchor = below and 'NW' or 'SW',
    width = width, height = MIN_HEIGHT, border = 'rounded', style = 'minimal', zindex = 55,
    title = ' comment ', title_pos = 'left',
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  api.nvim_set_option_value('winbar', winbar(opts), { scope = 'local', win = win })
  E = { win = win, buf = buf, opts = opts, origin = origin, opened = opened }
  local e = E
  M.map(buf, { save = function() save(function() end) end, send = send_now, cancel = cancel })
  api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function() save(function() end) end })
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { buffer = buf, callback = function() fit(e) end })
  api.nvim_create_autocmd('WinClosed', { pattern = tostring(win), once = true, callback = function()
    if E == e then E = nil end
  end })
  api.nvim_create_autocmd('BufWipeout', { buffer = buf, once = true, callback = function()
    if E == e then E = nil end
  end })
  vim.cmd('startinsert!')
  return win
end

---The open editor (tests): `{ win, buf }`, nil when none.
function M.state() return E and { win = E.win, buf = E.buf } or nil end

return M
