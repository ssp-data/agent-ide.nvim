-- Review comments: the per-work-tree store (review.lua), the text sent to Claude
-- (review_text.lua) and the anchoring of comments on a render (ui/review_marks.lua), all
-- without a window. Synthetic roots in a temporary folder; the runner's temporary state dir.
local eq = MiniTest.expect.equality
local review = require('agent-ide.review')

local tmp, root, notes

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    tmp = vim.uv.fs_realpath(tmp)
    root = tmp .. '/repo'
    vim.fn.mkdir(root, 'p')
    vim.fn.delete(vim.fn.stdpath('state') .. '/agent-ide/reviews', 'rf')
    review._reset()
    notes = {}
    vim.notify = function(msg) notes[#notes + 1] = msg end
  end,
  post_case = function()
    review._reset()
    vim.fn.delete(tmp, 'rf')
  end,
} })

-- The store ---------------------------------------------------------------------------------------

T['kind_of: a known kind up to a colon, any case; else NOTE with the whole text'] = function()
  eq({ review.kind_of('BUG: swallows the error') }, { 'BUG', 'swallows the error' })
  eq({ review.kind_of('bug:   trailing  ') }, { 'BUG', 'trailing' })
  eq({ review.kind_of('Bug - no colon') }, { 'NOTE', 'Bug - no colon' })
  eq({ review.kind_of('nit: x', { { 'NIT', 'small' } }) }, { 'NIT', 'x' })
  eq({ review.kind_of('NOTE:') }, { 'NOTE', '' })
  eq({ review.kind_of('BUG: first line\nsecond') }, { 'BUG', 'first line\nsecond' })
end

T['add, list, update, remove, clear, count; ids grow; the file round-trips'] = function()
  local c = review.add(root, { kind = 'BUG', text = 'x', scope = { kind = 'head', hash = 'abc1234' }, path = 'a.lua',
    side = 'new', line = 3, code = 'local a' })
  eq({ c.id, c.at ~= nil }, { 1, true })
  review.add(root, { kind = 'NOTE', text = 'y', scope = { kind = 'commit', hash = 'deadbeef', short = 'deadbee', subject = 's' },
    path = 'b.lua' })
  eq(#review.list(root), 2)
  eq(review.count(root), 2)
  review._reset() -- read again from disk
  eq(review.list(root)[2].scope.subject, 's')
  eq(review.list(root)[1].code, 'local a')
  eq(review.update(root, 1, { text = 'z' }), true)
  eq(review.list(root)[1].text, 'z')
  eq(review.update(root, 9, { text = 'z' }), false)
  eq(review.remove(root, 2).text, 'y')
  eq(review.remove(root, 2), nil)
  review.clear(root, { 1 })
  eq(review.count(root), 0)
  eq(review.add(root, { kind = 'NOTE', text = 'n', scope = { kind = 'head' }, path = 'a' }).id, 3)
end

T['matches: kind and hash; head and branch see each other except old-side anchors'] = function()
  eq(review.matches({ scope = { kind = 'head' }, side = 'new' }, { kind = 'branch' }), true)
  eq(review.matches({ scope = { kind = 'head' }, side = 'old' }, { kind = 'branch' }), false)
  eq(review.matches({ scope = { kind = 'branch' } }, { kind = 'head' }), true) -- file-level
  eq(review.matches({ scope = { kind = 'commit', hash = 'a' } }, { kind = 'commit', hash = 'b' }), false)
  eq(review.matches({ scope = { kind = 'commit', hash = 'a' } }, { kind = 'commit', hash = 'a' }), true)
  eq(review.matches({ scope = { kind = 'commits' } }, { kind = 'commits' }), true)
  eq(review.matches({ scope = { kind = 'commits' } }, { kind = 'head' }), false)
  review.add(root, { kind = 'NOTE', text = 'a', scope = { kind = 'head' }, path = 'a', side = 'old', line = 1 })
  review.add(root, { kind = 'NOTE', text = 'b', scope = { kind = 'head' }, path = 'a', side = 'new', line = 1 })
  eq(#review.list(root, { kind = 'branch' }), 1)
  eq(#review.list(root, { kind = 'head' }), 2)
end

T['session is kept; a corrupt file reads as empty and notifies once'] = function()
  review.set_session(root, 'id-1')
  review._reset()
  eq(review.session(root), 'id-1')
  review.set_session(root, nil)
  eq(review.session(root), nil)
  vim.fn.writefile({ '{ not json' }, review.file(root))
  review._reset()
  eq(review.list(root), {})
  eq(review.count(root), 0)
  eq(#notes, 1)
  eq(notes[1]:find('starting empty', 1, true) ~= nil, true)
end

T['file: under state/agent-ide/reviews, named by folder and hash, mode 0600 in a 0700 folder'] = function()
  local path = review.file(root)
  local dir = vim.fn.stdpath('state') .. '/agent-ide/reviews'
  eq(vim.fs.dirname(path), dir)
  eq(vim.fs.basename(path), 'repo-' .. vim.fn.sha256(root):sub(1, 12) .. '.json')
  review.add(root, { kind = 'NOTE', text = 'a', scope = { kind = 'head' }, path = 'a' })
  eq(vim.uv.fs_stat(path).mode % 512, 384)
  eq(vim.uv.fs_stat(dir).mode % 512, 448)
  local data = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  eq({ data.version, data.root, #data.comments }, { 1, root, 1 })
end

T['refresh: another writer\'s change is seen by stamp'] = function()
  review.add(root, { kind = 'NOTE', text = 'a', scope = { kind = 'head' }, path = 'a' })
  local path = review.file(root)
  local data = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  data.comments[2] = { id = 2, kind = 'BUG', text = 'b', scope = { kind = 'head' }, path = 'b', at = 'x' }
  data.next_id = 3
  vim.fn.writefile({ vim.json.encode(data) }, path)
  vim.uv.fs_utime(path, os.time() + 5, os.time() + 5) -- a stamp that differs for sure
  eq(review.count(root), 2)
  eq(review.add(root, { kind = 'NOTE', text = 'c', scope = { kind = 'head' }, path = 'c' }).id, 3)
end

return T
