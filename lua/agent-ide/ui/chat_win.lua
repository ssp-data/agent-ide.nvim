-- The two windows of the chat view in the Agents tab: transcript (the main window) and the
-- prompt split below it. Reused for whichever session is opened.
local api = vim.api
local config = require('agent-ide.config')
local prompt = require('agent-ide.ui.prompt')

local M = {}

local PROMPT_HEIGHT = 8

local W = {} -- { transcript = win|nil, prompt = win|nil }

local function drawer() return require('agent-ide.ui.drawer') end

local function valid_win(w) return w ~= nil and api.nvim_win_is_valid(w) end

---The window for the transcript: the one used before, else the Agents tab's main window
---(the prompt window itself when nothing else is left).
---@return integer win
function M.transcript()
  local tab = drawer().state().tab
  local w = W.transcript
  if valid_win(w) and w ~= W.prompt and (not tab or api.nvim_win_get_tabpage(w) == tab) then return w end
  w = drawer().main_win() or api.nvim_get_current_win()
  if w == W.prompt then
    local d = drawer().state().win
    for _, x in ipairs(api.nvim_tabpage_list_wins(api.nvim_win_get_tabpage(w))) do
      if x ~= w and x ~= d and api.nvim_win_get_config(x).relative == '' then
        w = x
        break
      end
    end
    if w == W.prompt then W.prompt = nil end
  end
  W.transcript = w
  return w
end

local function is_prompt_win(w)
  return vim.b[api.nvim_win_get_buf(w)].agent_ide_kind == 'prompt'
end

---Show prompt buffer `pbuf` in the prompt window of `twin`'s tab, created (height 8) below
---`twin` when the tab has none. At most one prompt window per tab: extra ones are closed.
---@param pbuf integer
---@param twin integer
---@return integer win
function M.show_prompt(pbuf, twin)
  local tab = api.nvim_win_get_tabpage(twin)
  local pwin
  if valid_win(W.prompt) and W.prompt ~= twin and api.nvim_win_get_tabpage(W.prompt) == tab then pwin = W.prompt end
  for _, w in ipairs(api.nvim_tabpage_list_wins(tab)) do
    if w ~= twin and w ~= pwin and api.nvim_win_get_config(w).relative == '' and is_prompt_win(w) then
      if pwin then
        pcall(api.nvim_win_close, w, false)
      else
        pwin = w
      end
    end
  end
  if pwin then
    if api.nvim_win_get_buf(pwin) ~= pbuf then api.nvim_win_set_buf(pwin, pbuf) end
  else
    pwin = api.nvim_open_win(pbuf, false, { split = 'below', win = twin, height = PROMPT_HEIGHT })
  end
  -- the chat's own windows live in the Agents tab
  local agents = drawer().state().tab
  if not agents or tab == agents or not valid_win(W.prompt) then W.prompt = pwin end
  prompt.setup_win(pwin)
  return pwin
end

---The chat transcript window when it shows `buf`.
---@param buf integer
---@return integer|nil
function M.showing(buf)
  if valid_win(W.transcript) and api.nvim_win_get_buf(W.transcript) == buf then return W.transcript end
end

---Tab-local directory of `win` to the project folder (part 1 behaviour); the global one stays.
---@param win integer
---@param project table|nil
function M.tcd(win, project)
  -- only an absolute key is a folder: a project without cwd is keyed by a bare directory name
  local key = project and project.key
  if config.get().tcd and key and key:sub(1, 1) == '/' and vim.fn.isdirectory(key) == 1 then
    api.nvim_win_call(win, function() vim.cmd.tcd(vim.fn.fnameescape(key)) end)
  end
end

---@return { transcript: integer|nil, prompt: integer|nil } the windows still valid
function M.get()
  return { transcript = valid_win(W.transcript) and W.transcript or nil, prompt = valid_win(W.prompt) and W.prompt or nil }
end

return M
