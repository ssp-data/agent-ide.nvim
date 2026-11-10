-- The prompts provider of the drawer sections hook: a top-level `Prompts` node (Skills &
-- commands, Library with its folders as groups) and, per expanded project with saved prompts,
-- a `Saved prompts (n)` section. Entries load on first expansion (see prompts/cache.lua).
local cache = require('agent-ide.prompts.cache')
local config = require('agent-ide.config')
local prefix = require('agent-ide.ui.icons').prefix

local M = {}

local HL_DIM = 'AgentIdeAge'
local HL_SECTION = 'AgentIdeSection'

local function actions() return require('agent-ide.prompts.actions') end

local function key_list(v) return require('agent-ide.ui.diff_buf').keys(v) end

local function prompt_keys()
  local keys = config.get().keys
  return type(keys) == 'table' and type(keys.prompts) == 'table' and keys.prompts or {}
end

local ROW_KEYS = {
  { 'edit', 'prompt row: edit the file (Claude\'s own files open read-only)' },
  { 'rename', 'prompt row: rename (library: group/name moves it)' },
  { 'delete', 'prompt row: delete the file (asks first)' },
  { 'yank', 'prompt row: yank the prompt\'s text' },
  { 'to_library', 'saved prompt row: copy it into the library' },
}

---Keys of prompt rows for the drawer (see ui/sections.lua `keys`).
---@return { lhs: string, desc: string }[]
function M.keys()
  local out, k = {}, prompt_keys()
  for _, r in ipairs(ROW_KEYS) do
    for _, lhs in ipairs(key_list(k[r[1]])) do out[#out + 1] = { lhs = lhs, desc = r[2] } end
  end
  return out
end

-- lhs -> handler of every prompt row (rebuilt when the key config changes)
local handlers, handlers_for
local function row_handlers()
  local k = prompt_keys()
  if handlers_for == k then return handlers end
  handlers, handlers_for = {}, k
  for _, r in ipairs(ROW_KEYS) do
    local name = r[1]
    for _, lhs in ipairs(key_list(k[name])) do
      handlers[lhs] = function(node) actions().row_key(name, node) end
    end
  end
  return handlers
end

local function use(node) actions().use(node.entry, { project = node.project }) end

local function hint(indent, text)
  return { pieces = { { indent .. text, HL_DIM } }, node = { type = 'hint' } }
end

local function fold_row(pieces, id, key, default, project)
  local node = { type = 'prompt_section', id = id, project = project, fold = { key = key, default = default, focus = id } }
  return { pieces = pieces, node = node }
end

local function is_open(expanded, key, default)
  local v = expanded[key]
  if v == nil then return default end
  return v == true
end

local NO_RIGHT = {}
local PROJECT_TAG = { { 'project', HL_DIM } }

-- Display parts of an entry (cached per entry table and indent): the label, the description dimmed (cut to the drawer width, dropped when no room is left), and a
-- right-aligned `project` tag for a project's own command or skill.
local row_cache = setmetatable({}, { __mode = 'k' }) -- entry -> its display parts
local function entry_pieces(e, indent)
  local c = row_cache[e]
  if c and c.indent == indent then return c.pieces, c.right end
  local label = (e.insert or e.title):gsub('[\r\n]', ' ')
  local pieces = { { indent .. label } }
  if e.description then pieces[2] = { '  ' .. e.description:gsub('[\r\n\t]', ' '), HL_DIM, fit = 'drop' } end
  local right = e.scope == 'project' and PROJECT_TAG or NO_RIGHT
  row_cache[e] = { indent = indent, pieces = pieces, right = right }
  return pieces, right
end

local function entry_row(out, e, indent, ctx, parent, project)
  local pieces, right = entry_pieces(e, indent)
  out[#out + 1] = { pieces = pieces, right = right, node = { type = 'prompt', id = 'prompt:' .. e.path,
    entry = e, project = project, open = use, keys = row_handlers(),
    fold = { key = parent.key, default = parent.default, focus = parent.id } } }
end

