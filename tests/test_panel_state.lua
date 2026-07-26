-- 面板宽度持久化的真实窗口生命周期测试
--
-- 运行：nvim --headless --clean -l tests/test_panel_state.lua

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local vendors = vim.fs.dirname(repo)
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(vim.fs.joinpath(vendors, 'vv-utils.nvim'))

local State = require('vv-utils.state')
local Replace = require('vv-replace')
local Buffer = require('vv-replace.buffer')
local PanelState = require('vv-replace.panel_state')

local function stored(value)
  return {
    get = function() return value end,
  }
end

for _, value in ipairs({ 0, -1, 1.5, '41', {}, math.huge }) do
  assert(PanelState.load_width(stored(value), 29) == 29, 'invalid persisted width must use fallback')
end
assert(PanelState.load_width(stored(nil), 29) == 29, 'missing persisted width must use fallback')
assert(PanelState.load_width(stored(1), 29) == 1, 'minimum positive integer width must be accepted')
assert(PanelState.load_width(stored(41), 29) == 41, 'positive integer width must be accepted')

if vim.env.VV_REPLACE_PANEL_STATE_MODE == 'read' then
  local path = assert(vim.env.VV_REPLACE_PANEL_STATE_PATH)
  local expected = assert(tonumber(vim.env.VV_REPLACE_PANEL_STATE_WIDTH))
  local state = State.register('vv-replace', 'panel', { path = path })

  Replace.setup({
    width = 29,
    debounce_ms = 60000,
    history_persist = false,
    state = state,
  })
  Replace.open()

  local ctx = assert(Buffer.current)
  assert(vim.api.nvim_win_get_width(ctx.win) == expected, 'new Neovim process must restore persisted width')
  Replace.close()
  print('PASS: vv-replace panel width restored in new Neovim process')
  return
end

local root = vim.fs.joinpath('/tmp', 'vv-replace-panel-state-' .. vim.uv.os_getpid())
local path = vim.fs.joinpath(root, 'state.json')
vim.fn.delete(root, 'rf')

local state = State.register('vv-replace', 'panel', { path = path })
assert(state:set('width', 'invalid'))

local function resize(width)
  vim.cmd('vertical resize ' .. width)
  -- headless 没有 UI redraw 循环，不会自动派发 WinResized
  vim.api.nvim_exec_autocmds('WinResized', {})
end

Replace.setup({
  width = 29,
  width_save_debounce_ms = 20,
  debounce_ms = 60000,
  history_persist = false,
  state = state,
})

Replace.open()
local ctx = assert(Buffer.current)
assert(vim.api.nvim_win_get_width(ctx.win) == 29, 'invalid persisted width must use configured width')

resize(41)
local resized_width = vim.api.nvim_win_get_width(ctx.win)
assert(vim.wait(200, function()
  return state:get('width') == resized_width
end), 'WinResized must debounce-save the actual panel width')

Replace.close()
assert(state:get('width') == resized_width, 'close must synchronously save the final width')

Replace.open()
ctx = assert(Buffer.current)
assert(vim.api.nvim_win_get_width(ctx.win) == resized_width, 'reopen must use the tracked width')

resize(43)
local externally_closed_width = vim.api.nvim_win_get_width(ctx.win)
vim.cmd('quit')
assert(Buffer.current == nil, 'external WinClosed must release the active context')
assert(state:get('width') == externally_closed_width, 'external WinClosed must save the final width')

Replace.open()
ctx = assert(Buffer.current)
resize(45)
local exit_width = vim.api.nvim_win_get_width(ctx.win)
vim.api.nvim_exec_autocmds('VimLeavePre', {})
vim.api.nvim_exec_autocmds('VimLeavePre', {})
assert(state:get('width') == exit_width, 'VimLeavePre must synchronously save the final width')

local reloaded = State.register('vv-replace', 'panel', { path = path })
assert(reloaded:get('width') == exit_width, 'a new state handle must read the persisted width')

local process = vim.system({
  vim.v.progpath,
  '--headless',
  '--clean',
  '-l',
  vim.fs.joinpath(repo, 'tests', 'test_panel_state.lua'),
}, {
  env = {
    VV_REPLACE_PANEL_STATE_MODE = 'read',
    VV_REPLACE_PANEL_STATE_PATH = path,
    VV_REPLACE_PANEL_STATE_WIDTH = tostring(exit_width),
  },
  text = true,
}):wait()
assert(process.code == 0, 'cross-process restore failed: ' .. process.stderr)

Replace.close()
vim.fn.delete(root, 'rf')
print('PASS: vv-replace panel width persistence')
