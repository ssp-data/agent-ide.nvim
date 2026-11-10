-- Saving from the prompt buffer: :w / ZZ / :x / :wq per project, <leader>W to the library,
-- updating a loaded prompt, and the rules that never lose or overwrite a prompt silently.
-- A child Neovim with a chat on a fresh session (no Claude process is started).
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local FIX = vim.fn.fnamemodify('tests/fixtures/prompts', ':p'):gsub('/$', '')
local tmp, repo, lib, saved

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    tmp = vim.uv.fs_realpath(tmp)
    repo, lib, saved = tmp .. '/repo', tmp .. '/library', tmp .. '/saved'
    vim.fn.mkdir(repo, 'p')
    vim.fn.system({ 'cp', '-r', FIX .. '/library', lib })
  end,
  post_case = function()
    child.stop()
    vim.fn.system({ 'chmod', '-R', 'u+rwx', tmp })
    vim.fn.delete(tmp, 'rf')
  end,
  post_once = function() child.stop() end,
} })

local function wait_for(cond, what, ms)
  if not vim.wait(ms or 5000, cond, 20) then error('timed out waiting for ' .. what, 2) end
end

local function start(extra)
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local tmp, repo, extra = ...
    vim.env.TMUX = nil
    _G.notes = {}
    vim.notify = function(msg, level) table.insert(_G.notes, { msg = msg, level = level }) end
    _G.answers, _G.asked, _G.inputs, _G.typed = {}, {}, {}, {}
    vim.ui.select = function(items, opts, cb)
      table.insert(_G.asked, { items = items, prompt = opts.prompt })
      local a = table.remove(_G.answers, 1)
      cb(a and items[a] or nil, a)
    end
    vim.ui.input = function(opts, cb)
      table.insert(_G.inputs, { prompt = opts.prompt, default = opts.default })
      cb(table.remove(_G.typed, 1))
    end
    _G.confirms = 0
    vim.fn.confirm = function() _G.confirms = _G.confirms + 1; return 1 end
    local opts = vim.tbl_deep_extend('force', { projects_dir = tmp .. '/projects', helper = { enabled = false },
      live = { interval_ms = 100000, cmd = { 'echo', '[]' } }, claude = { cmd = { 'false' } },
      prompts = { command_dirs = {}, skill_dirs = {}, library_dir = tmp .. '/library', saved_dir = tmp .. '/saved' } }, extra or {})
    require('agent-ide').setup(opts)
    require('agent-ide').toggle()
    local s = require('agent-ide.session').open({ cwd = repo })
    require('agent-ide.ui.chat').open(s, { key = repo, name = 'repo', root = repo, is_git = false, missing = false, sessions = {} })
  ]], { tmp, repo, extra or {} })
end

