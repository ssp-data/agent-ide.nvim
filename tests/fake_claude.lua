-- Scriptable fake Claude. Run: nvim -l tests/fake_claude.lua <scenario.jsonl> [more args...]
-- (Use tests/fake.lua: fake.cmd(lines) writes the scenario and returns the cmd for config.claude.cmd.)
-- Scenario: one JSON object per line, executed in order:
--   {"expect": "<substring>"}  block until an input line containing it arrives (earlier lines are kept)
--   {"emit": <object>}         write the object as one line, flushed
--   {"emit_raw": "<text>"}     write the text exactly (no newline added), flushed; for chunking/garbage
--   {"sleep_ms": n}  {"exit": code}  {"ignore_stdin": true} (stop reading, sleep until killed)
-- After the last step it keeps reading stdin until EOF, then exits 0.
-- Env FAKE_CLAUDE_LOG=<file>: appends {"argv":[...],"cwd":"...","api_key_set":bool} first, then
--   {"in":"<exact input line>"} per line received. `--version` anywhere in argv prints $FAKE_CLAUDE_VERSION
--   (default "2.1.306 (Claude Code)") and exits 0. Logged argv starts with the scenario path.
local args = {}
for i = 1, #arg do args[i] = arg[i] end

if vim.tbl_contains(args, '--version') then
  io.stdout:write((os.getenv('FAKE_CLAUDE_VERSION') or '2.1.306 (Claude Code)') .. '\n')
  io.stdout:flush()
  os.exit(0)
end

local log = os.getenv('FAKE_CLAUDE_LOG')
local function log_line(obj)
  if not log or log == '' then return end
  local f = io.open(log, 'a')
  if f then f:write(vim.json.encode(obj), '\n'); f:close() end
end
log_line({
  argv = args,
  cwd = vim.uv.cwd(),
  api_key_set = os.getenv('ANTHROPIC_API_KEY') ~= nil,
})

local steps = {}
for line in io.lines(args[1]) do
  if line:find('%S') then steps[#steps + 1] = vim.json.decode(line) end
end

local pending = {} -- input lines not yet consumed by an expect
local eof = false
local function read_line()
  local l = io.stdin:read('*l')
  if l == nil then eof = true; return nil end
  log_line({ ['in'] = l })
  return l
end

for _, step in ipairs(steps) do
  if step.expect then
    local found
    while not found do
      for i, l in ipairs(pending) do
        if l:find(step.expect, 1, true) then found = i; break end
      end
      if found then
        table.remove(pending, found)
      else
        local l = read_line()
        if l == nil then break end
        pending[#pending + 1] = l
      end
    end
    if not found then os.exit(0) end
  elseif step.emit ~= nil then
    io.stdout:write(vim.json.encode(step.emit), '\n'); io.stdout:flush()
  elseif step.emit_raw ~= nil then
    io.stdout:write(step.emit_raw); io.stdout:flush()
  elseif step.sleep_ms then
    vim.uv.sleep(step.sleep_ms)
  elseif step.exit ~= nil then
    os.exit(step.exit)
  elseif step.ignore_stdin then
    vim.wait(math.huge, function() return false end, 50)
  end
end

while not eof do read_line() end
os.exit(0)
