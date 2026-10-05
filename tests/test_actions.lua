-- source-window preview 的真实 extmark 渲染与跨 buffer 清理
local T, child = dofile('tests/helpers.lua').new_set()
local expect = require('mini.test').expect

T['源代码预览在两个缓冲区渲染并清除全部已登记的 extmark'] = function()
  child.lua([[
    Actions = require('vv-replace.actions')
    namespace = vim.api.nvim_create_namespace('vv-replace-actions-test')
    preview_win = vim.api.nvim_get_current_win()
    first_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(first_buf, 0, -1, false, { 'alpha beta' })
    vim.api.nvim_win_set_buf(preview_win, first_buf)
    ctx = {
      prev_win = preview_win,
      state = {
        preview_ns = namespace,
        result_matches = {
          { kind = 'match', filename = '/tmp/first.lua', lnum = 1,
            submatches = { { start = 0, ['end'] = 5, replacement = { text = 'omega' } } } },
        },
      },
    }
    Actions._apply_file_diff(ctx, '/tmp/first.lua', namespace)
  ]])
  local marks = child.lua_get('vim.api.nvim_buf_get_extmarks(first_buf, namespace, 0, -1, { details = true })')
  expect.equality(#marks, 2)
  expect.equality(marks[1][4].hl_group, 'VVReplaceMatchRemoved')
  expect.equality(marks[2][4].virt_text[1][1], 'omega')

  child.lua([[
    second_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(second_buf, 0, -1, false, { 'gamma' })
    vim.api.nvim_win_set_buf(preview_win, second_buf)
    ctx.state.result_matches = {
      { kind = 'match', filename = '/tmp/second.lua', lnum = 1,
        submatches = { { start = 0, ['end'] = 5 } } },
    }
    Actions._apply_file_diff(ctx, '/tmp/second.lua', namespace)
  ]])
  marks = child.lua_get('vim.api.nvim_buf_get_extmarks(second_buf, namespace, 0, -1, { details = true })')
  expect.equality(#marks, 1)
  expect.equality(marks[1][4].hl_group, 'VVReplaceMatch')

  child.lua('Actions._clear_all_preview_diff(ctx)')
  expect.equality(child.lua_get('#vim.api.nvim_buf_get_extmarks(first_buf, namespace, 0, -1, {})'), 0)
  expect.equality(child.lua_get('#vim.api.nvim_buf_get_extmarks(second_buf, namespace, 0, -1, {})'), 0)
  expect.equality(child.lua_get('vim.tbl_count(ctx.state.preview_bufs)'), 0)
end

return T