local function pbuf() return child.lua_get('vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().prompt)') end
local function set_prompt(lines) child.lua('vim.api.nvim_buf_set_lines(..., 0, -1, false, select(2, ...))', { pbuf(), lines }) end
local function origin() return child.lua_get('vim.b[...].agent_ide_origin', { pbuf() }) end
local function folder() return saved .. '/' .. child.lua_get('require("agent-ide.prompts.cache").folder({ key = ... })', { repo }) end
local function last_note() local n = child.lua_get('_G.notes'); return n[#n] and n[#n].msg end
local function read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local t = f:read('a')
  f:close()
  return t
end
local function files(dir)
  local out = {}
  for name in vim.fs.dir(dir) do out[#out + 1] = name end
  table.sort(out)
  return out
end
local function in_prompt() child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.chat")._windows().prompt)') end
local function modified() return child.lua_get('vim.bo[...].modified', { pbuf() }) end

T[':w saves a fresh prompt under the project; a second :w updates the same file'] = function()
  start()
  in_prompt()
  set_prompt({ '# Fix: the Login!! bug', '\tdetails  ', '[attach] src/a.lua' })
  child.cmd('write')
  local path = folder() .. '/fix-the-login-bug.md'
  eq(read(path), '# Fix: the Login!! bug\n\tdetails  \n[attach] src/a.lua\n')
  eq(last_note(), 'Agent-IDE: saved → Saved prompts/repo/fix-the-login-bug')
  eq(origin().path, path)
  eq(origin().kind, 'saved')
  eq(modified(), false)
  set_prompt({ '# Fix: the Login!! bug', 'more' })
  child.cmd('write')
  eq(files(folder()), { 'fix-the-login-bug.md' })
  eq(read(path), '# Fix: the Login!! bug\nmore\n')
  eq(last_note(), 'Agent-IDE: saved → Saved prompts/repo/fix-the-login-bug')
  -- created 0600 in a folder created 0700
  eq(vim.uv.fs_stat(path).mode % 512, tonumber('600', 8))
  eq(vim.uv.fs_stat(folder()).mode % 512, tonumber('700', 8))
  eq(vim.uv.fs_stat(saved).mode % 512, tonumber('700', 8))
end

T['same first line, different text: two files; the same text again: no copy'] = function()
  start()
  in_prompt()
  set_prompt({ 'Review', 'one' })
  child.cmd('write')
  child.lua('require("agent-ide.ui.prompt").clear(...)', { pbuf() }) -- what a send does
  eq(origin(), vim.NIL)
  set_prompt({ 'Review', 'two' })
  child.cmd('write')
  eq(files(folder()), { 'review-2.md', 'review.md' })
  eq(read(folder() .. '/review-2.md'), 'Review\ntwo\n')
  child.lua('require("agent-ide.ui.prompt").clear(...)', { pbuf() })
  set_prompt({ 'Review', 'one' })
  child.cmd('write')
  eq(files(folder()), { 'review-2.md', 'review.md' })
  eq(last_note(), 'Agent-IDE: already saved → Saved prompts/repo/review')
  -- the buffer is not tied to that file: editing and saving again never changes it
  eq(origin(), vim.NIL)
  set_prompt({ 'Review', 'one, tweaked' })
  child.cmd('write')
  eq(read(folder() .. '/review.md'), 'Review\none\n')
  eq(read(folder() .. '/review-3.md'), 'Review\none, tweaked\n')
end

T['pasting a saved prompt, :w, edit, :w: the original is never overwritten'] = function()
  start()
  in_prompt()
  vim.fn.mkdir(folder(), 'p')
  vim.fn.writefile({ 'Same text' }, folder() .. '/same-text.md')
  set_prompt({ 'Same text' })
  child.cmd('write')
  eq(last_note(), 'Agent-IDE: already saved → Saved prompts/repo/same-text')
  set_prompt({ 'Same text', 'more' })
  child.cmd('write')
  eq(read(folder() .. '/same-text.md'), 'Same text\n')
  eq(read(folder() .. '/same-text-2.md'), 'Same text\nmore\n')
end

T['file names: attach lines skipped, umlauts kept, emoji dropped, 60 characters, a timestamp when empty'] = function()
  start()
  local slug = function(lines) return child.lua_get('require("agent-ide.prompts.store").slug(...)', { lines }) end
  eq(slug({ '', '[attach] a.lua', '  Grüße für Ümit 🎉!' }), 'grüße-für-ümit')
  eq(slug({ string.rep('word ', 30) }), string.rep('word-', 12):sub(1, 59))
  eq(slug({ '../../etc/passwd' }), 'etc-passwd')
  eq(slug({ '...' }):match('^prompt%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d$') ~= nil, true)
  eq(vim.fn.strchars(slug({ string.rep('ü', 100) })), 60)
end

T['an empty prompt: :w says so and writes nothing; ZZ just hides'] = function()
  start()
  in_prompt()
  set_prompt({ '', '  ', '' })
  child.cmd('write')
  eq(last_note(), 'Agent-IDE: nothing to save')
  eq(vim.uv.fs_stat(saved), nil)
  child.lua('_G.notes = {}')
  child.type_keys('ZZ')
  eq(child.lua_get('require("agent-ide.ui.chat")._windows().prompt'), vim.NIL)
  eq(child.lua_get('#_G.notes'), 0)
  eq(vim.uv.fs_stat(saved), nil)
end

T['ZZ, :x and :wq save and hide; :q only hides'] = function()
  start()
  local t = child.lua_get('require("agent-ide.ui.chat")._windows().transcript')
  local function again()
    child.lua('vim.api.nvim_set_current_win(...)', { t })
    child.type_keys('i', '<Esc>')
  end
  in_prompt()
  set_prompt({ 'by ZZ' })
  child.type_keys('ZZ')
  eq(child.lua_get('require("agent-ide.ui.chat")._windows().prompt'), vim.NIL)
  eq(read(folder() .. '/by-zz.md'), 'by ZZ\n')
  for _, cmd in ipairs({ 'x', 'wq', 'exit' }) do
    again()
    local b = pbuf()
    child.lua('require("agent-ide.ui.prompt").clear(...)', { b })
    set_prompt({ 'by ' .. cmd })
    child.type_keys(':' .. cmd .. '<CR>')
    eq(child.lua_get('require("agent-ide.ui.chat")._windows().prompt'), vim.NIL)
    eq(read(folder() .. '/by-' .. cmd .. '.md'), 'by ' .. cmd .. '\n')
    eq(child.lua_get('vim.bo[...].modified', { b }), false)
  end
  again()
  child.lua('require("agent-ide.ui.prompt").clear(...)', { pbuf() })
  set_prompt({ 'by q' })
  child.cmd('quit')
  eq(read(folder() .. '/by-q.md'), nil)
  again()
  eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), { 'by q' })
