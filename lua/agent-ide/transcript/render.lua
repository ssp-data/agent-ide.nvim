-- Renders transcript events into buffer lines plus fold ranges, and the lines where Claude's own
-- text (an answer, a remark between tool calls) starts: the view marks them with a `●`. The
-- removed and added lines of an `Edit`, the command of a `Bash` and the colour codes of tool
-- output (`ansi`, the codes left out of the text) are listed too: the view colours them.
local ansi = require('agent-ide.transcript.ansi')
local textdiff = require('agent-ide.util.textdiff')

local M = {}

local GUTTER = '│ '

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
---@return string line, integer kept bytes of `line`
local function cut_line(line, max)
  local n = #line
  if n <= max then return line, n end
  local keep = max
  -- back up over continuation bytes (10xxxxxx) so no character is split
  while keep > 0 do
    local b = line:byte(keep + 1)
    if b < 0x80 or b >= 0xC0 then break end
    keep = keep - 1
  end
  return line:sub(1, keep) .. (' … +%d bytes (gr shows the raw line)'):format(n - keep), keep
end

---`cut_line` for every line of a list (the same count of lines comes back).
local function cut_lines(lines, max)
  for i, l in ipairs(lines) do
    if #l > max then lines[i] = (cut_line(l, max)) end
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

local EDIT_CONTEXT = 3 -- unchanged lines shown around a change of an Edit

