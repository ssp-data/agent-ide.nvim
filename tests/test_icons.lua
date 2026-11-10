-- Icon sets and the `icons_style` option.
local icons = require('agent-ide.ui.icons')
local config = require('agent-ide.config')
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({ hooks = { post_case = function() config.setup() end } })

local function private_use(s)
  for _, c in ipairs(vim.fn.split(s, '\\zs')) do
    local cp = vim.fn.char2nr(c)
    if (cp >= 0xE000 and cp <= 0xF8FF) or cp >= 0xF0000 then return true end
  end
  return false
end

T['both sets have the same keys; no value is wider than 2 cells'] = function()
  for k, v in pairs(icons.plain) do
    eq({ k, type(icons.nerd[k]) }, { k, 'string' })
    eq({ k, vim.fn.strdisplaywidth(icons.nerd[k]) <= 2 }, { k, true })
    eq({ k, vim.fn.strdisplaywidth(v) <= 2 }, { k, true })
  end
  for k in pairs(icons.nerd) do eq({ k, icons.plain[k] ~= nil }, { k, true }) end
end

T['the nerd set differs from the plain set in the pencil and the one git glyph only'] = function()
  local diff = {}
  for k, v in pairs(icons.nerd) do
    if v ~= icons.plain[k] then diff[#diff + 1] = k end
  end
  table.sort(diff)
  eq(diff, { 'changes', 'commits', 'prompts' })
  eq(icons.nerd.changes, icons.nerd.commits)
  eq(vim.fn.strchars(icons.nerd.changes), 1)
  eq({ icons.plain.prompts, icons.plain.changes, icons.plain.commits }, { '', '', '' })
  eq(private_use(icons.nerd.prompts) and private_use(icons.nerd.changes), true)
end

T['the plain set uses no private-use (nerd font) characters'] = function()
  for k, v in pairs(icons.plain) do eq({ k, private_use(v) }, { k, false }) end
end

T['nerd glyphs are the code points named in the comments'] = function()
  eq(vim.fn.char2nr(icons.nerd.prompts), 0xF0CB6) -- nf-md-pencil_outline
  eq(vim.fn.char2nr(icons.nerd.changes), 0xF47F) -- nf-oct-git_compare
end

T['states: the six marks of the mock; idle and parked differ; no sleep icon'] = function()
  for _, set in ipairs({ icons.nerd, icons.plain }) do
    eq({ set.waiting, set.busy, set.idle, set.parked, set.done, set.failed }, { '●', '◐', '●', '○', '✓', '✗' })
    eq(set.idle ~= set.parked, true)
    eq({ set.open, set.closed }, { '▾', '▸' })
  end
  for _, k in ipairs({ 'agents', 'project', 'sessions', 'saved_prompts', 'skills', 'library', 'group', 'command', 'skill',
    'template', 'saved', 'new' }) do
    eq({ k, icons.nerd[k] }, { k, nil })
  end
end

T['icons_style: nerd by default, plain on request; icons override single entries'] = function()
  eq(config.setup().icons_style, 'nerd')
  eq(config.get().icons.prompts, icons.nerd.prompts)
  eq(config.setup({ icons_style = 'plain' }).icons, icons.plain)
  local c = config.setup({ icons = { busy = 'B' } })
  eq({ c.icons.busy, c.icons.idle }, { 'B', icons.nerd.idle })
  c = config.setup({ icons_style = 'plain', icons = { prompts = 'P' } })
  eq({ c.icons.prompts, c.icons.open }, { 'P', '▾' })
end

T['prefix: icon and a space, nothing for an empty icon'] = function()
  eq({ icons.prefix('x'), icons.prefix(''), icons.prefix(nil) }, { 'x ', '', '' })
end

return T
