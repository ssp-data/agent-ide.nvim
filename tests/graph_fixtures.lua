-- `git log --graph` fixtures for the commit graph (graph shapes as git 2.56 draws them for small
-- synthetic histories). Each line: `<graph>@<id>\t<%D>\t<parent ids>\t<subject>` for a commit,
-- else the graph alone. `M.out(name)` turns a fixture into the bytes git prints for the format
-- of git.graph: ids padded to 40 hex digits, author `Ana`, times a minute apart going back from
-- M.NOW.
local M = {}

M.NOW = 1767225600 -- 2026-01-01T00:00:00Z

M.linear = {
  '* @a1\tHEAD -> refs/heads/main\tb2\tthird',
  '* @b2\t\tc3\tsecond',
  '* @c3\t\t\tfirst',
}

M.merge = {
  "*   @a1\tHEAD -> refs/heads/main, refs/remotes/origin/main\tf1 b2\tMerge branch 'long'",
  '|\\  ',
  '* | @f1\t\te0\tchore: drop the old poller',
  '| * @b2\trefs/heads/long\tb1\ttest: retry with a fake server',
  '| * @b1\t\te0\tfeat: retry loop',
  '|/  ',
  '* @e0\ttag: refs/tags/v0.3.0\tc0\trelease notes',
  '* @c0\t\t\tinitial import',
}

M.octopus = {
  "*---.   @01\ttag: refs/tags/v1\td1 a1 b1 e1\tMerge branches 'x', 'y' and 'z'",
  '|\\ \\ \\  ',
  '* | | | @d1\t\tc1\td',
  '| * | | @a1\trefs/heads/x\tb0\tx1',
  '| | * | @b1\trefs/heads/y\tc1\ty1',
  '| |/ /  ',
  '|/| |   ',
  '| | * @e1\trefs/heads/z\tc1\tz1',
  '| |/  ',
  '|/|   ',
  '* | @c1\t\tb0\tc',
  '|/  ',
  '* @b0\t\t\tb',
}

-- two long-lived branches merging into each other
M.crossing = {
  '* @d4\tHEAD -> refs/heads/dev\td3\td4',
  '| * @a5\trefs/heads/main\ta4\tm5',
  "* | @d3\t\td2 a4\tMerge branch 'main' into dev",
  '|\\| ',
  '* | @d2\t\td1\td3',
  '| * @a4\t\ta3\tm4',
  "| *   @a3\t\ta2 d1\tMerge branch 'dev'",
  '| |\\  ',
  '| |/  ',
  '|/|   ',
  '| * @a2\t\ta1\tm3',
  '* | @d1\t\tc0\td2',
  '|/  ',
  '* @c0\t\t\tm1',
}

M.refs = {
  '* @a1\tHEAD -> refs/heads/feat/retry, refs/remotes/origin/feat/retry, refs/remotes/origin/HEAD, tag: refs/tags/v1.0/rc1\tb2\tretry',
  '* @b2\trefs/remotes/upstream/main, refs/heads/main\t\tbase',
}

M.detached = {
  '* @a1\tHEAD\tb2\ton a detached head',
  '* @b2\trefs/heads/main, grafted\t\tshallow boundary',
}

local function hash(id) return id .. string.rep('0', 40 - #id) end

---@param name string|string[] a fixture name or lines
---@return string
function M.out(name)
  local lines = type(name) == 'table' and name or M[name]
  local out, n = {}, 0
  for _, l in ipairs(lines) do
    local graph, id, d, parents, subject = l:match('^([^@]*)@(%x+)\t([^\t]*)\t([^\t]*)\t(.*)$')
    if graph then
      local ps = {}
      for p in parents:gmatch('%x+') do ps[#ps + 1] = hash(p) end
      out[#out + 1] = table.concat({ graph .. '\30' .. hash(id), id, d, tostring(M.NOW - n * 60), 'Ana', table.concat(ps, ' '),
        subject }, '\31')
      n = n + 1
    else
      out[#out + 1] = l
    end
  end
  return table.concat(out, '\n') .. '\n'
end

M.hash = hash

return M
