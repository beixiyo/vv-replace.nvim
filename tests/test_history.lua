-- 输入历史按键回溯历史值并在重开面板后保留草稿的隔离 Neovim 集成测试
local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T['输入历史按键回溯历史值并在重开后保留草稿'] = function()
  -- 同步 RPC 的错误交由父进程 mini.test 记录；异步回调只收集数据
  child.lua_func(function()
    local Inputs = require('vv-replace.inputs')
    local Buffer = require('vv-replace.buffer')
    local Replace = require('vv-replace')

    local assert_eq = Helpers.eq
    local function press(key) Helpers.press(key, 'xt') end

    local function set_field(ctx, name, value)
      Inputs.goto_field(ctx, name)
      local row = vim.api.nvim_win_get_cursor(ctx.win)[1] - 1
      Helpers.fill(ctx, { [name] = value })
      vim.api.nvim_win_set_cursor(ctx.win, { row + 1, #value })
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
    assert_eq(Inputs.get_value(ctx, 'search'), 'second', '<Up> 应回溯最近一条')
    press('<Up>')
    assert_eq(Inputs.get_value(ctx, 'search'), 'first', '第二次 <Up> 应回溯更早一条')
    press('<Down>')
    assert_eq(Inputs.get_value(ctx, 'search'), 'second', '<Down> 应回到较新一条')
    press('<Down>')
    assert_eq(Inputs.get_value(ctx, 'search'), 'draft', '最后一次 <Down> 应回到草稿')

    vim.cmd('stopinsert')
    vim.api.nvim_win_set_cursor(ctx.win, { Inputs.results_header_row(ctx) + 1, 0 })
    press('<Up>')
    assert_eq(vim.api.nvim_win_get_cursor(ctx.win)[1], Inputs.results_header_row(ctx), '输入区外的 <Up> 保持原生移动')

    set_field(ctx, 'replace', '$100')
    Replace.close()
    Replace.open({ scope = 'project' })

    ctx = assert(Buffer.current)
    set_field(ctx, 'replace', '')
    assert(Inputs.navigate_history(ctx, -1))
    assert_eq(Inputs.get_value(ctx, 'replace'), '$100', '历史应在面板重开后保留')

    Replace.close()
  end)
end

return T
