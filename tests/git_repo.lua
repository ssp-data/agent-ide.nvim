-- Temporary git repositories for tests. Local user config only; global and system config are
-- ignored so results never depend on the machine.
local M = {}

M.ENV = { GIT_CONFIG_GLOBAL = '/dev/null', GIT_CONFIG_NOSYSTEM = '1', GIT_AUTHOR_DATE = '2026-01-01T00:00:00Z',
  GIT_COMMITTER_DATE = '2026-01-01T00:00:00Z' }

---Run git in `dir`; errors on failure.
---@param dir string
---@param args string[]
---@return string stdout
function M.git(dir, args)
  local r = vim.system(vim.list_extend({ 'git', '-C', dir }, args), { env = M.ENV, text = true }):wait()
  if r.code ~= 0 then error('git ' .. table.concat(args, ' ') .. ' failed: ' .. (r.stderr or ''), 2) end
  return r.stdout
end

---New repository at `dir` (created) with a local identity, on branch `branch` (default main).
---@param dir string
---@param branch? string
function M.init(dir, branch)
  vim.fn.mkdir(dir, 'p')
  M.git(dir, { 'init', '-q', '-b', branch or 'main' })
  M.git(dir, { 'config', 'user.name', 'Test' })
  M.git(dir, { 'config', 'user.email', 'test@example.invalid' })
  M.git(dir, { 'config', 'commit.gpgsign', 'false' })
  return dir
end

---Write `content` (string, or lines when a table) to `dir/path`, creating folders.
function M.write(dir, path, content)
  local full = dir .. '/' .. path
  vim.fn.mkdir(vim.fn.fnamemodify(full, ':h'), 'p')
  local f = assert(io.open(full, 'wb'))
  f:write(type(content) == 'table' and (table.concat(content, '\n') .. '\n') or content)
  f:close()
end

---Stage everything and commit with `msg`; returns the new HEAD hash.
function M.commit(dir, msg)
  M.git(dir, { 'add', '-A' })
  M.git(dir, { 'commit', '-q', '-m', msg })
  return vim.trim(M.git(dir, { 'rev-parse', 'HEAD' }))
end

---A fresh temporary folder (real path).
function M.tmp()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, 'p')
  return vim.uv.fs_realpath(d)
end

---Call `fn(cb)` and wait for `cb`'s arguments.
---@return any ...
function M.await(fn, ms)
  local res
  fn(function(...) res = { n = select('#', ...), ... } end)
  if not vim.wait(ms or 5000, function() return res ~= nil end, 5) then error('timed out', 2) end
  return unpack(res, 1, res.n)
end

return M
