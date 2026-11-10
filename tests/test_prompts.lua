-- Prompt sources: scanning folders of commands, skills, templates and saved prompts (synthetic
-- fixtures in tests/fixtures/prompts; project folders and odd files are made in a temp dir).
local eq = MiniTest.expect.equality
local sources = require('agent-ide.prompts.sources')

local FIX = vim.fn.fnamemodify('tests/fixtures/prompts', ':p'):gsub('/$', '')
local tmp

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    tmp = vim.uv.fs_realpath(tmp)
  end,
  post_case = function() vim.fn.delete(tmp, 'rf') end,
} })

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local f = assert(io.open(path, 'wb'))
  f:write(text)
  f:close()
end

local function scan(opts)
  local got
  sources.scan(opts, function(entries) got = entries end)
  if not vim.wait(10000, function() return got ~= nil end, 2) then error('scan never finished') end
  return got
end

local function by(entries, field, value)
  for _, e in ipairs(entries) do
    if e[field] == value then return e end
  end
end

-- The fixture set plus the odd skill (CRLF, malformed frontmatter) made here.
local function fixture_opts(extra)
  vim.fn.system({ 'cp', '-r', FIX .. '/skills', tmp .. '/skills' })
  write(tmp .. '/skills/broken/SKILL.md', '---\r\nname: [unclosed\r\ndescription: "a broken: yaml {\r\n: : :\r\n---\r\nBroken skill body.\r\n')
  return vim.tbl_extend('force', { command_dirs = { FIX .. '/commands' }, skill_dirs = { tmp .. '/skills' },
    library_dir = FIX .. '/library', saved_dir = FIX .. '/saved', project_name = 'alpha' }, extra or {})
end

