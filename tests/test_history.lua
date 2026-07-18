-- 输入历史的 Neovim 集成测试
--
-- 运行方式：nvim --headless --clean -l tests/test_history.lua

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local vendors = vim.fs.dirname(repo)
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(vim.fs.joinpath(vendors, 'vv-utils.nvim'))

local Inputs = require('vv-replace.inputs')
local Buffer = require('vv-replace.buffer')
local Replace = require('vv-replace')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(string.format('%s: expected %q, got %q', message, expected, actual))
  end
end

local function set_field(ctx, name, value)
  Inputs.goto_field(ctx, name)
  local row = vim.api.nvim_win_get_cursor(ctx.win)[1] - 1
  local line = vim.api.nvim_buf_get_lines(ctx.buf, row, row + 1, false)[1] or ''
  vim.api.nvim_buf_set_text(ctx.buf, row, 0, row, #line, { value })
  vim.api.nvim_win_set_cursor(ctx.win, { row + 1, #value })
end

local function press(key)
  local encoded = vim.api.nvim_replace_termcodes(key, true, false, true)
  vim.api.nvim_feedkeys(encoded, 'xt', false)
end

Replace.setup({ debounce_ms = 60000, history_persist = false })
Replace.open({ scope = 'project' })

local ctx = assert(Buffer.current)
set_field(ctx, 'search', 'first')
Inputs.record_current(ctx)
set_field(ctx, 'search', 'second')
Inputs.record_current(ctx)
Inputs.setup_history({ persist = false })
set_field(ctx, 'search', 'draft')

vim.cmd('startinsert!')
press('<Up>')
assert_eq(Inputs.get_value(ctx, 'search'), 'second', 'Up should recall latest value')
press('<Up>')
assert_eq(Inputs.get_value(ctx, 'search'), 'first', 'second Up should recall older value')
press('<Down>')
assert_eq(Inputs.get_value(ctx, 'search'), 'second', 'Down should recall newer value')
press('<Down>')
assert_eq(Inputs.get_value(ctx, 'search'), 'draft', 'final Down should restore draft')

vim.cmd('stopinsert')
vim.api.nvim_win_set_cursor(ctx.win, { Inputs.results_header_row(ctx) + 1, 0 })
press('<Up>')
assert_eq(vim.api.nvim_win_get_cursor(ctx.win)[1], Inputs.results_header_row(ctx), 'Up outside inputs should keep native movement')

set_field(ctx, 'replace', '$100')
Replace.close()
Replace.open({ scope = 'project' })

ctx = assert(Buffer.current)
set_field(ctx, 'replace', '')
assert(Inputs.navigate_history(ctx, -1))
assert_eq(Inputs.get_value(ctx, 'replace'), '$100', 'history should survive panel reopen')

Replace.close()
print('PASS: vv-replace input history integration')
