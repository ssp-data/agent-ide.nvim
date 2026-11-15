-- Review comments: the notes you put on lines of the full diff (`c`), kept per work tree until
-- they are sent to Claude, copied or deleted. Nothing goes into the repository or `.git`: the
-- file is stdpath('state')/agent-ide/reviews/<folder>-<hash of the root>.json, 0600 in a 0700
-- folder, written atomically. Several Neovims share it (read again by stamp, as names.lua).
--   { "version": 1, "root": "/abs/path", "session": "<id>" | null, "next_id": 4,
--     "comments": [ { "id": 1, "kind": "BUG", "text": "…", "at": "2026-11-15T08:10:05Z",
--       "scope": { "kind": "head", "hash": "7f0f916" },        -- or commit: hash, short, subject;
--       "path": "lua/x.lua", "side": "new", "line": 42, "code": "…" } ] }  -- branch, commits: base
-- `side` is `new` for `+` and context lines, `old` for `-` lines, absent with `line` for a
-- comment on a file as a whole; `code` is the line's text without its first character.
local jsonfile = require('agent-ide.util.jsonfile')

local M = {}

---The kinds a comment can have (`KIND: text`), with the description Claude is given.
M.DEFAULT_KINDS = {
  { 'NOTE', 'an observation' }, { 'ISSUE', 'a problem to fix' }, { 'BUG', 'wrong behaviour' },
  { 'DESIGN', 'structure or approach' }, { 'SUGGESTION', 'an improvement' }, { 'QUESTION', 'something to explain' },
}

local reviews = {} -- root -> { data = table, stamp = string }
local warned = {} -- path -> true, the unreadable files already notified

local function notify(msg, level) vim.notify('Agent-IDE: ' .. msg, level or vim.log.levels.WARN) end

local function dir() return vim.fn.stdpath('state') .. '/agent-ide/reviews' end

---The file of the review of work tree `root`.
---@param root string
---@return string
function M.file(root)
  return ('%s/%s-%s.json'):format(dir(), vim.fs.basename(root), vim.fn.sha256(root):sub(1, 12))
end

local function empty(root) return { version = 1, root = root, session = nil, next_id = 1, comments = {} } end

