-- The client-side file methods an ACP agent may call (`fs/read_text_file`,
-- `fs/write_text_file`), answered asynchronously and only inside the session's working
-- directory tree unless the agent's `fs` setting says `'any'` (`false`: every call is refused).
-- The agent sees a JSON-RPC error for anything refused or failed.
local M = {}

local REFUSED = -32000

---Whether `path` may be touched under `scope` (`'cwd'`, `'any'`, `false`) for folder `cwd`:
---absolute, normalised, and (for `'cwd'`) `cwd` itself or below it.
---@param scope string|boolean
---@param cwd string|nil
---@param path any
---@return boolean ok, string|nil why
function M.allowed(scope, cwd, path)
  if scope == false or scope == nil then return false, 'file access is off for this agent (agents.<name>.fs)' end
  if type(path) ~= 'string' or path == '' then return false, 'no path' end
  if path:sub(1, 1) ~= '/' then return false, 'path is not absolute' end
  if scope == 'any' then return true end
  if type(cwd) ~= 'string' or cwd == '' then return false, 'the session has no working directory' end
  local p, root = vim.fs.normalize(path), vim.fs.normalize(cwd)
  -- the real location decides: a link out of the tree is outside it
  local rp = vim.uv.fs_realpath(p) or (vim.uv.fs_realpath(vim.fs.dirname(p)) or vim.fs.dirname(p)) .. '/' .. vim.fs.basename(p)
  local rr = vim.uv.fs_realpath(root) or root
  if rp == rr or vim.startswith(rp, rr .. '/') then return true end
  return false, 'outside the working directory (agents.<name>.fs = "any" allows it)'
end

local function fail(respond, msg) respond(nil, { code = REFUSED, message = msg }) end

---Read `path` whole, then `cb(err, text)`.
local function read_file(path, cb)
  vim.uv.fs_open(path, 'r', 438, function(err, fd)
    if err then return cb(err) end
    vim.uv.fs_fstat(fd, function(serr, st)
      if serr or not st then return vim.uv.fs_close(fd, function() cb(serr or 'stat failed') end) end
      vim.uv.fs_read(fd, st.size, 0, function(rerr, data)
        vim.uv.fs_close(fd, function() cb(rerr, data or '') end)
      end)
    end)
  end)
end

---Write `text` to `path` (truncating), then `cb(err)`.
local function write_file(path, text, cb)
  vim.uv.fs_open(path, 'w', 420, function(err, fd)
    if err then return cb(err) end
    local off = 0
    local function step()
      if off >= #text then return vim.uv.fs_close(fd, function() cb(nil) end) end
      vim.uv.fs_write(fd, text:sub(off + 1), off, function(werr, n)
        if werr then return vim.uv.fs_close(fd, function() cb(werr) end) end
        off = off + (n or 0)
        step()
      end)
    end
    step()
  end)
end

---`fs/read_text_file {path, line?, limit?}` -> `{content}`; `line` (1-based) and `limit` cut
---the lines returned, as the protocol defines them.
---@param scope string|boolean
---@param cwd string|nil
---@return fun(params: table, respond: fun(result?: table, err?: table))
function M.read_handler(scope, cwd)
  return function(params, respond)
    params = type(params) == 'table' and params or {}
    local ok, why = M.allowed(scope, cwd, params.path)
    if not ok then return fail(respond, 'read refused: ' .. why) end
    read_file(params.path, vim.schedule_wrap(function(err, text)
      if err then return fail(respond, 'cannot read: ' .. tostring(err)) end
      if type(params.line) == 'number' or type(params.limit) == 'number' then
        local lines = vim.split(text, '\n', { plain = true })
        local first = math.max(1, tonumber(params.line) or 1)
        local last = type(params.limit) == 'number' and math.min(#lines, first + params.limit - 1) or #lines
        text = table.concat(vim.list_slice(lines, first, last), '\n')
      end
      respond({ content = text })
    end))
  end
end

---`fs/write_text_file {path, content}` -> `{}`.
---@param scope string|boolean
---@param cwd string|nil
---@return fun(params: table, respond: fun(result?: table, err?: table))
function M.write_handler(scope, cwd)
  return function(params, respond)
    params = type(params) == 'table' and params or {}
    local ok, why = M.allowed(scope, cwd, params.path)
    if not ok then return fail(respond, 'write refused: ' .. why) end
    if type(params.content) ~= 'string' then return fail(respond, 'write refused: no content') end
    write_file(params.path, params.content, vim.schedule_wrap(function(err)
      if err then return fail(respond, 'cannot write: ' .. tostring(err)) end
      respond(vim.empty_dict())
    end))
  end
end

return M
