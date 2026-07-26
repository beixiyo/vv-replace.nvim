-- 面板关闭入口共享同一幂等清理链
-- 运行：nvim --headless --clean -l tests/test_buffer_lifecycle.lua

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local vendors = vim.fs.dirname(repo)
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(vim.fs.joinpath(vendors, 'vv-utils.nvim'))

local Buffer = require('vv-replace.buffer')
local Inputs = require('vv-replace.inputs')
local Replace = require('vv-replace')

Replace.setup({
  debounce_ms = 60000,
  history_persist = false,
})

local record_count = 0
local record_all = Inputs.record_all
Inputs.record_all = function(ctx)
  record_count = record_count + 1
  return record_all(ctx)
end

Replace.open()
local first = assert(Buffer.current)
Replace.close()

assert(Buffer.current == nil, 'explicit close must release the active context')
assert(not vim.api.nvim_buf_is_valid(first.buf), 'explicit close must wipe the panel buffer')
assert(record_count == 1, 'explicit close plus BufWipeout must finalize exactly once')

Replace.open()
local second = assert(Buffer.current)
vim.api.nvim_win_close(second.win, true)

assert(Buffer.current == nil, 'external window close must release the active context')
assert(not vim.api.nvim_buf_is_valid(second.buf), 'external window close must wipe the panel buffer')
assert(record_count == 2, 'external close must finalize exactly once')

Inputs.record_all = record_all
print('PASS: vv-replace buffer lifecycle finalizes once per panel')
