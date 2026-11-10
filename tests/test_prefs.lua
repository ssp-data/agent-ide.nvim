-- prefs.lua: the model last used and the legend toggle, kept in prefs.json.
local eq = MiniTest.expect.equality
local prefs = require('agent-ide.prefs')
local jsonfile = require('agent-ide.util.jsonfile')
local config = require('agent-ide.config')

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    vim.fn.delete(prefs._file())
    prefs._reset()
    config.setup({})
  end,
  post_case = function()
    vim.fn.delete(prefs._file())
    prefs._reset()
  end,
} })

T['set writes prefs.json atomically (0600); get reads it back after a reset'] = function()
  eq(prefs.get('model'), nil)
  prefs.set('model', 'haiku')
  prefs.set('legend', false)
  local st = vim.uv.fs_stat(prefs._file())
  eq(st ~= nil, true)
  eq(bit.band(st.mode, 511), 384)
  eq(jsonfile.read(prefs._file()), { version = 1, model = 'haiku', legend = false })
  prefs._reset()
  eq({ prefs.get('model'), prefs.get('legend') }, { 'haiku', false })
  -- nil forgets; a wrong type or an empty string is ignored
  prefs.set('model', nil)
  prefs.set('legend', 'yes')
  prefs.set('model', '')
  eq({ prefs.get('model'), prefs.get('legend') }, { nil, false })
  eq(jsonfile.read(prefs._file()), { version = 1, legend = false })
end

T['a corrupt or missing file reads as nothing set'] = function()
  vim.fn.mkdir(vim.fs.dirname(prefs._file()), 'p')
  vim.fn.writefile({ '{ not json' }, prefs._file())
  prefs._reset()
  eq({ prefs.get('model'), prefs.get('legend') }, { nil, nil })
  vim.fn.writefile({ '{"version":1,"model":42,"legend":true}' }, prefs._file())
  prefs._reset()
  eq({ prefs.get('model'), prefs.get('legend') }, { nil, true })
end

T['start_model: asked for, picked, claude.model, last used, else nil'] = function()
  local s = {}
  eq(prefs.start_model(s), nil)
  prefs.set('model', 'haiku')
  eq(prefs.start_model(s), 'haiku')
  config.setup({ claude = { model = 'opus' } })
  eq(prefs.start_model(s), 'opus')
  eq(prefs.start_model({ model_chosen = 'sonnet' }), 'sonnet')
  eq(prefs.start_model({ model_chosen = 'sonnet', model_requested = 'fable' }), 'fable')
  config.setup({})
end

return T
