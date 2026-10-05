-- 面板关闭入口共享同一幂等清理链；父进程检查真实 child 状态
local T, child = dofile('tests/helpers.lua').new_set()
local expect = require('mini.test').expect

T['显式关闭与外部关闭对每个面板只执行一次最终清理'] = function()
  child.lua([[
    Buffer = require('vv-replace.buffer')
    Inputs = require('vv-replace.inputs')
    Replace = require('vv-replace')
    Replace.setup({ debounce_ms = 60000, history_persist = false })
    record_count = 0
    local record_all = Inputs.record_all
    Inputs.record_all = function(ctx)
      record_count = record_count + 1
      return record_all(ctx)
    end
    Replace.open()
    first = assert(Buffer.current)
    Replace.close()
  ]])
  expect.equality(child.lua_get('Buffer.current == nil'), true)
  expect.equality(child.lua_get('vim.api.nvim_buf_is_valid(first.buf)'), false)
  expect.equality(child.lua_get('record_count'), 1)

  child.lua([[
    Replace.open()
    second = assert(Buffer.current)
    vim.api.nvim_win_close(second.win, true)
  ]])
  expect.equality(child.lua_get('Buffer.current == nil'), true)
  expect.equality(child.lua_get('vim.api.nvim_buf_is_valid(second.buf)'), false)
  expect.equality(child.lua_get('record_count'), 2)
end

return T
