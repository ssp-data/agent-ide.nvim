-- Renders transcript events into buffer lines plus fold ranges, and the lines where Claude's own
-- text (an answer, a remark between tool calls) starts: the view marks them with a `●`.
local M = {}

local CAP_INPUT, CAP_RESULT, CAP_UNKNOWN, CAP_EDIT_SIDE = 60, 200, 20, 30

-- Longest buffer line, in bytes: a markdown buffer with wrap, treesitter and a render plugin
-- cannot cope with lines of hundreds of kilobytes (a pasted screenshot, a minified file).
-- Lines inside a fold body are cut at MAX_FOLD_LINE; the user's and Claude's own prose (prompts
-- and answer text) is cut only at MAX_TEXT_LINE, far above any wrapped paragraph.
M.MAX_FOLD_LINE = 2000
M.MAX_TEXT_LINE = 20000
local SUMMARY_FIELDS = { 'command', 'file_path', 'skill', 'pattern', 'description', 'prompt' }

-- Metatables are a decoding detail (`{}` from JSON carries one, a default `{}` does not); leave
-- them out so the same input always reads the same, whichever backend parsed it.
local INSPECT_OPTS = {
  process = function(item, path)
    if path[#path] ~= vim.inspect.METATABLE then return item end
  end,
}

---Split on \n, \r\n and \r; keeps empty pieces (including a trailing one).
local function split(s)
  s = tostring(s == nil and '' or s):gsub('\r\n', '\n'):gsub('\r', '\n')
  return vim.split(s, '\n', { plain = true })
end

---Cut `line` to at most `max` bytes at a UTF-8 character boundary and say how many bytes went.
---Display rule only: events keep their full text and `gr` shows the raw line. An over-long line
---that is yanked (the `ir`/`ar` answer text objects copy buffer text) yanks in its cut form.
---@param line string
---@param max integer
---@return string
local function cut_line(line, max)
  local n = #line
  if n <= max then return line end
  local keep = max
  -- back up over continuation bytes (10xxxxxx) so no character is split
  while keep > 0 do
    local b = line:byte(keep + 1)
    if b < 0x80 or b >= 0xC0 then break end
    keep = keep - 1
  end
  return line:sub(1, keep) .. (' … +%d bytes (gr shows the raw line)'):format(n - keep)
end

---`cut_line` for every line of a list (the same count of lines comes back).
local function cut_lines(lines, max)
  for i, l in ipairs(lines) do
    if #l > max then lines[i] = cut_line(l, max) end
  end
  return lines
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

local function first_line(s)
  return split(s)[1]
end

local function summary(input)
  if type(input) ~= 'table' then return '' end
  for _, field in ipairs(SUMMARY_FIELDS) do
    if input[field] ~= nil then
      return vim.fn.strcharpart(first_line(input[field]), 0, 80)
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
    -- each side capped on its own, so a long removal never hides the added lines
    lines = cap(prefixed(split(input.old_string), '- '), CAP_EDIT_SIDE)
    vim.list_extend(lines, cap(prefixed(split(input.new_string), '+ '), CAP_EDIT_SIDE))
    return cut_lines(lines, M.MAX_FOLD_LINE)
  elseif call.name == 'Write' then
    lines = split(input.content)
  else
    lines = split(vim.inspect(call.input, INSPECT_OPTS))
  end
  return cut_lines(cap(lines, CAP_INPUT), M.MAX_FOLD_LINE)
end

local function result_lines(res)
  local lines = split(res.text)
  if res.is_error then lines[1] = 'ERROR ' .. lines[1] end
  return cut_lines(cap(lines, CAP_RESULT), M.MAX_FOLD_LINE)
end

---Emit rendered events into `out` ({lines, folds}); `results` maps id -> results, `known` is the set of call ids; `nested` renders a sidechain group's own events without regrouping.
local function emit(events, results, known, out, nested)
  local function block(header, body)
    local first = #out.lines + 1
    out.lines[first] = cut_line(header, M.MAX_FOLD_LINE)
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
      plain(cut_lines(split(ev.text), M.MAX_TEXT_LINE))
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
      if ev.sidechain and not nested then
        local j = i
        while j <= #events and events[j].sidechain do j = j + 1 end
        local group = vim.list_slice(events, i, j - 1)
        local inner = { lines = {}, folds = {}, answers = {} }
        emit(group, results, known, inner, true)
        block(('▸ subagent (%d events)'):format(#group), inner.lines)
        i = j
      else
        if ev.kind == 'text' then
          if not nested and ev.text ~= '' then out.answers[#out.answers + 1] = #out.lines + 1 end
          plain(cut_lines(split(ev.text), M.MAX_TEXT_LINE))
          plain({ '' })
        elseif ev.kind == 'tool_call' then
          local body = call_body(ev)
          for _, res in ipairs(results[ev.id] or {}) do
            vim.list_extend(body, result_lines(res))
          end
          block(('▸ %s: %s'):format(first_line(ev.name or '?'), summary(ev.input)), body)
        elseif ev.kind == 'tool_result' then
          block('▸ result (no matching call)', result_lines(ev))
        elseif ev.kind == 'thinking' then
          block('▸ thinking', cut_lines(split(ev.text), M.MAX_FOLD_LINE))
        elseif ev.kind == 'meta' then
          block('▸ ' .. first_line(ev.label), cut_lines(split(ev.text), M.MAX_FOLD_LINE))
        else
          block('▸ unknown: ' .. first_line(ev.label), cut_lines(cap(split(ev.raw), CAP_UNKNOWN), M.MAX_FOLD_LINE))
        end
        i = i + 1
      end
    end
  end
end

---Header summary and body lines of a tool call block (the body without results or the `│ `
---prefix), for blocks that show a tool's input outside the events, e.g. a pending ask.
---@param name string
---@param input any
---@return string summary, string[] body
function M.tool_parts(name, input)
  return summary(input), call_body({ name = name, input = input })
end

---First line of `s` (`\n`, `\r\n` or `\r` end a line).
M.first_line = first_line

---True when `ev` starts a turn: a main-thread prompt. Events before the first one form turn 0.
---@param ev table
---@return boolean
function M.starts_turn(ev)
  return ev.kind == 'prompt' and not ev.sidechain
end

---Render one turn's events into `out`. Results attach only to calls of the same turn, so a
---turn renders the same whatever follows it.
local function emit_turn(events, out)
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
  emit(events, results, known, out)
end

---Render events turn by turn; the result is the concatenation of each turn rendered alone.
---`answers`: the first line of every main-thread `text` event (a subagent's text is not one).
---@param events table[]
---@return { lines: string[], folds: { first: integer, last: integer }[], answers: integer[] }
function M.render(events)
  local out = { lines = {}, folds = {}, answers = {} }
  local first = 1
  for i = 2, #events + 1 do
    if i > #events or M.starts_turn(events[i]) then
      emit_turn(vim.list_slice(events, first, i - 1), out)
      first = i
    end
  end
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
