-- Transcript parser: turns Claude Code JSONL records into the shared Event model.
-- Nothing is dropped silently: anything not understood becomes an `unknown` event.
local M = {}

local DECODE_OPTS = { luanil = { object = true, array = true } }

-- Record types that carry no conversation content.
local BOOKKEEPING = {}
for _, t in ipairs({
  'last-prompt', 'mode', 'permission-mode', 'atis-latch', 'attachment',
  'file-history-snapshot', 'file-history-delta', 'ai-title', 'api-request',
  'api-request-shape', 'api-request-blob', 'system', 'summary', 'queue-operation',
  'cost-state', 'pr-link', 'frame-link', 'artifact-autoreact-ledger',
  'artifact-comment-monitor',
}) do
  BOOKKEEPING[t] = true
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

-- Original JSON text of each element of `message.content` in `line`, or nil.
-- Only used for unknown blocks, so the cost is irrelevant on the hot path.
local function raw_content_blocks(line)
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
          local arr = line:match('^%s*()%[', colon + 1)
          if not arr then return nil end
          -- One entry per element (scalars included) so indexes line up with `ipairs(content)`.
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
      end
      i = e + 1
    else
      depth = depth + ((c == '{' or c == '[') and 1 or -1)
      i = i + 1
    end
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
  if type(block) ~= 'table' then
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

local function conversation_events(rec, line)
  local content = type(rec.message) == 'table' and rec.message.content or nil
  if type(content) == 'string' then
    if rec.type == 'user' then return user_string_events(rec, content) end
    return { { kind = 'text', text = content } }
  end
  if type(content) ~= 'table' then
    return { { kind = 'unknown', label = rec.type, raw = line } }
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

---@param line string
---@return table[] events
function M.parse_line(line)
  if type(line) ~= 'string' or not line:find('%S') then return {} end
  local ok, rec = pcall(vim.json.decode, line, DECODE_OPTS)
  if not ok or type(rec) ~= 'table' then return {} end

  local rtype = rec.type
  if type(rtype) ~= 'string' then rtype = '?' end
  local events
  if BOOKKEEPING[rtype] then
    return {}
  elseif rtype == 'user' or rtype == 'assistant' then
    events = conversation_events({ type = rtype, isMeta = rec.isMeta, message = rec.message }, line)
  else
    events = { { kind = 'unknown', label = rtype, raw = line } }
  end

  if rec.isSidechain == true then
    for _, ev in ipairs(events) do ev.sidechain = true end
  end
  return events
end

---@param text string
---@return table[] events
function M.parse_text(text)
  local events = {}
  for line in (text or ''):gmatch('[^\n]+') do
    for _, ev in ipairs(M.parse_line(line)) do events[#events + 1] = ev end
  end
  return events
end

return M
