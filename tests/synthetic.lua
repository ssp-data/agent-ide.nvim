-- Synthetic transcript text for tests (never real data). Shared by several test files.
local M = {}

local KIB = 1024

---Assistant text records totalling at least `n` bytes.
function M.filler(n)
  local line = vim.json.encode({ type = 'assistant', message = { content = { { type = 'text', text = string.rep('f', 1000) } } } }) .. '\n'
  return string.rep(line, math.floor(n / #line) + 1)
end

function M.title_line(t) return vim.json.encode({ type = 'ai-title', aiTitle = t }) .. '\n' end

---A transcript of more than 600 KiB with optional ai-title records near the start, in the
---middle (outside both metadata windows) and near the end. Same shape as the Rust tests.
function M.big(early, middle, late)
  local s = '{"type":"user","cwd":"/w","message":{"content":"first prompt"}}\n'
  if early then s = s .. M.title_line(early) end
  s = s .. M.filler(300 * KIB)
  if middle then s = s .. M.title_line(middle) end
  s = s .. M.filler(300 * KIB)
  if late then s = s .. M.title_line(late) end
  s = s .. M.filler(10 * KIB)
  assert(#s > 600 * KIB)
  return s
end

---Write `text` to `path` as bytes, creating the directory.
function M.write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  local f = assert(io.open(path, 'wb'))
  f:write(text)
  f:close()
end

return M