T['commands, skills: names, inserts, one-line descriptions'] = function()
  local e = scan(fixture_opts())
  local inserts = {}
  for _, x in ipairs(e) do
    if x.insert then inserts[#inserts + 1] = x.insert end
  end
  table.sort(inserts)
  eq(inserts, { '/broken', '/dataviz-pro', '/fix-grammar', '/git:sync' })
  -- a command keeps its file name even when the frontmatter names it otherwise
  local fg = by(e, 'insert', '/fix-grammar')
  eq({ fg.kind, fg.scope, fg.description }, { 'command', 'user', 'Fix grammar and spelling in the given text' })
  eq(by(e, 'insert', '/git:sync').description, nil)
  local dv = by(e, 'insert', '/dataviz-pro')
  eq({ dv.kind, dv.name, dv.description }, { 'skill', 'dataviz-pro', 'Make clean charts from compact specs.' })
  local br = by(e, 'insert', '/broken')
  eq({ br.kind, br.name }, { 'skill', 'broken' })
end

T['library groups and titles; saved prompts of the project'] = function()
  local e = scan(fixture_opts())
  local li = by(e, 'path', FIX .. '/library/writing/linkedin-post.md')
  eq({ li.kind, li.scope, li.group, li.title, li.insert }, { 'template', 'library', 'writing', 'LinkedIn post', nil })
  local tw = by(e, 'path', FIX .. '/library/writing/social/tweet.md')
  eq({ tw.group, tw.title }, { 'writing/social', 'tweet' })
  local inv = by(e, 'path', FIX .. '/library/invoice.md')
  eq({ inv.group, inv.title, inv.description }, { nil, 'Invoice text', 'Short invoice text for a client' })
  local sv = by(e, 'kind', 'saved')
  eq({ sv.scope, sv.title, sv.path }, { 'saved', 'add idle support', FIX .. '/saved/alpha/add-idle-support.md' })
  -- sorted by group, then title, case-insensitive
  local order = vim.tbl_map(function(x) return (x.group or ''):gsub('/', '\1') .. '\0' .. x.title end, e)
  local sorted = vim.deepcopy(order)
  table.sort(sorted, function(a, b) return a:lower() < b:lower() end)
  eq(order, sorted)
end

T['a project command shadows the user one and is marked project'] = function()
  local root = tmp .. '/proj'
  vim.fn.mkdir(root .. '/.claude/commands', 'p')
  vim.fn.system({ 'cp', FIX .. '/project-commands/fix-grammar.md', root .. '/.claude/commands/' })
  local e = scan(fixture_opts({ project_root = root }))
  local n = 0
  for _, x in ipairs(e) do
    if x.insert == '/fix-grammar' then n = n + 1 end
  end
  eq(n, 1)
  local fg = by(e, 'insert', '/fix-grammar')
  eq({ fg.scope, fg.description }, { 'project', 'Project grammar rules' })
  -- project_dirs = false: only the user one
  e = scan(fixture_opts({ project_root = root, project_dirs = false }))
  eq(by(e, 'insert', '/fix-grammar').scope, 'user')
end

T['parse: CRLF, malformed YAML, none, body starting with ---, quotes, unclosed'] = function()
  local p = sources.parse('---\r\nname: x-y\r\ndescription: "quoted: yes"\r\n---\r\nbody\r\n')
  eq({ p.name, p.description, p.body }, { 'x-y', 'quoted: yes', 'body\r\n' })
  p = sources.parse('---\n: : [\n{{{\nname\n---\nB')
  eq({ p.name, p.description, p.body }, { nil, nil, 'B' })
  p = sources.parse('no frontmatter\n---\nstill body\n')
  eq({ p.name, p.body, p.frontmatter }, { nil, 'no frontmatter\n---\nstill body\n', nil })
  p = sources.parse('---\nname: a\n---\n---\nbody\n')
  eq({ p.name, p.body, p.frontmatter }, { 'a', '---\nbody\n', '---\nname: a\n---\n' })
  p = sources.parse("---\nname: 'it''s'\ndescription: |\n  one\n  two\n---\n")
  eq({ p.name, p.description, p.body }, { "it's", 'one two', '' })
  p = sources.parse('---\nname: never closed\nbody\n')
  eq({ p.name, p.body }, { nil, '---\nname: never closed\nbody\n' })
  p = sources.parse('---\ndescription: ' .. string.rep('long ', 400) .. '\n---\n')
  eq(vim.fn.strchars(p.description) <= 500, true)
  eq(p.description:find('\n'), nil)
  for _, odd in ipairs({ '', '---', '---\n', '\0\1\2', string.rep('-', 10000) }) do sources.parse(odd) end
end

T['a frontmatter block longer than the first read still gives the name'] = function()
  write(tmp .. '/skills/long/SKILL.md', '---\ndescription: ' .. string.rep('x', 20000) .. '\nname: long-one\n---\nbody\n')
  local e = scan({ skill_dirs = { tmp .. '/skills' } })
  eq(e[1].insert, '/long-one')
  eq(vim.fn.strchars(e[1].description), 500)
end

T['read: the body without frontmatter, byte for byte; a gone file'] = function()
  local got
  sources.read({ path = FIX .. '/library/writing/linkedin-post.md' }, function(t) got = t end)
  eq(got, '# LinkedIn post\n\nWrite a LinkedIn post about:\n\t- topic\nwith trailing spaces   \n')
  sources.read({ path = FIX .. '/library/writing/social/tweet.md' }, function(t) got = t end)
  eq(got, 'Write a tweet about [topic].')
  sources.read({ path = FIX .. '/library/invoice.md' }, function(t) got = t end)
  eq(got, 'Please write an invoice text for [client].\n')
  local err
  sources.read({ path = tmp .. '/gone.md' }, function(t, e) got, err = t, e end)
  eq({ got, err }, { nil, 'file not found' })
end

T['missing folders give nothing and no error; symlinked folders are followed once'] = function()
  eq(scan({ command_dirs = { tmp .. '/nope' }, skill_dirs = { tmp .. '/nope2' }, library_dir = tmp .. '/nope3',
    saved_dir = tmp .. '/nope4', project_name = 'x', project_root = tmp .. '/nope5' }), {})
  vim.uv.fs_symlink(FIX .. '/commands', tmp .. '/cmds')
  vim.uv.fs_symlink(tmp .. '/skills-real', tmp .. '/skills')
  vim.fn.mkdir(tmp .. '/skills-real/one', 'p')
  write(tmp .. '/skills-real/one/SKILL.md', 'one\n')
  -- a loop inside the library
  vim.fn.mkdir(tmp .. '/lib/a', 'p')
  write(tmp .. '/lib/a/x.md', 'x')
  vim.uv.fs_symlink(tmp .. '/lib', tmp .. '/lib/a/loop')
  local e = scan({ command_dirs = { tmp .. '/cmds' }, skill_dirs = { tmp .. '/skills' }, library_dir = tmp .. '/lib' })
  eq(by(e, 'insert', '/git:sync') ~= nil, true)
  eq(by(e, 'insert', '/one') ~= nil, true)
  local n = 0
  for _, x in ipairs(e) do
    if x.kind == 'template' then n = n + 1 end
  end
  eq(n, 1)
end

T['hidden files and folders (.git) are skipped; names with spaces, umlauts and emoji list'] = function()
  write(tmp .. '/lib/.git/HEAD.md', 'no')
  write(tmp .. '/lib/.hidden.md', 'no')
  write(tmp .. '/lib/Grüße an alle 🎉.md', 'hi')
  local e = scan({ library_dir = tmp .. '/lib' })
  eq(#e, 1)
  eq(e[1].title, 'Grüße an alle 🎉')
end

T['500 library files in deep folders: the scan never blocks the UI longer than 16 ms'] = function()
  for i = 1, 500 do
    local dir = tmp .. '/lib/' .. ('g%d/h%d/i%d'):format(i % 7, i % 5, i % 3)
    write(dir .. ('/prompt-%03d.md'):format(i), ('---\nname: Prompt %d\ndescription: d\n---\n# H\n%s'):format(i, string.rep('text ', 200)))
  end
  local timer, last, worst = vim.uv.new_timer(), vim.uv.hrtime(), 0
  timer:start(1, 1, function()
    local now = vim.uv.hrtime()
    worst = math.max(worst, now - last)
    last = now
  end)
  local e = scan({ library_dir = tmp .. '/lib' })
  timer:stop()
  timer:close()
  eq(#e, 500)
  local ms = worst / 1e6
  if ms >= 16 then error(('longest tick %.1f ms'):format(ms)) end
  MiniTest.add_note(('500 files: longest tick %.2f ms'):format(ms))
end

return T