end

T['<leader>W saves to the library under a name (group/name makes folders); cancel does nothing'] = function()
  start()
  in_prompt()
  set_prompt({ 'My post about X', 'body' })
  child.lua('_G.typed = { "writing/my post" }')
  child.type_keys('\\W')
  local i = child.lua_get('_G.inputs')
  eq(i[1], { prompt = 'Save to library as: ', default = 'my-post-about-x' })
  eq(read(lib .. '/writing/my-post.md'), 'My post about X\nbody\n')
  eq(origin(), { kind = 'template', path = lib .. '/writing/my-post.md', stamp = origin().stamp })
  eq(last_note(), 'Agent-IDE: saved → Library/writing/my-post')
  -- :w now updates that library file
  set_prompt({ 'My post about X', 'body 2' })
  child.cmd('write')
  eq(read(lib .. '/writing/my-post.md'), 'My post about X\nbody 2\n')
  -- cancel
  child.lua('_G.typed = { nil }; _G.inputs = {}')
  child.type_keys('\\W')
  eq(#child.lua_get('_G.inputs'), 1)
  eq(files(lib .. '/writing'), { 'linkedin-post.md', 'my-post.md', 'social' })
  eq(vim.uv.fs_stat(lib .. '/writing/new-folder'), nil)
  eq(modified(), false)
end

T['<leader>W: bad names are refused and asked again; an existing name is never overwritten'] = function()
  start()
  in_prompt()
  set_prompt({ 'Text' })
  child.lua('_G.typed = { "../x", "/abs", "a/./b", "a//b", "bad*char", ".hidden", "invoice", "ok name" }')
  child.type_keys('\\W')
  local inputs = child.lua_get('_G.inputs')
  eq(#inputs, 8)
  eq(inputs[2].default, '../x') -- asked again with what was typed
  eq(inputs[8].default, 'invoice-2') -- the next free name
  local msgs = vim.tbl_map(function(n) return n.msg end, child.lua_get('_G.notes'))
  eq(vim.tbl_contains(msgs, 'Agent-IDE: name not allowed: ".." is not allowed'), true)
  eq(vim.tbl_contains(msgs, 'Agent-IDE: name not allowed: only letters, digits, space, - _ and . are allowed'), true)
  eq(vim.tbl_contains(msgs, 'Agent-IDE: Library/invoice already exists; pick another name'), true)
  eq(read(lib .. '/invoice.md'), '---\nname: Invoice text\ndescription: Short invoice text for a client\n---\nPlease write an invoice text for [client].\n')
  eq(read(lib .. '/ok-name.md'), 'Text\n')
  eq(vim.uv.fs_stat(tmp .. '/x.md'), nil)
end

local function load_invoice()
  child.lua([[require('agent-ide.prompts.actions').use({ kind = 'template', path = ..., title = 'Invoice text' })]], { lib .. '/invoice.md' })
  wait_for(function() return origin() ~= vim.NIL end, 'loaded')
end

T['a loaded template is updated in place: the file is the buffer text, nothing kept or added'] = function()
  start()
  load_invoice()
  in_prompt()
  set_prompt({ 'New invoice text', '' })
  child.cmd('write')
  eq(read(lib .. '/invoice.md'), 'New invoice text\n\n')
  eq(last_note(), 'Agent-IDE: saved → Library/invoice')
  eq(vim.uv.fs_stat(saved), nil)
end

T['changed on disk since it was loaded: overwrite, save as new, or cancel'] = function()
  for _, answer in ipairs({ 3, 1, 2 }) do
    vim.fn.delete(lib, 'rf')
    vim.fn.system({ 'cp', '-r', FIX .. '/library', lib })
    start()
    load_invoice()
    in_prompt()
    vim.uv.sleep(20)
    vim.fn.writefile({ '---', 'name: Changed', '---', 'changed elsewhere' }, lib .. '/invoice.md')
    set_prompt({ 'mine' })
    child.lua('_G.answers = { ... }', { answer })
    child.cmd('write')
    local a = child.lua_get('_G.asked')
    eq(#a, 1)
    eq(a[1].prompt, 'Library/invoice changed on disk since it was loaded. Overwrite, save as new, or cancel?')
    eq(a[1].items, { 'Overwrite', 'Save as new', 'Cancel' })
    if answer == 3 then
      eq(read(lib .. '/invoice.md'), '---\nname: Changed\n---\nchanged elsewhere\n')
      eq(vim.uv.fs_stat(lib .. '/invoice-2.md'), nil)
    elseif answer == 1 then
      eq(read(lib .. '/invoice.md'), 'mine\n')
      -- no question for the next :w: the file is as this buffer left it
      child.cmd('write')
      eq(#child.lua_get('_G.asked'), 1)
    else
      eq(read(lib .. '/invoice.md'), '---\nname: Changed\n---\nchanged elsewhere\n')
      eq(read(lib .. '/invoice-2.md'), 'mine\n')
      eq(origin().path, lib .. '/invoice-2.md')
    end
    child.stop()
  end
end

T['a loaded file deleted since: asked too; overwrite writes it again'] = function()
  start()
  load_invoice()
  in_prompt()
  vim.fn.delete(lib .. '/invoice.md')
  set_prompt({ 'back' })
  child.lua('_G.answers = { 1 }')
  child.cmd('write')
  eq(#child.lua_get('_G.asked'), 1)
  eq(read(lib .. '/invoice.md'), 'back\n')
end

T['a sent prompt forgets its origin; browsing history saves the shown prompt as new'] = function()
  start()
  load_invoice()
  in_prompt()
  child.lua('require("agent-ide.ui.prompt").clear(...)', { pbuf() }) -- a send
  eq(origin(), vim.NIL)
  load_invoice()
  child.lua([[
    local s = require('agent-ide.session').all()[1]
    s.events = { { kind = 'prompt', text = 'old prompt' } }
  ]])
  child.lua('vim.api.nvim_win_set_cursor(0, { 1, 0 })')
  child.type_keys('<C-p>')
  eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), { 'old prompt' })
  child.cmd('write')
  eq(read(folder() .. '/old-prompt.md'), 'old prompt\n')
  eq(read(lib .. '/invoice.md'):find('Please write', 1, true) ~= nil, true)
end

T['a folder that cannot be written: one warning, nothing raised, no partial file'] = function()
  start()
  in_prompt()
  vim.fn.mkdir(folder(), 'p')
  vim.fn.setfperm(folder(), 'r-x------')
  set_prompt({ 'cannot' })
  child.cmd('write')
  local n = child.lua_get('_G.notes')
  eq(#n, 1)
  eq(n[1].level, vim.log.levels.WARN)
  eq(n[1].msg:match('^Agent%-IDE: could not save') ~= nil, true)
  eq(files(folder()), {})
  eq(modified(), false)
end

T['nothing is ever written under a .claude folder'] = function()
  start({ prompts = { library_dir = tmp .. '/x/.claude/prompts' } })
  in_prompt()
  set_prompt({ 'Text' })
  child.lua('_G.typed = { "name" }')
  child.type_keys('\\W')
  eq(last_note(), 'Agent-IDE: could not save: refusing to write under a .claude folder')
  eq(vim.uv.fs_stat(tmp .. '/x'), nil)
end

T[':w <file> is refused; the prompt stays unmodified'] = function()
  start()
  in_prompt()
  set_prompt({ 'Text' })
  pcall(child.cmd, 'write ' .. tmp .. '/other.md')
  eq(vim.uv.fs_stat(tmp .. '/other.md'), nil)
  eq(last_note(), 'Agent-IDE: the prompt is saved with :w (no file name); see g? for the keys')
  eq(modified(), false)
end

T['store: a new file never replaces another (two Neovims saving the same name)'] = function()
  start()
  local res = child.lua_get([[(function(dir)
    local store = require('agent-ide.prompts.store')
    local a = { store.write_new(dir .. '/same.md', 'first\n') }
    local b = { store.write_new(dir .. '/same.md', 'second\n') }
    return { a, b }
  end)(...)]], { tmp .. '/race' })
  eq(res[1], { true })
  eq(res[2], { vim.NIL, 'exists' })
  eq(read(tmp .. '/race/same.md'), 'first\n')
  eq(files(tmp .. '/race'), { 'same.md' })
end

T[':qa with a draft quits without saving or asking'] = function()
  start()
  in_prompt()
  set_prompt({ 'draft' })
  pcall(child.type_keys, ':qa<CR>')
  wait_for(function() return not pcall(child.lua_get, '1') end, 'Neovim to exit', 3000)
  eq(vim.uv.fs_stat(saved), nil)
end

for _, cmd in ipairs({ 'wqa', 'xa' }) do
  T[':' .. cmd .. ' with a draft quits without saving or asking'] = function()
    start()
    in_prompt()
    set_prompt({ 'draft' })
    pcall(child.type_keys, ':' .. cmd .. '<CR>')
    wait_for(function() return not pcall(child.lua_get, '1') end, 'Neovim to exit', 3000)
    eq(vim.uv.fs_stat(saved), nil)
    eq(vim.uv.fs_stat(lib .. '/draft.md'), nil)
  end
end

-- Origin and history stay consistent whatever writes into the prompt ---------------------------

T['queued prompts put back (interrupt, park) make a loaded template a new prompt'] = function()
  start()
  load_invoice()
  in_prompt()
  child.lua('require("agent-ide.ui.prompt").restore(..., { "queued one" })', { pbuf() })
  eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'),
    { 'queued one', '', '---', 'name: Invoice text', 'description: Short invoice text for a client', '---', 'Please write an invoice text for [client].' })
  eq(origin(), vim.NIL)
  child.cmd('write')
  eq(read(lib .. '/invoice.md'):find('queued', 1, true), nil)
  eq(read(folder() .. '/queued-one.md') ~= nil, true)
end

T['restore while browsing the history puts the draft back first'] = function()
  start()
  in_prompt()
  set_prompt({ 'my draft' })
  child.lua('require("agent-ide.session").all()[1].events = { { kind = "prompt", text = "old prompt" } }')
  child.lua('vim.api.nvim_win_set_cursor(0, { 1, 0 })')
  child.type_keys('<C-p>')
  eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), { 'old prompt' })
  child.lua('require("agent-ide.ui.prompt").restore(..., { "queued" })', { pbuf() })
  eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), { 'queued', '', 'my draft' })
  eq(child.lua_get('require("agent-ide.ui.prompt").browsing(...)', { pbuf() }), false)