-- Library rows: entries sorted by group then title; a group row per folder level.
local function library_rows(out, list, ctx, parent)
  local open_groups = { [''] = true } -- group path -> shown
  local made = {}
  local counts = {}
  for _, e in ipairs(list) do
    local g = e.group or ''
    while g ~= '' do
      counts[g] = (counts[g] or 0) + 1
      g = g:match('^(.*)/[^/]*$') or ''
    end
  end
  for _, e in ipairs(list) do
    local g = e.group or ''
    -- the group rows of every folder level not shown yet
    local path, depth = '', 0
    local fold = parent
    for part in g:gmatch('[^/]+') do
      local up = path
      path = path == '' and part or (path .. '/' .. part)
      local key = 'prompts/group/' .. path
      local id = 'prompts#group:' .. path
      if not made[path] then
        made[path] = true
        local shown_parent = open_groups[up]
        local open = shown_parent and is_open(ctx.expanded, key, false)
        open_groups[path] = open
        if shown_parent then
          local ind = '    ' .. string.rep('  ', depth)
          out[#out + 1] = fold_row({ { ind .. (open and ctx.icons.open or ctx.icons.closed) .. ' ' .. part .. '/', HL_SECTION },
            { ' (' .. counts[path] .. ')', HL_DIM } }, id, key, false)
        end
      end
      fold = { key = key, default = false, id = id }
      depth = depth + 1
    end
    if open_groups[g] then entry_row(out, e, '      ' .. string.rep('  ', depth), ctx, fold) end
  end
end

local function save_hint()
  local k = config.get().keys
  local lhs = type(k) == 'table' and type(k.chat) == 'table' and key_list(k.chat.save_library)[1]
  return lhs and ('no prompts yet — ' .. lhs .. ' in a prompt buffer saves one') or 'no prompts yet'
end

---Provider `top`: the Prompts node.
---@param ctx table
---@return table[]
function M.top(ctx)
  local open = is_open(ctx.expanded, 'prompts', false)
  cache.visible = { global = open, saved = {} } -- top() runs first on every render
  local icon = ctx.icons.prompts
  local out = { fold_row({ { (open and ctx.icons.open or ctx.icons.closed) .. ' ' .. prefix(icon) }, { 'Prompts', 'AgentIdeProject' } },
    'prompts', 'prompts', false) }
  if not open then return out end
  local all = cache.global()
  if not all then
    out[#out + 1] = hint('    ', 'loading…')
    return out
  end
  local cmds, lib = {}, {}
  for _, e in ipairs(all) do
    if e.insert then cmds[#cmds + 1] = e else lib[#lib + 1] = e end
  end
  if #all == 0 then
    out[#out + 1] = hint('    ', save_hint())
    return out
  end
  local function section(name, label, list, default)
    local key, id = 'prompts/' .. name, 'prompts#' .. name
    local o = is_open(ctx.expanded, key, default)
    out[#out + 1] = fold_row({ { '  ' .. (o and ctx.icons.open or ctx.icons.closed) .. ' ' .. label, HL_SECTION },
      { ' (' .. #list .. ')', HL_DIM } }, id, key, default)
    return o, { key = key, default = default, id = id }
  end
  local o, parent = section('skills', 'Skills & commands', cmds, false)
  if o then
    for _, e in ipairs(cmds) do entry_row(out, e, '      ', ctx, parent) end
  end
  o, parent = section('library', 'Library', lib, true)
  if o then
    if #lib == 0 then
      out[#out + 1] = hint('      ', save_hint():gsub('^no prompts yet', 'empty'))
    else
      library_rows(out, lib, ctx, parent)
    end
  end
  return out
end

---Provider `rows`: `Saved prompts (n)` of an expanded project that has saved prompts.
---@param project table
---@param ctx table
function M.rows(project, ctx)
  if not ctx.open then return nil end
  local list = cache.saved(project)
  if not list or #list == 0 then return nil end
  local key, id = project.key .. '/saved', project.key .. '#saved'
  local o = is_open(ctx.expanded, key, false)
  if o then cache.visible.saved[cache.folder(project)] = true end
  local out = { fold_row({ { '  ' .. (o and ctx.icons.open or ctx.icons.closed) .. ' ' .. 'Saved prompts', HL_SECTION },
    { ' (' .. #list .. ')', HL_DIM } }, id, key, false, project) }
  if o then
    local parent = { key = key, default = false, id = id }
    for _, e in ipairs(list) do entry_row(out, e, '      ', ctx, parent, project) end
  end
  return out
end

local function on_update()
  local d = package.loaded['agent-ide.ui.drawer']
  if d then d.refresh() end
end

function M.register()
  cache.on_update(on_update)
  require('agent-ide.ui.sections').register('prompts', { top = M.top, rows = M.rows, keys = M.keys,
    refresh = cache.invalidate, focus = cache.focus })
end

return M
