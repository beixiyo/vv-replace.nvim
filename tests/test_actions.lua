-- source-window preview diff 的 Neovim 集成测试
-- 运行：nvim --headless --clean -l tests/test_actions.lua

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local vendors = vim.fs.dirname(repo)
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(vim.fs.joinpath(vendors, 'vv-utils.nvim'))

local Actions = require('vv-replace.actions')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(string.format('%s: expected %q, got %q', message, expected, actual))
  end
end

local namespace = vim.api.nvim_create_namespace('vv-replace-actions-test')
local preview_win = vim.api.nvim_get_current_win()
local first_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(first_buf, 0, -1, false, { 'alpha beta' })
vim.api.nvim_win_set_buf(preview_win, first_buf)

local ctx = {
  prev_win = preview_win,
  state = {
    preview_ns = namespace,
    result_marks = {
      [1] = {
        kind = 'match',
        filename = '/tmp/first.lua',
        lnum = 1,
        submatches = {
          {
            start = 0,
            ['end'] = 5,
            replacement = { text = 'omega' },
          },
        },
      },
    },
  },
}

Actions._apply_file_diff(ctx, '/tmp/first.lua', namespace)
local first_marks = vim.api.nvim_buf_get_extmarks(first_buf, namespace, 0, -1, { details = true })
assert_eq(#first_marks, 2, 'replacement preview should render removed and added marks')
assert_eq(first_marks[1][4].hl_group, 'VVReplaceMatchRemoved', 'matched text highlight')
assert_eq(first_marks[2][4].virt_text[1][1], 'omega', 'replacement inline text')

local second_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(second_buf, 0, -1, false, { 'gamma' })
vim.api.nvim_win_set_buf(preview_win, second_buf)
ctx.state.result_marks = {
  [1] = {
    kind = 'match',
    filename = '/tmp/second.lua',
    lnum = 1,
    submatches = {
      {
        start = 0,
        ['end'] = 5,
      },
    },
  },
}

Actions._apply_file_diff(ctx, '/tmp/second.lua', namespace)
local second_marks = vim.api.nvim_buf_get_extmarks(second_buf, namespace, 0, -1, { details = true })
assert_eq(#second_marks, 1, 'plain search preview should render one match mark')
assert_eq(second_marks[1][4].hl_group, 'VVReplaceMatch', 'plain match highlight')

Actions._clear_all_preview_diff(ctx)
assert_eq(
  #vim.api.nvim_buf_get_extmarks(first_buf, namespace, 0, -1, {}),
  0,
  'cleanup should clear the first preview buffer'
)
assert_eq(
  #vim.api.nvim_buf_get_extmarks(second_buf, namespace, 0, -1, {}),
  0,
  'cleanup should clear the current preview buffer'
)
assert_eq(vim.tbl_count(ctx.state.preview_bufs), 0, 'cleanup should reset tracked preview buffers')

print('PASS: vv-replace source preview lifecycle')
