-- Drawer row keys on prompts: rename, delete, yank, copy a saved prompt into the library.
-- Claude's commands and skills are read-only here: these keys only say so.
local cache = require('agent-ide.prompts.cache')
local sources = require('agent-ide.prompts.sources')
local store = require('agent-ide.prompts.store')

local M = {}

local function notify(msg, level) vim.notify('Agent-IDE: ' .. msg, level or vim.log.levels.INFO) end

local function short(e) return require('agent-ide.prompts.save').short(e.kind, e.path) end

-- True (after a notice) for Claude's own files.
local function claude_owned(e)
  if e.kind ~= 'command' and e.kind ~= 'skill' then return false end
  notify(e.insert .. " belongs to Claude's folders; it is read-only here")
  return true
end

-- Name of an entry as `r` shows it: library `group/name`, saved `name`.
local function current_name(e)
  if e.kind == 'template' then
    local lib = cache.dirs().library
    local rel = vim.startswith(e.path, lib .. '/') and e.path:sub(#lib + 2) or vim.fs.basename(e.path)
    return (rel:gsub('%.md$', ''))
  end
  return (vim.fs.basename(e.path):gsub('%.md$', ''))
end

---@param e table PromptEntry
function M.rename(e)
  if claude_owned(e) then return end
  vim.ui.input({ prompt = 'Rename to: ', default = current_name(e) }, function(typed)
    if not typed or vim.trim(typed) == '' then return end
    store.rename(e, typed, function(path, err)
      if not path then
        if err == 'exists' then
          local rel = store.clean_name(typed, e.kind == 'saved')
          local dir = e.kind == 'template' and cache.dirs().library or vim.fs.dirname(e.path)
          err = short({ kind = e.kind, path = dir .. '/' .. rel .. '.md' }) .. ' already exists'
        end
        return notify('cannot rename: ' .. err, vim.log.levels.WARN)
      end
      notify('renamed → ' .. short({ kind = e.kind, path = path }))
      cache.invalidate()
    end)
  end)
end

---@param e table PromptEntry
function M.delete(e)
  if claude_owned(e) then return end
  local name = short(e)
  if vim.fn.confirm('Delete ' .. name .. '?', '&Yes\n&No', 2) ~= 1 then return end
  store.delete(e, function(ok, err)
    if not ok then return notify('cannot delete: ' .. tostring(err), vim.log.levels.WARN) end
    notify('deleted ' .. name)
    cache.invalidate()
  end)
end

---@param e table PromptEntry
function M.yank(e)
  if claude_owned(e) then return end
  sources.read(e, function(text, err)
    if not text then
      cache.invalidate()
      return notify(('cannot yank %s: %s'):format(e.title, err), vim.log.levels.WARN)
    end
    vim.fn.setreg('"', text)
    pcall(vim.fn.setreg, '+', text) -- no clipboard provider: the unnamed register only
    notify('yanked ' .. e.title)
  end)
end

---Copy a saved prompt into the library under a name (asked as for `<leader>W`).
---@param e table PromptEntry
function M.to_library(e)
  if claude_owned(e) then return end
  if e.kind ~= 'saved' then return notify('this prompt is in the library already') end
  sources.read(e, function(text, err)
    if not text then
      cache.invalidate()
      return notify(('cannot copy %s: %s'):format(e.title, err), vim.log.levels.WARN)
    end
    local lib = cache.dirs().library
    local function ask(default)
      vim.ui.input({ prompt = 'Save to library as: ', default = default }, function(typed)
        if not typed or vim.trim(typed) == '' then return end
        local rel, why = store.clean_name(typed)
        if not rel then
          notify('name not allowed: ' .. why, vim.log.levels.WARN)
          return ask(typed)
        end
        local path = lib .. '/' .. rel .. '.md'
        local ok, werr = store.write_new(path, text)
        if ok then
          notify(require('agent-ide.prompts.save').notice('saved', 'template', path))
          return cache.invalidate()
        end
        if werr ~= 'exists' then return notify('could not save: ' .. tostring(werr), vim.log.levels.WARN) end
        notify(short({ kind = 'template', path = path }) .. ' already exists; pick another name', vim.log.levels.WARN)
        local dir = vim.fs.dirname(rel)
        local free = store.free_name(vim.fs.dirname(path), vim.fs.basename(rel))
        ask(dir ~= '.' and (dir .. '/' .. free) or free)
      end)
    end
    ask(current_name(e))
  end)
end

return M
