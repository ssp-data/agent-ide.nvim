-- Renders transcript events into buffer lines plus fold ranges.
local M = {}

local CAP_INPUT, CAP_RESULT, CAP_UNKNOWN = 60, 200, 20
local SUMMARY_FIELDS = { 'command', 'file_path', 'skill', 'pattern', 'description', 'prompt' }

---Split on \n, \r\n and \r; keeps empty pieces (including a trailing one).
local function split(s)
  s = tostring(s == nil and '' or s):gsub('\r\n', '\n'):gsub('\r', '\n')
  return vim.split(s, '\n', { plain = true })
end

local function prefixed(lines, prefix)
  local out = {}
  for i, l in ipairs(lines) do out[i] = prefix .. l end
  return out
end

---Cut `lines` to `max`, appending a marker line with the hidden count.
local function cap(lines, max)
  if #lines <= max then return lines end
  local out = vim.list_slice(lines, 1, max)
  out[#out + 1] = ('… %d more lines'):format(#lines - max)
  return out
end

local function summary(input)
  if type(input) ~= 'table' then return '' end
  for _, field in ipairs(SUMMARY_FIELDS) do
    if input[field] ~= nil then
      return vim.fn.strcharpart(split(input[field])[1], 0, 80)
    end
  end
  return ''
end

local function call_body(call)
  local input = type(call.input) == 'table' and call.input or {}
  local lines
  if call.name == 'Bash' then
    lines = split('$ ' .. tostring(input.command or ''))
  elseif call.name == 'Edit' then
    lines = {}
    for _, l in ipairs(split(input.old_string)) do lines[#lines + 1] = '- ' .. l end
    for _, l in ipairs(split(input.new_string)) do lines[#lines + 1] = '+ ' .. l end
  elseif call.name == 'Write' then
    lines = split(input.content)
  else
    lines = split(vim.inspect(call.input))
  end
  return cap(lines, CAP_INPUT)
end

local function result_lines(res)
  local lines = split(res.text)
  if res.is_error then lines[1] = 'ERROR ' .. lines[1] end
  return cap(lines, CAP_RESULT)
end

---Emit rendered events into `out` ({lines, folds}); `results` maps id -> results, `known` is the set of call ids.
local function emit(events, results, known, out)
  local function block(header, body)
    local first = #out.lines + 1
    out.lines[first] = header
    for _, l in ipairs(body) do out.lines[#out.lines + 1] = '│ ' .. l end
    out.folds[#out.folds + 1] = { first = first, last = #out.lines }
  end
  local function plain(lines)
    for _, l in ipairs(lines) do out.lines[#out.lines + 1] = l end
  end

  local after_prompt = false
  local i = 1
  while i <= #events do
    local ev = events[i]
    if ev.kind == 'prompt' then
      plain({ '', '## You', '' })
      plain(split(ev.text))
      plain({ '' })
      after_prompt = true
      i = i + 1
    elseif ev.kind == 'tool_result' and known[ev.id] then
      i = i + 1 -- rendered with its call
    else
      if after_prompt then
        plain({ '## Claude', '' })
        after_prompt = false
      end
      if ev.sidechain then
        local j = i
        while j <= #events and events[j].sidechain do j = j + 1 end
        local group = vim.list_slice(events, i, j - 1)
        local inner = { lines = {}, folds = {} }
        emit(group, results, known, inner)
        block(('▸ subagent (%d events)'):format(#group), inner.lines)
        i = j
      else
        if ev.kind == 'text' then
          plain(split(ev.text))
          plain({ '' })
        elseif ev.kind == 'tool_call' then
          local body = call_body(ev)
          for _, res in ipairs(results[ev.id] or {}) do
            vim.list_extend(body, result_lines(res))
          end
          block(('▸ %s: %s'):format(ev.name or '?', summary(ev.input)), body)
        elseif ev.kind == 'tool_result' then
          block('▸ result (no matching call)', result_lines(ev))
        elseif ev.kind == 'thinking' then
          block('▸ thinking', split(ev.text))
        elseif ev.kind == 'meta' then
          block('▸ ' .. tostring(ev.label), split(ev.text))
        else
          block('▸ unknown: ' .. tostring(ev.label), cap(split(ev.raw), CAP_UNKNOWN))
        end
        i = i + 1
      end
    end
  end
end

---@param events table[]
---@return { lines: string[], folds: { first: integer, last: integer }[] }
function M.render(events)
  local results, known = {}, {}
  for _, ev in ipairs(events) do
    if ev.kind == 'tool_call' and ev.id ~= nil then known[ev.id] = true end
  end
  for _, ev in ipairs(events) do
    if ev.kind == 'tool_result' and known[ev.id] then
      results[ev.id] = results[ev.id] or {}
      table.insert(results[ev.id], ev)
    end
  end
  local out = { lines = {}, folds = {} }
  emit(events, results, known, out)
  return out
end

---@return string[] one foldlevel string per line
function M.fold_levels(folds, line_count)
  local levels = {}
  for i = 1, line_count do levels[i] = '0' end
  for _, f in ipairs(folds) do
    for l = f.first, f.last do levels[l] = '1' end
    levels[f.first] = '>1'
  end
  return levels
end

return M
