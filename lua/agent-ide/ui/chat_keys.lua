-- Buffer-local keys of the chat view (transcript and prompt) and the chat help float.
local config = require('agent-ide.config')

local M = {}

---`config.keys.chat` (name -> lhs or false); `keys = false` disables them all.
function M.keys()
  local keys = config.get().keys
  return type(keys) == 'table' and type(keys.chat) == 'table' and keys.chat or {}
end

local HELP = {
  { 'send', 'send the prompt (normal and insert mode)' },
  { 'send_alt', 'send the prompt' },
  { 'interrupt', 'interrupt Claude; queued prompts return to the prompt buffer' },
  { 'prompt', 'focus the prompt' },
  { 'answer', 'answer what Claude asks (permission, question, plan)' },
  { 'mode', 'next permission mode (manual, acceptEdits, plan, auto)' },
  { 'model', 'pick the model' },
  { 'raw', 'transcript: raw view of the wire lines (>> sent, << received), not the rendered answer; q or the same key returns' },
  { 'raw_event', 'transcript: raw view at the line of the unknown fold under the cursor' },
  { 'native', 'continue in native Claude in a tmux pane (parks here; reloads when it exits)' },
  { 'help', 'this help' },
  { 'history_prev', 'prompt: older prompt (also <Up>) on the first line' },
  { 'history_next', 'prompt: newer prompt (also <Down>) on the last line' },
  { 'attach', 'prompt: pick a file and add an [attach] line' },
  { 'answer_inner', 'transcript: text object, one Claude answer' },
  { 'answer_outer', 'transcript: text object, one Claude answer with its header' },
}

function M.help()
  local keys = M.keys()
  local rows = {}
  for _, h in ipairs(HELP) do
    if keys[h[1]] then rows[#rows + 1] = { key = keys[h[1]], desc = h[2] } end
  end
  local all = config.get().keys
  if type(all) == 'table' and all.next_waiting then
    rows[#rows + 1] = { key = all.next_waiting, desc = 'anywhere: go to the next session that needs you' }
  end
  rows[#rows + 1] = { key = '/', desc = 'prompt, at line start: Claude commands (menu)' }
  rows[#rows + 1] = { key = '@', desc = 'prompt, after a space: pick a file to attach' }
  rows[#rows + 1] = { key = 'i / a / o', desc = 'in the transcript: write in the prompt' }
  rows[#rows + 1] = { key = 'za', desc = 'toggle fold' }
  rows[#rows + 1] = { key = ':w', desc = 'save prompt (later; does nothing yet)' }
  rows[#rows + 1] = { key = ':q / ZZ', desc = 'prompt: hide the window, the draft stays' }
  rows[#rows + 1] = { key = ':q!', desc = 'prompt: hide the window and discard the draft' }
  require('agent-ide.ui.help').open('Agent-IDE chat', rows)
end

---Map the chat keys in `buf`.
---@param c table Chat (`c.s` is its Session)
---@param buf integer
---@param is_transcript boolean
---@param act { send: fun(c), interrupt: fun(c), focus_prompt: fun(c, insert: boolean), native: fun(c) }
function M.map(c, buf, is_transcript, act)
  local keys = M.keys()
  local function map(modes, lhs, fn, desc)
    if not lhs then return end
    vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = 'Agent-IDE: ' .. desc })
  end
  map({ 'n', 'i' }, keys.send, function() act.send(c) end, 'send prompt')
  map('n', keys.send_alt, function() act.send(c) end, 'send prompt')
  map('n', keys.interrupt, function() act.interrupt(c) end, 'interrupt')
  map('n', keys.prompt, function() act.focus_prompt(c, false) end, 'focus prompt')
  map('n', keys.help, M.help, 'chat help')
  map('n', keys.answer, function() require('agent-ide.ui.permission').answer(c.s) end, 'answer Claude')
  map('n', keys.mode, function() require('agent-ide.ui.mode').cycle(c.s) end, 'next permission mode')
  map('n', keys.model, function() require('agent-ide.ui.mode').pick_model(c.s) end, 'pick model')
  map('n', keys.native, function() act.native(c) end, 'continue in native Claude (tmux)')
  if is_transcript then
    map('n', keys.raw, function() require('agent-ide.ui.raw').open(c.s) end, 'raw view')
    map('n', keys.raw_event, function() require('agent-ide.ui.raw').open_at_cursor(c.s, buf) end, 'raw view at event')
    require('agent-ide.ui.textobj').map(buf, c.s, keys)
    for _, lhs in ipairs({ 'i', 'a', 'o' }) do map('n', lhs, function() act.focus_prompt(c, true) end, 'write in the prompt') end
  end
end

return M
