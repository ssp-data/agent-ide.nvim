-- Where the query of a search hit occurs in rendered lines (the picker's preview, the opened
-- transcript), which occurrence to show first, and the transcript's own highlights after
-- opening a hit. Matching is the search's own (`search.match`: smart case, umlauts compared
-- lower-cased), so the Rust helper and the Lua fallback highlight the same way. Fuzzy hits add
-- the text the search matched (from the hit's snippet), else the longest part of the word the
-- lines contain.
local api = vim.api
local match = require('agent-ide.search.match')

local M = {}

local MIN_PART = 3 -- shortest part of a fuzzy word highlighted on its own
local GAP = 3 -- matched letters of one fuzzy match lie at most this many bytes apart

local function lower(s)
  if s:find('[\128-\255]') then return vim.fn.tolower(s) end
  return s:lower()
end

local function term(raw)
  local low = lower(raw)
  return { raw = raw, needle = low, cs = false }
end

-- Ranges of `hit.positions` (byte offsets in the snippet) that no exact word covers: the
-- letters of a fuzzy match, grouped into the texts they span.
local function fuzzy_spans(hit, words)
  local sn, pos = hit.snippet, hit.positions
  if hit.match ~= 'fuzzy' or type(sn) ~= 'string' or type(pos) ~= 'table' then return {} end
  local exact = match.positions(sn, words)
  local rest = {}
  for _, r in ipairs(pos) do
    local s, e = r[1], r[2]
    local covered = false
    for _, x in ipairs(exact) do
      if s >= x[1] and e <= x[2] then covered = true; break end
    end
    if not covered and type(s) == 'number' and type(e) == 'number' and e > s then rest[#rest + 1] = { s, e } end
  end
  table.sort(rest, function(a, b) return a[1] < b[1] end)
  local spans, out = {}, {}
  for _, r in ipairs(rest) do
    local last = spans[#spans]
    if last and r[1] - last[2] <= GAP then last[2] = math.max(last[2], r[2]) else spans[#spans + 1] = { r[1], r[2] } end
  end
  for _, s in ipairs(spans) do
    local text = vim.trim(sn:sub(s[1] + 1, s[2]))
    if vim.fn.strchars(text) >= 2 then out[#out + 1] = text end
  end
  return out
end

-- The longest part (at least MIN_PART characters) of word `w` that `hay` (lower-cased) holds.
local function best_part(hay, w)
  local chars = vim.fn.split(w.needle, '\\zs')
  local n = #chars
  for len = n - 1, math.max(MIN_PART, math.ceil(n / 2)), -1 do
    for i = 1, n - len + 1 do
      local part = table.concat(chars, '', i, i + len - 1)
      if hay:find(part, 1, true) then return part end
    end
  end
end

local function found_in(text, w)
  return type(text) == 'string' and text ~= '' and match.find(match.prepare(text), w, 1) ~= nil
end

---The terms to mark for `query` on `hit`: its words, then for a fuzzy hit what the search
---matched. Each term knows whether the hit's row already shows it (`visible`: in its title or
---project name). `lines` (rendered text) is read only for a fuzzy hit without a matched span.
---@param query string
---@param hit table
---@param lines? string[]|fun(): string[]
---@return { raw: string, needle: string, cs: boolean, visible: boolean, fuzzy?: boolean }[]
function M.terms(query, hit, lines)
  local words = match.words(query)
  local terms = {}
  for _, w in ipairs(words) do terms[#terms + 1] = w end
  if hit and hit.match == 'fuzzy' then
    local spans = fuzzy_spans(hit, words)
    for _, text in ipairs(spans) do
      local t = term(text)
      t.fuzzy = true
      terms[#terms + 1] = t
    end
    if #spans == 0 and lines then
      if type(lines) == 'function' then lines = lines() end
      local hay
      for _, w in ipairs(words) do
        if vim.fn.strchars(w.needle) > MIN_PART and not found_in(hit.title, w) and not found_in(hit.project, w) then
          hay = hay or lower(table.concat(lines, '\n'))
          if not hay:find(w.needle, 1, true) then
            local part = best_part(hay, w)
            if part then
              local t = term(part)
              t.fuzzy = true
              terms[#terms + 1] = t
            end
          end
        end
      end
    end
  end
  for _, t in ipairs(terms) do
    t.visible = hit ~= nil and (found_in(hit.title, t) or found_in(hit.project, t))
  end
  return terms
end

-- Occurrences of `terms` in `lines` a..b, line by line (texts whose lower-cased form has
-- another byte length).
local function by_line(lines, terms, a, b, out)
  for l = a, b do
    local line = lines[l]
    if line ~= '' then
      local p = match.prepare(line)
      for _, t in ipairs(terms) do
        local s, e = match.find(p, t, 1)
        while s do
          out[#out + 1] = { line = l, s = s - 1, e = e, hidden = not t.visible }
          s, e = match.find(p, t, e + 1)
        end
      end
    end
  end
end

---Every occurrence of `terms` in `lines` (lines `from`..`to`), in text order; overlapping ones
---are one. `hidden`: one of its terms is not shown in the hit's row.
---@return { line: integer, s: integer, e: integer, hidden: boolean }[] line 1-based; s, e 0-based bytes, e exclusive
function M.occurrences(lines, terms, from, to)
  local found = {}
  local a, b = from or 1, math.min(to or #lines, #lines)
  if #terms == 0 or a > b then return found end
  -- the whole text at once: one lower-casing, plain finds; offsets back to lines by bisection
  local text = table.concat(lines, '\n', a, b)
  local low = lower(text)
  if #low ~= #text then
    by_line(lines, terms, a, b, found)
  else
    local starts, at = {}, 1
    for l = a, b do
      starts[#starts + 1] = at
      at = at + #lines[l] + 1
    end
    for _, t in ipairs(terms) do
      local hay, needle, init = t.cs and text or low, t.needle, 1
      local k = 1
      while true do
        local s, e = hay:find(needle, init, true)
        if not s then break end
        -- the line holding byte s: lines are visited in order, so walk forward
        while k < #starts and starts[k + 1] <= s do k = k + 1 end
        local st = starts[k]
        found[#found + 1] = { line = a + k - 1, s = s - st, e = e - st + 1, hidden = not t.visible }
        init = e + 1
      end
    end
  end
  if #terms > 1 then
    table.sort(found, function(x, y)
      if x.line ~= y.line then return x.line < y.line end
      return x.s < y.s
    end)
  end
  local merged, last = {}, nil
  for _, o in ipairs(found) do
    if last and o.line == last.line and o.s < last.e then
      last.e = math.max(last.e, o.e)
      last.hidden = last.hidden or o.hidden
    else
      merged[#merged + 1] = o
      last = o
    end
  end
  return merged
end

---Index of the occurrence to show first: the first one of a term the hit's row does not show,
---at or after line `from` (else anywhere), else the first one of any term at or after `from`
---(else anywhere); nil when there is none.
---@return integer|nil
function M.pick(occ, from)
  from = from or 1
  local hidden_any, after, any
  for i, o in ipairs(occ) do
    if o.hidden then
      if o.line >= from then return i end
      hidden_any = hidden_any or i
    end
    if o.line >= from then after = after or i end
    any = any or i
  end
  return hidden_any or after or any
end

---Every term is in the hit's title or project name (and there is at least one).
function M.all_visible(terms)
  if #terms == 0 then return false end
  for _, t in ipairs(terms) do
    if not t.visible then return false end
  end
  return true
end

-- Transcript windows -------------------------------------------------------------------------

M.KEYS_DESC = 'Agent-IDE search: '

local W = {} -- win -> { buf, terms, ids, cur_id, maps = { [lhs] = true } }
local augroup

local function pattern(t)
  return (t.cs and '\\C' or '\\c') .. '\\V' .. t.raw:gsub('\\', '\\\\')
end

local function echo(msg) api.nvim_echo({ { msg } }, false, {}) end

local function occ_of(st)
  local tick = api.nvim_buf_get_changedtick(st.buf)
  if st.tick ~= tick then
    st.occ = M.occurrences(api.nvim_buf_get_lines(st.buf, 0, -1, false), st.terms)
    st.tick = tick
  end
  return st.occ
end

local function mark_current(win, st, o)
  if st.cur_id then pcall(vim.fn.matchdelete, st.cur_id, win) end
  st.cur_id = nil
  if o then
    st.cur_id = vim.fn.matchaddpos('AgentIdeSearchMatchCurrent', { { o.line, o.s + 1, o.e - o.s } }, 21, -1, { window = win })
  end
end

local function unmap(st)
  for lhs in pairs(st.maps or {}) do
    -- the buffer may be shown with highlights in another window still
    local other = false
    for w, s in pairs(W) do
      if s ~= st and s.buf == st.buf and api.nvim_win_is_valid(w) then other = true end
    end
    if not other and api.nvim_buf_is_valid(st.buf) then pcall(vim.keymap.del, 'n', lhs, { buffer = st.buf }) end
  end
  st.maps = {}
end

---Remove the highlights (and their keys) of transcript window `win`.
function M.clear(win)
  local st = W[win]
  if not st then return end
  W[win] = nil
  if api.nvim_win_is_valid(win) then
    for _, id in ipairs(st.ids) do pcall(vim.fn.matchdelete, id, win) end
    if st.cur_id then pcall(vim.fn.matchdelete, st.cur_id, win) end
  end
  unmap(st)
end

---Remove the highlights of every transcript window (a new search starts).
function M.clear_all()
  for _, win in ipairs(vim.tbl_keys(W)) do M.clear(win) end
end

local function setup_autocmds()
  if augroup then return end
  augroup = api.nvim_create_augroup('agent-ide.search_hl', { clear = true })
  api.nvim_create_autocmd('WinClosed', { group = augroup, callback = function(ev)
    local win = tonumber(ev.match)
    if win and W[win] then M.clear(win) end
  end })
  -- the window shows another buffer: its matches would stay on that one
  api.nvim_create_autocmd({ 'BufWinEnter', 'BufWinLeave' }, { group = augroup, callback = function()
    vim.schedule(function()
      for win, st in pairs(W) do
        if not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= st.buf then M.clear(win) end
      end
    end)
  end })
end

---Step to the next (`d` = 1) or previous (-1) occurrence in transcript window `win`, wrapping.
---@return integer|nil index, integer|nil count
function M.step(win, d)
  local st = W[win]
  if not st or not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= st.buf then return end
  local occ = occ_of(st)
  if #occ == 0 then
    echo('Agent-IDE search: no match in this transcript')
    return nil, 0
  end
  local cur = api.nvim_win_get_cursor(win)
  local l, c = cur[1], cur[2]
  local pick
  if d > 0 then
    for i, o in ipairs(occ) do
      if o.line > l or (o.line == l and o.s > c) then pick = i; break end
    end
    pick = pick or 1
  else
    for i = #occ, 1, -1 do
      local o = occ[i]
      if o.line < l or (o.line == l and o.s < c) then pick = i; break end
    end
    pick = pick or #occ
  end
  local o = occ[pick]
  api.nvim_win_set_cursor(win, { o.line, o.s })
  api.nvim_win_call(win, function() vim.cmd('normal! zvzz') end)
  mark_current(win, st, o)
  echo(('Agent-IDE search: match %d/%d'):format(pick, #occ))
  return pick, #occ
end

---Highlight `terms` in transcript window `win` (window-local matches: the search register and
---'hlsearch' stay as they are), the occurrence `cur` as the current one; map the step keys
---(`keys.next`, `keys.prev`, normal mode) and `<Esc>` (clears) buffer-locally where the buffer
---does not map them already.
---@param win integer
---@param terms table[] from `terms()`
---@param cur? table an occurrence
---@param keys { next: string[], prev: string[] }
function M.attach(win, terms, cur, keys)
  M.clear(win)
  if #terms == 0 or not api.nvim_win_is_valid(win) then return end
  setup_autocmds()
  local buf = api.nvim_win_get_buf(win)
  local st = { buf = buf, terms = terms, ids = {}, maps = {} }
  for _, t in ipairs(terms) do
    st.ids[#st.ids + 1] = vim.fn.matchadd('AgentIdeSearchMatch', pattern(t), 20, -1, { window = win })
  end
  W[win] = st
  mark_current(win, st, cur)
  local function map(lhs, fn, what)
    local m = vim.fn.maparg(lhs, 'n', false, true)
    local ours = type(m) == 'table' and m.desc and vim.startswith(m.desc, M.KEYS_DESC)
    if type(m) == 'table' and m.buffer == 1 and not ours then return end -- the buffer's own map stays
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true, desc = M.KEYS_DESC .. what })
    st.maps[lhs] = true
  end
  api.nvim_buf_call(buf, function()
    local function here(d) return function() M.step(api.nvim_get_current_win(), d) end end
    for _, lhs in ipairs(keys.next or {}) do map(lhs, here(1), 'next match') end
    for _, lhs in ipairs(keys.prev or {}) do map(lhs, here(-1), 'previous match') end
    map('<Esc>', function()
      M.clear(api.nvim_get_current_win())
      -- a global <Esc> mapping of the user's still runs (once this buffer's is gone)
      local still = vim.fn.maparg('<Esc>', 'n', false, true)
      if type(still) == 'table' and still.buffer == 1 then return end
      for _, m in ipairs(api.nvim_get_keymap('n')) do
        if m.lhs == '<Esc>' then return api.nvim_feedkeys(vim.keycode('<Esc>'), 'm', false) end
      end
    end, 'clear the highlights')
  end)
end

---Test only: the windows with highlights.
function M._state()
  local out = {}
  for win, st in pairs(W) do
    out[#out + 1] = { win = win, buf = st.buf, ids = st.ids, cur_id = st.cur_id, maps = vim.tbl_keys(st.maps) }
  end
  return out
end

return M