-- The body of an `Edit` as a diff of its old and new text: unchanged lines as context (`  `),
-- three around each change and the rest counted (`… n unchanged lines`), removed lines `- `,
-- added lines `+ `, at most 30 of each (the rest counted). `signs` says which index is which;
-- `spans` marks the changed text of a removed line and the added line paired with it (0-based
-- byte columns in the line, the group as `ansi` spans carry it).
local function edit_body(old, new)
  local lines, signs, spans = {}, {}, {}
  local n_del, n_add = 0, 0
  local function context(from, to)
    for i = from, to do lines[#lines + 1] = '  ' .. old[i] end
  end
  local function gap(from, to)
    if to < from then return end
    if to - from + 1 <= EDIT_CONTEXT then return context(from, to) end
    lines[#lines + 1] = ('… %d unchanged lines'):format(to - from + 1 - EDIT_CONTEXT)
    context(to - EDIT_CONTEXT + 1, to)
  end
  -- unchanged lines between two changes: three after the one, three before the other
  local function between(from, to)
    if to - from + 1 <= 2 * EDIT_CONTEXT then return context(from, to) end
    context(from, from + EDIT_CONTEXT - 1)
    lines[#lines + 1] = ('… %d unchanged lines'):format(to - from + 1 - 2 * EDIT_CONTEXT)
    context(to - EDIT_CONTEXT + 1, to)
  end
  local hunks = vim.diff(table.concat(old, '\n') .. '\n', table.concat(new, '\n') .. '\n', { result_type = 'indices' })
  local pos = 1 -- the next line of `old` not shown yet
  for _, h in ipairs(hunks or {}) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    local before = ca == 0 and sa or sa - 1 -- a pure insertion comes after line `sa`
    if pos <= before then
      if pos == 1 then gap(pos, before) else between(pos, before) end
    end
    local del_first = #lines + 1
    local more_del, more_add = 0, 0 -- of this change, beyond the caps: counted right after its lines
    for i = sa, sa + ca - 1 do
      if n_del < CAP_EDIT_SIDE then
        n_del = n_del + 1
        lines[#lines + 1] = '- ' .. old[i]
        signs[#lines] = '-'
      else
        more_del = more_del + 1
      end
    end
    if more_del > 0 then lines[#lines + 1] = ('… %d more removed lines'):format(more_del) end
    for j = 0, cb - 1 do
      if n_add < CAP_EDIT_SIDE then
        n_add = n_add + 1
        lines[#lines + 1] = '+ ' .. new[sb + j]
        signs[#lines] = '+'
        -- the removed line this one replaces, when both are shown: its changed text
        local del = del_first + j
        if j < ca and signs[del] == '-' then
          local a, b = old[sa + j], new[sb + j]
          local p, s = textdiff.changed(a, b)
          if p then
            if #a - s > p then spans[del] = { { 2 + p, 2 + #a - s, 'AgentIdeDiffDelText' } } end
            if #b - s > p then spans[#lines] = { { 2 + p, 2 + #b - s, 'AgentIdeDiffAddText' } } end
          end
        end
      else
        more_add = more_add + 1
      end
    end
    if more_add > 0 then lines[#lines + 1] = ('… %d more added lines'):format(more_add) end
    pos = before + 1 + ca
  end
  if pos <= #old then
    -- the unchanged tail: three lines, the rest counted (no change at all: the same, from the start)
    local last = #old
    if last - pos + 1 <= EDIT_CONTEXT then
      context(pos, last)
    else
      context(pos, pos + EDIT_CONTEXT - 1)
      lines[#lines + 1] = ('… %d unchanged lines'):format(last - (pos + EDIT_CONTEXT - 1))
    end
  end
  return lines, signs, spans
end

---Body lines of a tool call; for an `Edit` also which of them are removed (`-`) or added (`+`)
---lines, for a `Bash` which are the command (`$`), by index (the `… n more lines` markers are
---none of these), and the spans of changed text in an `Edit` (by index, as `ansi` spans).
---@return string[] lines, table<integer, string>|nil signs, table<integer, table[]>|nil spans
local function call_body(call)
  local input = type(call.input) == 'table' and call.input or {}
  local lines
  if call.name == 'Bash' then
    lines = split('$ ' .. tostring(input.command or ''))
    local signs = {}
    for i = 1, math.min(#lines, CAP_INPUT) do signs[i] = '$' end
    return cut_lines(cap(lines, CAP_INPUT), M.MAX_FOLD_LINE), signs
  elseif call.name == 'Edit' then
    local lines, signs, spans = edit_body(split(input.old_string), split(input.new_string))
    return cut_lines(lines, M.MAX_FOLD_LINE), signs, spans
  elseif call.name == 'Write' then
    lines = split(input.content)
  else
    lines = split(vim.inspect(call.input, INSPECT_OPTS))
  end
  return cut_lines(cap(lines, CAP_INPUT), M.MAX_FOLD_LINE)
end

---Lines of a tool result without their colour codes, and the coloured spans per line index
---(`ansi.parse`, clipped to what a cut line still shows).
---@return string[] lines, table<integer, table[]> spans
local function result_lines(res)
  local lines, spans, state = cap(split(res.text), CAP_RESULT), {}, nil
  for i = 1, math.min(#lines, CAP_RESULT) do
    local sp
    lines[i], sp, state = ansi.parse(lines[i], state)
    if #sp > 0 then spans[i] = sp end
  end
  if res.is_error then
    lines[1] = 'ERROR ' .. lines[1]
    for _, s in ipairs(spans[1] or {}) do s[1], s[2] = s[1] + 6, s[2] + 6 end
  end
  for i, l in ipairs(lines) do
    if #l > M.MAX_FOLD_LINE then
      local keep
      lines[i], keep = cut_line(l, M.MAX_FOLD_LINE)
      local kept = {}
      for _, s in ipairs(spans[i] or {}) do
        if s[1] < keep then kept[#kept + 1] = { s[1], math.min(s[2], keep), s[3] } end
      end
      spans[i] = kept
    end
  end
  return lines, spans
end

---Emit rendered events into `out` ({lines, folds, answers, added, removed, commands, ansi}); `results` maps id -> results, `known` is the set of call ids; `nested` renders a sidechain group's own events without regrouping.
local function emit(events, results, known, out, nested)
  -- `spans`: the coloured spans of body lines, by index into `body` (from `result_lines`)
  local function block(header, body, spans)
    local first = #out.lines + 1
    out.lines[first] = (cut_line(header, M.MAX_FOLD_LINE))
    for _, l in ipairs(body) do out.lines[#out.lines + 1] = GUTTER .. l end
    out.folds[#out.folds + 1] = { first = first, last = #out.lines }
    for k, list in pairs(spans or {}) do
      for _, s in ipairs(list) do
        out.ansi[#out.ansi + 1] = { line = first + k, col = #GUTTER + s[1], end_col = #GUTTER + s[2], hl = s[3] }
      end
    end
    return first
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
        local inner = { lines = {}, folds = {}, answers = {}, added = {}, removed = {}, commands = {}, ansi = {}, edits = {} }
        emit(group, results, known, inner, true)
        local first = block(('▸ subagent (%d events)'):format(#group), inner.lines)
        -- a subagent's Edit folds are not folds of their own here (the whole group is one fold)
        for _, l in ipairs(inner.added) do out.added[#out.added + 1] = first + l end
        for _, l in ipairs(inner.removed) do out.removed[#out.removed + 1] = first + l end
        for _, l in ipairs(inner.commands) do out.commands[#out.commands + 1] = first + l end
        for _, a in ipairs(inner.ansi) do
          out.ansi[#out.ansi + 1] = { line = first + a.line, col = #GUTTER + a.col, end_col = #GUTTER + a.end_col, hl = a.hl }
        end
        i = j
      else
        if ev.kind == 'text' then
          if not nested and ev.text ~= '' then out.answers[#out.answers + 1] = #out.lines + 1 end
          plain(cut_lines(split(ev.text), M.MAX_TEXT_LINE))
          plain({ '' })
        elseif ev.kind == 'tool_call' then
          local body, signs, edit_spans = call_body(ev)
          local n, spans = #body, {}
          for k, list in pairs(edit_spans or {}) do spans[k] = list end
          for _, res in ipairs(results[ev.id] or {}) do
            local lines, sp = result_lines(res)
            for k, list in pairs(sp) do spans[#body + k] = list end
            vim.list_extend(body, lines)
          end
          local first = block(('▸ %s: %s'):format(first_line(ev.name or '?'), summary(ev.input)), body, spans)
          if ev.name == 'Edit' then
            out.folds[#out.folds].edit = true
            out.edits[#out.edits + 1] = first
          end
          for k = 1, signs and n or 0 do
            if signs[k] == '+' then
              out.added[#out.added + 1] = first + k
            elseif signs[k] == '-' then
              out.removed[#out.removed + 1] = first + k
            elseif signs[k] == '$' then
              out.commands[#out.commands + 1] = first + k
            end
          end
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
  return summary(input), (call_body({ name = name, input = input }))
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
---`added`, `removed`: the `+` and `-` lines of every `Edit`, a subagent's included; `edits`: the first
---line of every `Edit` fold of its own (they start open; a subagent's are inside its fold).
---`commands`: the command lines of every `Bash` call, a subagent's included.
---`ansi`: the coloured spans of tool results (0-based byte columns, end exclusive), with the
---highlight group `ansi.spec` defines.
---@param events table[]
---@return { lines: string[], folds: { first: integer, last: integer, edit: boolean|nil }[], answers: integer[], added: integer[], removed: integer[], commands: integer[], ansi: { line: integer, col: integer, end_col: integer, hl: string }[], edits: integer[] }
function M.render(events)
  local out = { lines = {}, folds = {}, answers = {}, added = {}, removed = {}, commands = {}, ansi = {}, edits = {} }
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
