-- Keeps Neovim usable on long transcripts. With 'conceallevel' >= 2 (markdown render plugins set
-- 3) and a highlight query that conceals whole lines (markdown's fence lines), Neovim asks the
-- treesitter highlighter about EVERY buffer row it needs a height for, and each answer is its own
-- `parse({ row, row + 1 })`: a few milliseconds per row with a few thousand injected regions. Moving
-- into a 20 000-line transcript then freezes Neovim for minutes. Measured on such a transcript:
-- text height of the whole buffer 36 s after a full parse (far more before one), 9 ms with the
-- per-row check off.
--
-- The check has no public switch, so this turns the highlighter's private `_conceal_line` flag off
-- for one buffer and keeps it off (the highlighter sets it again whenever an injected language
-- arrives). Cost: treesitter no longer hides whole fence lines in that buffer; everything else
-- (highlighting, inline conceal, a render plugin's own marks) is unchanged. If the internals
-- change, this does nothing.
local M = {}

local MARK = '_agent_ide_no_conceal_lines'

---Switch the per-row conceal-line check off for `buf`'s treesitter highlighter, if it has one.
---Cheap and idempotent: call it whenever the highlighter may have (re)started.
---@param buf integer
---@return boolean off whether a highlighter was found and is switched off
function M.off(buf)
  local ok, hl = pcall(function() return vim.treesitter.highlighter.active[buf] end)
  if not ok or type(hl) ~= 'table' then return false end
  if rawget(hl, MARK) then return true end
  local mt = getmetatable(hl)
  if type(mt) ~= 'table' then return false end
  local new = {}
  for k, v in pairs(mt) do new[k] = v end
  new.__index = mt.__index or mt
  new.__newindex = function(t, k, v)
    if k ~= '_conceal_line' then rawset(t, k, v) end
  end
  rawset(hl, '_conceal_line', nil)
  rawset(hl, MARK, true)
  setmetatable(hl, new)
  return true
end

---Keep the check off for `buf` for as long as it lives: now, and whenever a highlighter starts
---(filetype set again, the buffer shown in a window).
---@param buf integer
---@param group integer|string augroup for the autocommands
function M.keep_off(buf, group)
  M.off(buf)
  vim.api.nvim_create_autocmd({ 'FileType', 'BufWinEnter' }, { group = group, buffer = buf, callback = function(ev)
    M.off(ev.buf)
    -- a highlighter started by a later FileType handler of the user's config
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(ev.buf) then M.off(ev.buf) end
    end)
  end })
end

return M