-- What the file holds, leniently: a comment needs a path and a scope with a kind.
local function take(root, data)
  local out = empty(root)
  if type(data) ~= 'table' then return out end
  if type(data.session) == 'string' and data.session ~= '' then out.session = data.session end
  local max = 0
  for _, c in ipairs(type(data.comments) == 'table' and data.comments or {}) do
    if type(c) == 'table' and type(c.path) == 'string' and type(c.scope) == 'table' and type(c.scope.kind) == 'string'
      and type(c.id) == 'number' then
      c.kind = type(c.kind) == 'string' and c.kind or 'NOTE'
      c.text = type(c.text) == 'string' and c.text or ''
      out.comments[#out.comments + 1] = c
      if c.id > max then max = c.id end
    end
  end
  out.next_id = math.max(type(data.next_id) == 'number' and data.next_id or 1, max + 1)
  return out
end

---Read the file of `root` (a missing one: no comments; an unreadable one: the same, noticed once).
---@param root string
function M.load(root)
  local path = M.file(root)
  local data, stamp = jsonfile.read(path)
  if data == nil and stamp ~= '' and not warned[path] then
    warned[path] = true
    notify('reviews file unreadable, starting empty: ' .. path)
  end
  if data ~= nil then warned[path] = nil end
  reviews[root] = { data = take(root, data), stamp = stamp }
end

---Read the file again when another Neovim changed it since (or it was never read).
---@param root string
---@return boolean changed
function M.refresh(root)
  local r = reviews[root]
  if r and jsonfile.stamp(M.file(root)) == r.stamp then return false end
  M.load(root)
  return true
end

local function data(root)
  M.refresh(root)
  return reviews[root].data
end

local function save(root)
  local d = reviews[root].data
  local stamp, err = jsonfile.write(M.file(root), d)
  if not stamp then
    notify('cannot save the review: ' .. tostring(err))
    return false
  end
  reviews[root].stamp = stamp
  return true
end

---Split `KIND: text`: the first word up to a colon is a kind when `kinds` (default
---`DEFAULT_KINDS`) lists it, in any case; else the whole text is a NOTE. The rest is trimmed.
---@param text string
---@param kinds? { [1]: string, [2]: string }[]
---@return string kind, string rest
function M.kind_of(text, kinds)
  local word, rest = text:match('^%s*(%w+)%s*:%s*(.*)$')
  if word then
    for _, k in ipairs(kinds or M.DEFAULT_KINDS) do
      if k[1]:upper() == word:upper() then return k[1], (rest:gsub('%s+$', '')) end
    end
  end
  return 'NOTE', (text:gsub('^%s+', ''):gsub('%s+$', ''))
end

---Whether comment `c` belongs in the full diff scope `scope` (`{ kind, hash? }`): the same kind
---and, for one commit, the same hash. The uncommitted lines show in the head and the branch
---scopes alike, so a comment made in one is seen in the other, unless it sits on an old-side
---line (those numbers differ between the merge-base and HEAD).
---@param c table
---@param scope { kind: string, hash?: string }
---@return boolean
function M.matches(c, scope)
  local k = c.scope.kind
  if k == scope.kind then
    return k ~= 'commit' or c.scope.hash == scope.hash
  end
  local pair = (k == 'head' and scope.kind == 'branch') or (k == 'branch' and scope.kind == 'head')
  return pair and c.side ~= 'old'
end

---The comments of `root` in creation order, those of `scope` only when given.
---@param root string
---@param scope? { kind: string, hash?: string }
---@return table[]
function M.list(root, scope)
  local out = {}
  for _, c in ipairs(data(root).comments) do
    if not scope or M.matches(c, scope) then out[#out + 1] = c end
  end
  return out
end

---Add a comment; its `id` and `at` are set here. Returns it (saved or not).
---@param root string
---@param c { kind: string, text: string, scope: table, path: string, side?: string, line?: integer, code?: string }
---@return table comment
function M.add(root, c)
  local d = data(root)
  c = vim.deepcopy(c)
  c.id, d.next_id = d.next_id, d.next_id + 1
  c.at = os.date('!%Y-%m-%dT%H:%M:%SZ')
  d.comments[#d.comments + 1] = c
  save(root)
  return c
end

---Change the text or kind of comment `id`; false when there is no such comment.
---@param root string
---@param id integer
---@param fields { kind?: string, text?: string }
---@return boolean
function M.update(root, id, fields)
  for _, c in ipairs(data(root).comments) do
    if c.id == id then
      if fields.kind then c.kind = fields.kind end
      if fields.text then c.text = fields.text end
      return save(root)
    end
  end
  return false
end

---Take comment `id` out; the comment, or nil when there is none.
---@param root string
---@param id integer
---@return table|nil
function M.remove(root, id)
  local list = data(root).comments
  for i, c in ipairs(list) do
    if c.id == id then
      table.remove(list, i)
      save(root)
      return c
    end
  end
  return nil
end

---Take the comments with these ids out (the ones sent or copied).
---@param root string
---@param ids integer[]
function M.clear(root, ids)
  local gone = {}
  for _, id in ipairs(ids) do gone[id] = true end
  local d = data(root)
  local keep = {}
  for _, c in ipairs(d.comments) do
    if not gone[c.id] then keep[#keep + 1] = c end
  end
  if #keep ~= #d.comments then
    d.comments = keep
    save(root)
  end
end

---How many comments are pending for `root`.
---@param root string
---@return integer
function M.count(root) return #data(root).comments end

---The session the review of `root` goes to (nil: not chosen yet).
---@param root string
---@return string|nil
function M.session(root) return data(root).session end

---@param root string
---@param id string|nil
function M.set_session(root, id)
  local d = data(root)
  d.session = id
  save(root)
end

---Test only: forget everything read (the files stay).
function M._reset() reviews, warned = {}, {} end

return M
