-- Icon sets and the `icons_style` option.
local icons = require('agent-ide.ui.icons')
local config = require('agent-ide.config')
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({ hooks = { post_case = function() config.setup() end } })

T['the nerd set defines every key of the plain set; no value is empty or wider than 2 cells'] = function()
  for k in pairs(icons.plain) do
    local v = icons.nerd[k]
    eq({ k, type(v) }, { k, 'string' })
    eq({ k, v ~= '' }, { k, true })
    eq({ k, vim.fn.strdisplaywidth(v) <= 2 }, { k, true })
    eq({ k, vim.fn.strchars(v) }, { k, 1 })
  end
  for k in pairs(icons.nerd) do eq({ k, icons.plain[k] ~= nil }, { k, true }) end
end

T['the plain set uses no private-use (nerd font) characters'] = function()
  for k, v in pairs(icons.plain) do
    for _, cp in ipairs(vim.tbl_map(function(c) return vim.fn.char2nr(c) end, vim.fn.split(v, '\\zs'))) do
      eq({ k, (cp >= 0xE000 and cp <= 0xF8FF) or cp >= 0xF0000 }, { k, false })
    end
  end
end

T['nerd glyphs are the code points named in the comments'] = function()
  eq(vim.fn.char2nr(icons.nerd.agents), 0xF06A9)
  eq(vim.fn.char2nr(icons.nerd.project), 0xF401)
  eq(vim.fn.char2nr(icons.nerd.failed), 0xF0159)
end

T['icons_style: nerd by default, plain on request; icons override single entries'] = function()
  eq(config.setup().icons_style, 'nerd')
  eq(config.get().icons.project, icons.nerd.project)
  eq(config.setup({ icons_style = 'plain' }).icons, icons.plain)
  local c = config.setup({ icons = { busy = 'B' } })
  eq({ c.icons.busy, c.icons.idle }, { 'B', icons.nerd.idle })
  c = config.setup({ icons_style = 'plain', icons = { project = 'P' } })
  eq({ c.icons.project, c.icons.open }, { 'P', '▾' })
end

T['prefix: icon and a space, nothing for an empty icon'] = function()
  eq({ icons.prefix('x'), icons.prefix(''), icons.prefix(nil) }, { 'x ', '', '' })
end

return T
