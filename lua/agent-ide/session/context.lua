-- The size of a session's context: the input tokens of its last request to the model, which is
-- what the next prompt reads again (from the cache while it is warm, in full after a pause).
-- Live it comes from the stream (session/actions.lua); for a session without a process it is
-- read from the end of the transcript. The model is never asked for it.
local usage = require('agent-ide.claude.usage')

local M = {}

M.TAIL = 1024 * 1024 -- bytes read from the end of a transcript (a few messages at most)

local DECODE_OPTS = { luanil = { object = true, array = true } }

---The context after the transcript lines `lines` (the last ones of a file): the usage of the
---last assistant message of the main conversation, or what a later compaction left. nil when
---none of the lines says (an empty session, a compaction without a size, a cut tail).
---@param lines string[]
---@return integer|nil
function M.from_lines(lines)
  for i = #lines, 1, -1 do
    local l = lines[i]
    if l:find('"compact_boundary"', 1, true) or l:find('"assistant"', 1, true) then
      local ok, rec = pcall(vim.json.decode, l, DECODE_OPTS)
      if ok and type(rec) == 'table' and rec.isSidechain ~= true then
        if rec.type == 'system' and rec.subtype == 'compact_boundary' then
          local m = type(rec.compactMetadata) == 'table' and rec.compactMetadata or {}
          return type(m.postTokens) == 'number' and m.postTokens > 0 and m.postTokens or nil
        elseif rec.type == 'assistant' and type(rec.message) == 'table' and rec.message.model ~= '<synthetic>' then
          local n = usage.context(rec.message.usage)
          if n then return n end
        end
      end
    end
  end
  return nil
end

---Read the context size from the end of `path`; `cb(tokens|nil)` on the main loop.
---@param path string
---@param cb fun(tokens: integer|nil)
function M.read(path, cb)
  local uv = vim.uv
  local function done(v) vim.schedule(function() cb(v) end) end
  uv.fs_open(path, 'r', 384, function(err, fd)
    if err or not fd then return done(nil) end
    uv.fs_fstat(fd, function(err2, st)
      if err2 or not st then uv.fs_close(fd); return done(nil) end
      local size = st.size
      local len = math.min(size, M.TAIL)
      if len == 0 then uv.fs_close(fd); return done(nil) end
      uv.fs_read(fd, len, size - len, function(err3, data)
        uv.fs_close(fd)
        if err3 or type(data) ~= 'string' then return done(nil) end
        vim.schedule(function()
          local lines = vim.split(data, '\n', { trimempty = true })
          if len < size then table.remove(lines, 1) end -- the first line of a cut tail is partial
          cb(M.from_lines(lines))
        end)
      end)
    end)
  end)
end

---Bring `s.context_tokens` up to date and hand it over: the live value while a process runs,
---else the transcript's tail, read once per version of the file (`s.context_key`).
---`cb(tokens|nil)` on the main loop.
---@param s table Session
---@param cb? fun(tokens: integer|nil)
function M.refresh(s, cb)
  cb = cb or function() end
  if s:_alive() or not s.path then return vim.schedule(function() cb(s.context_tokens) end) end
  vim.uv.fs_stat(s.path, vim.schedule_wrap(function(_, st)
    if not st then return cb(s.context_tokens) end
    local key = st.mtime.sec .. '.' .. st.mtime.nsec .. ':' .. st.size
    if key == s.context_key then return cb(s.context_tokens) end
    M.read(s.path, function(tokens)
      if s:_alive() then return cb(s.context_tokens) end -- started meanwhile: the stream knows better
      if s.context_tokens ~= tokens then
        s.context_tokens, s.context_key = tokens, key
        s:_emit('meta')
      else
        s.context_key = key
      end
      cb(tokens)
    end)
  end))
end

return M