end

T['loading a template while the history is shown asks about the real draft and leaves the history'] = function()
  start()
  in_prompt()
  set_prompt({ 'my draft' })
  child.lua('require("agent-ide.session").all()[1].events = { { kind = "prompt", text = "old prompt" } }')
  child.lua('vim.api.nvim_win_set_cursor(0, { 1, 0 })')
  child.type_keys('<C-p>')
  child.lua('_G.answers = { 1 }')
  load_invoice()
  eq(#child.lua_get('_G.asked'), 1)
  eq(child.lua_get('require("agent-ide.ui.prompt").browsing(...)', { pbuf() }), false)
  set_prompt({ 'edited invoice' })
  child.lua('vim.api.nvim_win_set_cursor(0, { 1, 0 })')
  child.type_keys('<Down>') -- no history to step out of: the text stays
  eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), { 'edited invoice' })
  child.cmd('write')
  eq(read(lib .. '/invoice.md'):find('edited invoice', 1, true) ~= nil, true)
  -- a command inserted while the history is shown lands above the real draft
  child.lua('require("agent-ide.ui.prompt").clear(...)', { pbuf() })
  set_prompt({ 'draft two' })
  child.lua('vim.api.nvim_win_set_cursor(0, { 1, 0 })')
  child.type_keys('<C-p>')
  child.lua('require("agent-ide.prompts.actions").use({ kind = "command", insert = "/x", title = "/x", path = "/nonexistent" })')
  eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), { '/x ', 'draft two' })
