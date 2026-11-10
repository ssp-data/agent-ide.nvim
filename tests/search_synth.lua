-- Synthetic transcripts for the search tests (never real data).
local M = {}

local function enc(t) return vim.json.encode(t) end

---ISO timestamp `n` minutes after a fixed start.
function M.ts(n)
  return os.date('!%Y-%m-%dT%H:%M:%SZ', 1767225600 + n * 60)
end

function M.user(text, n, cwd)
  return enc({ type = 'user', cwd = cwd or '/w/repo', timestamp = M.ts(n), message = { role = 'user', content = text } })
end

function M.answer(text, n)
  return enc({ type = 'assistant', timestamp = M.ts(n), message = { content = { { type = 'text', text = text } } } })
end

function M.tool(name, command, id)
  return enc({ type = 'assistant', message = { content = { { type = 'tool_use', id = id, name = name, input = { command = command } } } } })
end

function M.result(id, text)
  return enc({ type = 'user', message = { content = { { type = 'tool_result', tool_use_id = id, content = text } } } })
end

function M.title(t) return enc({ type = 'ai-title', aiTitle = t }) end

---Write `lines` (a list, or one string) to `<root>/<project>/<id>.jsonl`; returns the path.
function M.write(root, project, id, lines)
  local dir = root .. '/' .. project
  vim.fn.mkdir(dir, 'p')
  local path = dir .. '/' .. id .. '.jsonl'
  local f = assert(io.open(path, 'wb'))
  f:write(type(lines) == 'string' and lines or (table.concat(lines, '\n') .. '\n'))
  f:close()
  return path
end

---Lines of a session with `rounds` rounds of prompt, answer and a tool call with `pad` bytes
---of output, about `words` (minutes counted from `t0`).
function M.session(cwd, rounds, words, pad, t0)
  local out, blob = {}, string.rep('o', pad)
  for n = 1, rounds do
    local t = (t0 or 0) + n
    out[#out + 1] = M.user(('prompt %d about %s'):format(n, words), t, cwd)
    out[#out + 1] = M.answer(('answer %d explaining %s in detail'):format(n, words), t)
    out[#out + 1] = M.tool('Bash', 'ls -la', 't' .. n)
    out[#out + 1] = M.result('t' .. n, blob)
  end
  return out
end

---`count` sessions in 30 projects, about `bytes` each; returns the projects dir.
function M.generate(root, count, bytes)
  local projects = root .. '/projects'
  local per_round = 4700
  for i = 1, count do
    local p = ('p%02d'):format(i % 30)
    local cwd = '/w/' .. p
    local words = ('topic%d Übersetzung parser%d'):format(i % 17, i)
    M.write(projects, '-w-' .. p, ('%08d-0000-4000-8000-000000000000'):format(i),
      M.session(cwd, math.max(1, math.floor(bytes / per_round)), words, 4200, i * 1000))
  end
  return projects
end

return M
