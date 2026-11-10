-- Transcript parser: turns Claude Code JSONL records into the shared Event model.
-- Nothing is dropped silently: anything not understood becomes an `unknown` event.
local M = {}

-- JSON null is nil in objects (the key is absent) and vim.NIL in arrays, so arrays keep
-- their length and a null element is seen, not skipped. The helper client decodes the
-- same way, so events from both backends compare equal.
M.DECODE_OPTS = { luanil = { object = true } }
local DECODE_OPTS = M.DECODE_OPTS

-- Record types that carry no conversation content.
local BOOKKEEPING = {}
for _, t in ipairs({
  'last-prompt', 'mode', 'permission-mode', 'atis-latch', 'attachment',
  'file-history-snapshot', 'file-history-delta', 'ai-title', 'api-request',
  'api-request-shape', 'api-request-blob', 'summary', 'queue-operation',
  'cost-state', 'pr-link', 'frame-link', 'artifact-autoreact-ledger',
  'artifact-comment-monitor',
}) do
  BOOKKEEPING[t] = true
end

local byte, sub, find = string.byte, string.sub, string.find
local REPLACEMENT = '\239\191\189' -- U+FFFD

---Replace invalid UTF-8 the way Rust's `String::from_utf8_lossy` does: each maximal invalid
---subpart becomes one U+FFFD. Valid input is returned unchanged (and fast when it is ASCII).
---@param s string
---@return string
function M.fix_utf8(s)
  local i = find(s, '[\128-\255]')
  if not i then return s end
  local out, from = {}, 1
  while i do
    local c = byte(s, i)
    local need, lo, hi = 0, 0x80, 0xBF
    if c >= 0xC2 and c <= 0xDF then need = 1
    elseif c == 0xE0 then need, lo = 2, 0xA0
    elseif c == 0xED then need, hi = 2, 0x9F
    elseif c >= 0xE1 and c <= 0xEF then need = 2
    elseif c == 0xF0 then need, lo = 3, 0x90
    elseif c == 0xF4 then need, hi = 3, 0x8F
    elseif c >= 0xF1 and c <= 0xF3 then need = 3 end
    local j, ok = i + 1, need > 0
    for _ = 1, need do
      local b = byte(s, j)
      if not b or b < lo or b > hi then ok = false; break end
      lo, hi = 0x80, 0xBF
      j = j + 1
    end
    if ok then
      i = find(s, '[\128-\255]', j)
    else
      out[#out + 1] = sub(s, from, i - 1)
      out[#out + 1] = REPLACEMENT
      from = j > i + 1 and j or i + 1
      i = find(s, '[\128-\255]', from)
    end
  end
  if #out == 0 then return s end
  out[#out + 1] = sub(s, from)
  return table.concat(out)
end

-- Position of the closing quote of the JSON string opening at `i`.
local function string_end(s, i)
  local j = i + 1
  while true do
    j = s:find('["\\]', j)
    if not j then return nil end
    if s:sub(j, j) == '\\' then j = j + 2 else return j end
  end
end

-- Position of the first character of the value of `message.content` in `line`, or nil.
local function content_start(line)
  local depth, top_key, i = 0, nil, 1
  while true do
    i = line:find('["{}%[%]]', i)
    if not i then return nil end
    local c = line:sub(i, i)
    if c == '"' then
      local e = string_end(line, i)
      if not e then return nil end
      local colon = line:match('^%s*():', e + 1)
      if colon then
        local key = line:sub(i + 1, e - 1)
        if depth == 1 then top_key = key end
        if depth == 2 and key == 'content' and top_key == 'message' then
          return line:match('^%s*()', colon + 1)
        end
      end
      i = e + 1
    else
      depth = depth + ((c == '{' or c == '[') and 1 or -1)
      i = i + 1
    end
  end
end

-- Original JSON text of each element of `message.content` in `line`, or nil.
-- Only used for unknown blocks, so the cost is irrelevant on the hot path.
local function raw_content_blocks(line)
  local arr = content_start(line)
  if not arr or line:sub(arr, arr) ~= '[' then return nil end
  -- One entry per element (scalars included) so indexes line up with the array.
  local blocks, d, s0, j = {}, 0, arr + 1, arr + 1
  local function push(e)
    local t = line:sub(s0, e - 1):match('^%s*(.-)%s*$')
    if t ~= '' then blocks[#blocks + 1] = t end
  end
  while true do
    j = line:find('["{},%[%]]', j)
    if not j then return nil end
    local ch = line:sub(j, j)
    if ch == '"' then
      j = string_end(line, j)
      if not j then return nil end
    elseif ch == '{' or ch == '[' then
      d = d + 1
    elseif ch == ',' then
      if d == 0 then push(j); s0 = j + 1 end
    else
      d = d - 1
      if d < 0 then push(j); return blocks end
    end
    j = j + 1
  end
end

local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

local function tool_result_text(content)
  if type(content) == 'string' then return content end
  if type(content) ~= 'table' then return '' end
  local parts = {}
  for _, item in ipairs(content) do
    if type(item) == 'table' and item.type == 'text' and type(item.text) == 'string' then
      parts[#parts + 1] = item.text
    elseif item == vim.NIL then
      parts[#parts + 1] = '[null]'
    elseif type(item) == 'table' then
      parts[#parts + 1] = '[' .. tostring(item.type) .. ']'
    else
      parts[#parts + 1] = '[' .. type(item) .. ']'
    end
  end
  return table.concat(parts, '\n')
end

local function user_string_events(rec, s)
  local name = s:match('<command%-name>(.-)</command%-name>')
  if name then
    local args = s:match('<command%-args>(.-)</command%-args>') or ''
    return { { kind = 'prompt', text = trim(name .. ' ' .. args) } }
  end
  local out = s:match('^%s*<local%-command%-stdout>(.-)</local%-command%-stdout>%s*$')
  if out then return { { kind = 'meta', label = 'command output', text = out } } end
  if s:sub(1, 1) == '<' or rec.isMeta == true then
    return { { kind = 'meta', label = 'meta', text = s } }
  end
  return { { kind = 'prompt', text = s } }
end

local function block_events(rec, block, raw)
  local events = {}
  local function unknown(label)
    events[1] = { kind = 'unknown', label = label, raw = raw() }
  end
  if block == vim.NIL then
    unknown('null')
    return events
  elseif type(block) ~= 'table' then
    unknown(type(block))
    return events
  end
  local bt = block.type
  if rec.type == 'user' and bt == 'tool_result' then
    events[1] = {
      kind = 'tool_result',
      id = block.tool_use_id,
      text = tool_result_text(block.content),
      is_error = block.is_error == true,
    }
  elseif rec.type == 'user' and bt == 'text' then
    events[1] = { kind = rec.isMeta == true and 'meta' or 'prompt', text = block.text or '' }
    if rec.isMeta == true then events[1].label = 'meta' end
  elseif rec.type == 'assistant' and bt == 'text' then
    events[1] = { kind = 'text', text = block.text or '' }
  elseif rec.type == 'assistant' and bt == 'thinking' then
    local t = block.thinking
    if type(t) == 'string' and t ~= '' then events[1] = { kind = 'thinking', text = t } end
  elseif rec.type == 'assistant' and bt == 'tool_use' then
    events[1] = { kind = 'tool_call', id = block.id, name = block.name, input = block.input or {} }
  else
    unknown(tostring(bt))
  end
  return events
end

-- Whether a decoded table was a JSON object. `{}` decodes with a metatable; an object whose
-- values are all null decodes to a bare empty table, like `[]`, so the text decides.
local function is_object(t, line)
  if next(t) == nil then
    if getmetatable(t) ~= nil then return true end
    local p = content_start(line)
    return p ~= nil and line:sub(p, p) == '{'
  end
  return not vim.islist(t)
end

local function conversation_events(rec, line)
  local content = type(rec.message) == 'table' and rec.message.content or nil
  if type(content) == 'string' then
    if rec.type == 'user' then return user_string_events(rec, content) end
    return { { kind = 'text', text = content } }
  end
  if type(content) ~= 'table' then
    return { { kind = 'unknown', label = rec.type, raw = line } }
  end
  if is_object(content, line) then
    return { { kind = 'unknown', label = 'content', raw = line } }
  end
  local raws
  local events = {}
  for idx, block in ipairs(content) do
    local function raw()
      raws = raws or raw_content_blocks(line) or {}
      return raws[idx] or vim.json.encode(block)
    end
    for _, ev in ipairs(block_events(rec, block, raw)) do events[#events + 1] = ev end
  end
  return events
end

---Events of one `user` or `assistant` message: the same block rules as transcript records.
---Also used by the stream decoder, whose messages carry the same content blocks.
---@param rec { type: 'user'|'assistant', isMeta: boolean|nil, message: table|nil }
---@param line string original JSON text (raw of unknown blocks is cut from it)
---@return table[] events
M.message_events = conversation_events

---Events of one line, and whether the line failed to decode.
---@param line string
---@return table[] events, boolean invalid
function M.parse_record(line)
  if type(line) ~= 'string' or not line:find('%S') then return {}, false end
  line = M.fix_utf8(line)
  local ok, rec = pcall(vim.json.decode, line, DECODE_OPTS)
  if not ok then return { { kind = 'unknown', label = 'invalid JSON', raw = line } }, true end
  if type(rec) ~= 'table' then return { { kind = 'unknown', label = '?', raw = line } }, false end

  local rtype = rec.type
  if type(rtype) ~= 'string' then rtype = '?' end
  local events
  if BOOKKEEPING[rtype] then
    return {}, false
  elseif rtype == 'system' then
    local sub_t = rec.subtype
    events = { {
      kind = 'meta',
      label = (type(sub_t) == 'string' and sub_t ~= '') and ('system: ' .. sub_t) or 'system',
      text = type(rec.content) == 'string' and rec.content or line,
    } }
  elseif rtype == 'user' or rtype == 'assistant' then
    events = conversation_events({ type = rtype, isMeta = rec.isMeta, message = rec.message }, line)
  else
    events = { { kind = 'unknown', label = rtype, raw = line } }
  end

  if rec.isSidechain == true then
    for _, ev in ipairs(events) do ev.sidechain = true end
  end
  return events, false
end

---Events of one line. A non-blank line that does not decode is an `unknown` event.
---@param line string
---@return table[] events
function M.parse_line(line)
  return (M.parse_record(line))
end

---Lines of a transcript, and whether the last one is unterminated (maybe still being written).
---@param text string
---@return string[] lines, boolean partial_last
function M.split_lines(text)
  local lines = {}
  for line in text:gmatch('[^\n]+') do lines[#lines + 1] = line end
  return lines, text ~= '' and text:sub(-1) ~= '\n'
end

---Append the events of `lines[k]` to `events`. The unterminated last line of a file is
---skipped when it does not decode (it is still being written).
function M.append_line_events(events, lines, k, partial_last)
  local evs, invalid = M.parse_record(lines[k])
  if invalid and partial_last and k == #lines then return end
  for _, ev in ipairs(evs) do events[#events + 1] = ev end
end

---@param text string
---@return table[] events
function M.parse_text(text)
  local events = {}
  local lines, partial = M.split_lines(text or '')
  for k = 1, #lines do M.append_line_events(events, lines, k, partial) end
  return events
end

return M