end

T['a command inserted above a loaded template, or a reused search hit, makes it a new prompt'] = function()
  start()
  load_invoice()
  in_prompt()
  child.lua('require("agent-ide.prompts.actions").use({ kind = "command", insert = "/x", title = "/x", path = "/nonexistent" })')
  eq(origin(), vim.NIL)
  child.type_keys('<Esc>')
  child.lua('_G.answers = { 1 }') -- replace the draft
  load_invoice()
  child.lua('require("agent-ide.ui.search_open").reuse("from search")')
  eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'),
    { '---', 'name: Invoice text', 'description: Short invoice text for a client', '---', 'Please write an invoice text for [client].', '', 'from search' })
  eq(origin(), vim.NIL)
end

T['a saved prompt or library file that starts with a --- block is loaded whole and saved back byte for byte'] = function()
  start()
  vim.fn.mkdir(folder(), 'p')
  local cases = {
    { kind = 'saved', path = folder() .. '/rule.md', text = '---\nname: looks like yaml\n---\nbody\n' },
    { kind = 'template', path = lib .. '/rule-pair.md', text = '---\nhello there\n---\nbody\n' },
    { kind = 'template', path = lib .. '/mixed.md', text = '---\nnote: x\njust a sentence\n---\nbody\n' },
  }
  for _, c in ipairs(cases) do
    local f = assert(io.open(c.path, 'wb'))
    f:write(c.text)
    f:close()
    child.lua('_G.answers = { 1 }')
    child.lua('require("agent-ide.prompts.actions").use({ kind = ..., path = select(2, ...), title = "t" })', { c.kind, c.path })
    wait_for(function() return origin() ~= vim.NIL and origin().path == c.path end, 'loaded ' .. c.path)
    eq(child.lua_get('table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\\n") .. "\\n"'), c.text)
    child.cmd('write')
    eq(read(c.path), c.text)
  end
  -- a real name/description block: shown as title and description, but loaded and saved as is
  child.lua('_G.answers = { 1 }')
  load_invoice()
  eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), { '---', 'name: Invoice text', 'description: Short invoice text for a client', '---', 'Please write an invoice text for [client].' })
  child.cmd('write')
  eq(read(lib .. '/invoice.md'), '---\nname: Invoice text\ndescription: Short invoice text for a client\n---\nPlease write an invoice text for [client].\n')
  local e = child.lua_get([[(function(dir)
    local got
    require('agent-ide.prompts.sources').scan({ library_dir = dir }, function(x) got = x end)
    vim.wait(5000, function() return got ~= nil end, 5)
    for _, x in ipairs(got) do if x.path:find('invoice.md', 1, true) then return { x.title, x.description } end end
  end)(...)]], { lib })
  eq(e, { 'Invoice text', 'Short invoice text for a client' })
