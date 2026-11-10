-- Extra drawer sections per project, from registered providers (git changes and commits,
-- later the Prompts node). `tree.build` stays pure: it calls `collect` for each project.
--
-- sections.register(name, provider): provider is `rows(project, ctx)` or a table
-- { rows = fn?, top = fn?, setup = fn?, refresh = fn?, focus = fn?, keys = fn? }.
--   top(ctx) -> rows|nil: rows above all projects (e.g. a Prompts node); ctx as below without
--     `open`. Nodes as for project rows (`id`, `fold`, `open`).
--   rows(project, ctx) -> rows|nil, suffix|nil
--     ctx    = { open = <project expanded>, expanded = <drawer expansion table>, icons, now,
--               width = <drawer window width> }
--     rows   = { { pieces = { { text, hl_group|nil }, ... }, node = Node }, ... } shown below the
--              project's Sessions section while the project is expanded
--     suffix = { { text, hl_group|nil }, ... } appended to the project's own row
--   Node: a table with `type`, `project`, a stable unique `id` (the cursor stays on it), and
--     optionally `fold = { key, default, focus }` (<CR>/za toggle `expanded[key]`, which starts
--     as `default`, then the cursor lands on node id `focus`) and `open = function(node)` (<CR>).
--   setup(): the Agents tab was created; refresh(): `R` in the drawer; focus(): the drawer
--   window was entered.
--   keys() -> { { lhs = string, desc = string }, ... }: extra drawer keys for the provider's rows.
--     The drawer maps each lhs (read when its buffer is made) and lists it in its help; on a row
--     whose node has `keys = { [lhs] = function(node) }` the key calls that function, on any
--     other row it does what it does natively (a count is kept).
local M = {}

local order, by_name = {}, {}
local broken = {}

local function norm(provider)
  if type(provider) == 'function' then return { rows = provider } end
  return provider
end

---@param name string
---@param provider function|table
function M.register(name, provider)
  if not by_name[name] then order[#order + 1] = name end
  by_name[name] = norm(provider)
  broken[name] = nil
end

local function report(name, err)
  if broken[name] then return end
  broken[name] = true
  vim.schedule(function()
    vim.notify('Agent-IDE: drawer section ' .. name .. ' failed: ' .. tostring(err), vim.log.levels.WARN)
  end)
end

---Rows and project-row suffix of every provider for `project`, in registration order.
---@param project table
---@param ctx table
---@return table[]|nil rows, table[]|nil suffix
function M.collect(project, ctx)
  local rows, suffix
  for _, name in ipairs(order) do
    local p = by_name[name]
    if p.rows then
      local ok, r, s = pcall(p.rows, project, ctx)
      if not ok then
        report(name, r)
      else
        if r and #r > 0 then rows = vim.list_extend(rows or {}, r) end
        if s and #s > 0 then suffix = vim.list_extend(suffix or {}, s) end
      end
    end
  end
  return rows, suffix
end

---Top-level rows of every provider (above the projects), in registration order.
---@param ctx table
---@return table[]
function M.collect_top(ctx)
  local rows = {}
  for _, name in ipairs(order) do
    local p = by_name[name]
    if p.top then
      local ok, r = pcall(p.top, ctx)
      if not ok then
        report(name, r)
      elseif r then
        vim.list_extend(rows, r)
      end
    end
  end
  return rows
end

local function each(field, ...)
  for _, name in ipairs(order) do
    local fn = by_name[name][field]
    if fn then
      local ok, err = pcall(fn, ...)
      if not ok then report(name, err) end
    end
  end
end

---Extra row keys of every provider, in registration order (the first one of an lhs wins).
---@return { lhs: string, desc: string }[]
function M.keys()
  local out, seen = {}, {}
  for _, name in ipairs(order) do
    local fn = by_name[name].keys
    if fn then
      local ok, list = pcall(fn)
      if not ok then
        report(name, list)
      else
        for _, k in ipairs(list or {}) do
          if type(k.lhs) == 'string' and k.lhs ~= '' and not seen[k.lhs] then
            seen[k.lhs] = true
            out[#out + 1] = { lhs = k.lhs, desc = k.desc or '' }
          end
        end
      end
    end
  end
  return out
end

function M.setup() each('setup') end

function M.refresh() each('refresh') end

function M.focus() each('focus') end

---Test only: forget every provider.
function M._reset() order, by_name, broken = {}, {}, {} end

return M
