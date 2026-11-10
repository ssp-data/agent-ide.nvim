-- A copy of tests/fixtures/projects with fixed modification times, for tests that depend on the
-- order of the fixture projects (projects sort by last activity; fixtures without timestamps
-- fall back to the file's mtime, which a checkout sets in any order).
local M = {}

-- Newest first: the order the drawer lists them in.
M.ORDER = { '-home-u-git-alpha', '-home-u-git-alpha-docs', '-home-u-notes', '-nocwd' }
M.BASE = 1700000000 -- the newest file's mtime; each next one is an hour older

---Copy the fixture projects into a new temporary folder; returns its path (delete it after).
---@return string
function M.make()
  local src = vim.fn.fnamemodify('tests/fixtures/projects', ':p'):gsub('/$', '')
  local dst = vim.fn.tempname() .. '-projects'
  vim.fn.mkdir(dst, 'p')
  for i, name in ipairs(M.ORDER) do
    vim.fn.mkdir(dst .. '/' .. name, 'p')
    for _, f in ipairs(vim.fn.readdir(src .. '/' .. name)) do
      local to = dst .. '/' .. name .. '/' .. f
      vim.fn.writefile(vim.fn.readfile(src .. '/' .. name .. '/' .. f, 'b'), to, 'b')
      local t = M.BASE - (i - 1) * 3600
      assert(vim.uv.fs_utime(to, t, t))
    end
  end
  return dst
end

return M