end

T['<leader>W with a leading --- block, then :w twice: the file is the buffer text, the block once'] = function()
  start()
  in_prompt()
  local text = { '---', '- do this', 'key: value', '---', 'body' }
  set_prompt(text)
  child.lua('_G.typed = { "blocky" }')
  child.type_keys('\\W')
  eq(read(lib .. '/blocky.md'), table.concat(text, '\n') .. '\n')
  text[5] = 'body edited'
  set_prompt(text)
  child.cmd('write')
  eq(read(lib .. '/blocky.md'), table.concat(text, '\n') .. '\n')
  child.cmd('write')
  eq(read(lib .. '/blocky.md'), table.concat(text, '\n') .. '\n')
  local _, n = read(lib .. '/blocky.md'):gsub('key: value', '')
  eq(n, 1)
  -- loading it again gives the same text
  child.lua('require("agent-ide.ui.prompt").clear(...)', { pbuf() })
  child.lua([[require('agent-ide.prompts.actions').use({ kind = 'template', path = ..., title = 'b' })]], { lib .. '/blocky.md' })
  wait_for(function() return origin() ~= vim.NIL end, 'loaded')
  eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), text)
end

T['changed on disk and the prompt is the last window: ZZ asks before Neovim exits'] = function()
  start()
  load_invoice()
  in_prompt()
  child.cmd('tabonly')
  child.cmd('only')
  eq(child.lua_get('#vim.api.nvim_list_wins()'), 1)
  vim.uv.sleep(20)
  vim.fn.writefile({ 'changed elsewhere' }, lib .. '/invoice.md')
  set_prompt({ 'mine' })
  child.lua([[local out = ...
  vim.fn.confirm = function(msg, choices)
    vim.fn.writefile({ msg, choices }, out)
    return 1
  end]], { tmp .. '/asked.txt' })
  pcall(child.type_keys, 'ZZ')
  wait_for(function() return not pcall(child.lua_get, '1') end, 'Neovim to exit', 3000)
  eq(vim.fn.readfile(tmp .. '/asked.txt'), { 'Library/invoice changed on disk since it was loaded. Overwrite, save as new, or cancel?',
    '&Overwrite\n&Save as new\n&Cancel' })
  eq(read(lib .. '/invoice.md'), 'mine\n')
end

local function async_select()
  child.lua([[vim.ui.select = function(items, opts, cb)
    _G.pending = { cb = cb, items = items, prompt_shown = require('agent-ide.ui.chat')._windows().prompt ~= nil }
  end]])
end

for _, how in ipairs({ 'ZZ', ':x' }) do
  T['changed on disk, ' .. how .. ' with an asynchronous picker: the question opens after the hide'] = function()
    start()
    load_invoice()
    in_prompt()
    vim.uv.sleep(20)
    vim.fn.writefile({ 'changed elsewhere' }, lib .. '/invoice.md')
    set_prompt({ 'mine' })
    async_select()
    child.type_keys(how == 'ZZ' and 'ZZ' or ':x<CR>')
    wait_for(function() return child.lua_get('_G.pending ~= nil') end, 'question')
    eq(child.lua_get('_G.pending.prompt_shown'), false)
    child.lua('_G.pending.cb("Overwrite", 1)')
    eq(read(lib .. '/invoice.md'), 'mine\n')
  end
end

T['a renamed file keeps the changed-on-disk check of the buffer loaded from it'] = function()
  start()
  load_invoice()
  in_prompt()
  vim.uv.sleep(20)
  vim.fn.writefile({ 'changed elsewhere' }, lib .. '/invoice.md')
  child.lua([[require('agent-ide.prompts.store').rename({ kind = 'template', path = ... }, 'renamed', function() end)]], { lib .. '/invoice.md' })
  eq(origin().path, lib .. '/renamed.md')
  set_prompt({ 'mine' })
  child.lua('_G.answers = { 3 }')
  child.cmd('write')
  eq(#child.lua_get('_G.asked'), 1)
  eq(read(lib .. '/renamed.md'), 'changed elsewhere\n')
end

T[':file and :saveas do not turn the prompt into a file buffer'] = function()
  start()
  in_prompt()
  set_prompt({ 'Text' })
  local name = child.lua_get('vim.api.nvim_buf_get_name(0)')
  pcall(child.cmd, 'file ' .. tmp .. '/renamed.md')
  eq(child.lua_get('vim.api.nvim_buf_get_name(0)'), name)
  eq(last_note(), 'Agent-IDE: the prompt buffer keeps its name; save it with :w')
  pcall(child.cmd, 'saveas ' .. tmp .. '/saved-as.md')
  eq(child.lua_get('vim.api.nvim_buf_get_name(0)'), name)
  eq(vim.uv.fs_stat(tmp .. '/saved-as.md'), nil)
  eq(vim.uv.fs_stat(tmp .. '/renamed.md'), nil)
  eq(child.lua_get('vim.bo.buftype'), 'acwrite')
  -- still saves normally
  child.cmd('write')
  eq(read(folder() .. '/text.md'), 'Text\n')
end

T['file names are limited by bytes'] = function()
  start()
  local res = child.lua_get('{ require("agent-ide.prompts.store").clean_name(...) }', { string.rep('ü', 121) })
  eq(res, { vim.NIL, 'a name part is longer than 240 bytes' })
  res = child.lua_get('{ require("agent-ide.prompts.store").clean_name(...) }', { string.rep('ü', 120) })
  eq(res, { string.rep('ü', 120) })
  eq(#child.lua_get('require("agent-ide.prompts.store").slug(...)', { { string.rep('ü', 200) } }) <= 240, true)
end

return T
