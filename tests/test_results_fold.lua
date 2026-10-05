-- 折叠只改变显示，不丢失预览/替换模型；按场景独立搜索同一真实 fixture
local T, child = dofile('tests/helpers.lua').new_set()

local function setup()
  child.lua_func(function()
    H = Helpers
    root, snapshot = H.fixture({
      ['packages/web/src/routes/admin/a.lua'] = 'foo = 1\nx = foo\nfoo()\n',
      ['z.lua'] = 'local foo\nreturn foo\n',
    })
    file_a, file_b = root .. '/packages/web/src/routes/admin/a.lua', root .. '/z.lua'
    Render = require('vv-replace.render')
    Inputs = require('vv-replace.inputs')
    Replace = require('vv-replace')
    ctx = H.open_project(root, { width = 60, rg_extra_args = { '--sort=path' },
      icons = { fold_open = 'v', fold_closed = '>' } })
    H.fill(ctx, { search = 'foo', replace = 'bar', cwd = root })
    H.search(ctx)
    header = Render.header_row(ctx)
    function row() return vim.api.nvim_win_get_cursor(ctx.win)[1] - 1 end
    function goto_row(target) vim.api.nvim_win_set_cursor(ctx.win, { target + 1, 0 }) end
    function line(target) return vim.api.nvim_buf_get_lines(ctx.buf, target, target + 1, false)[1] end
    function count_matches(filename)
      local count = 0
      for _, mark in pairs(ctx.state.result_marks) do
        if mark.kind == 'match' and (not filename or mark.filename == filename) then count = count + 1 end
      end
      return count
    end
    function fold_a()
      goto_row(header + 3)
      H.press('h')
      H.eq(row(), header + 1, '折叠把光标移到文件行')
      H.eq(Render.mark_at_cursor(ctx).folded, true, '光标下是真实折叠行')
      H.eq(count_matches(file_a), 0, '折叠只移除已渲染的匹配行')
      H.eq(#ctx.state.result_matches, 5, '完整预览模型在折叠后保留')
    end
  end)
end

-- 结果导航跳过展开的文件行，输入区仍保持原生编辑/移动
T['结果导航跳过已展开的文件行且不拦截输入区编辑'] = function()
  setup()
  child.lua_func(function()
    Inputs.goto_field(ctx, 'search')
    H.press('ccjkhl<Esc>')
    H.eq(Inputs.get_value(ctx, 'search'), 'jkhl', '插入模式 j/k/h/l 仍是文本')
    goto_row(0)
    H.press('j')
    H.eq(row(), 1, '输入区 j 原生移动')
    H.press('k')
    H.eq(row(), 0, '输入区 k 原生移动')
    H.fill(ctx, { search = 'foo' })
    H.search(ctx)
    goto_row(header)
    H.press('j')
    H.eq(row(), header + 2, 'j 跳过已展开的文件行')
    H.press('3j')
    H.eq(row(), header + 6, '带计数 j 跨过文件边界')
    H.press('<Up>')
    H.eq(row(), header + 4, '<Up> 跳过第二个文件头')
    H.press('2k')
    H.eq(row(), header + 2, '带计数 k 停在第一个匹配')
    H.press('k')
    H.eq(row(), header - 1, 'k 回到输入区')
  end)
end

-- 折叠后的游标索引与真实文件/行号必须一致，展开后能恢复所有匹配
T['折叠后的导航映射到正确源文件，展开进入第一个匹配'] = function()
  setup()
  child.lua_func(function()
    fold_a()
    H.press('h')
    H.eq(row(), header + 1, '重复折叠是无操作')
    H.press('<C-n>')
    H.eq(row(), header + 3, '下一匹配跳过已折叠文件')
    local mark = Render.mark_at_cursor(ctx)
    H.eq(mark.filename, file_b, '光标指向第二个源文件')
    H.eq(mark.lnum, 1, '光标映射到首个源行')
    H.press('<C-p>')
    H.eq(row(), header + 4, '上一匹配在可见匹配间回绕')
    H.press('2k')
    H.eq(row(), header + 1, 'k 停在折叠文件行')
    H.press('l')
    H.eq(row(), header + 2, '展开进入第一个匹配')
    H.eq(Render.mark_at_cursor(ctx).filename, file_a, '展开后光标的源文件')
    H.eq(Render.mark_at_cursor(ctx).lnum, 1, '展开后光标的源行')
    H.eq(count_matches(file_a), 3, '展开恢复已渲染匹配')
  end)
end

-- 重搜按文件路径保存折叠，而非按旧行号；不会从完整模型删掉折叠匹配
T['重搜保留折叠文件及其完整预览模型'] = function()
  setup()
  child.lua_func(function()
    fold_a()
    H.search(ctx)
    H.eq(ctx.state.result_marks[header + 1].folded, true, '折叠在真实 rg refresh 后保留')
    H.eq(count_matches(file_a), 0, 'refresh 后折叠匹配保持隐藏')
    H.eq(#ctx.state.result_matches, 5, 'refresh 保留完整预览模型')
  end)
end

-- 真实 WinResized 接线重排路径，但不得把游标对应的 source match 换掉
T['调整窗口宽度收窄长路径但不改变游标对应的源匹配'] = function()
  setup()
  child.lua_func(function()
    goto_row(header + 2)
    local before = Render.mark_at_cursor(ctx)
    vim.api.nvim_win_set_width(ctx.win, 20)
    vim.api.nvim_exec_autocmds('WinResized', {})
    H.eq(line(header + 1), 'v …/a.lua', '窄宽度保留文件名')
    H.eq(Render.mark_at_cursor(ctx).filename, before.filename, 'resize 保留源文件')
    H.eq(Render.mark_at_cursor(ctx).lnum, before.lnum, 'resize 保留源行')
    vim.api.nvim_win_set_width(ctx.win, 60)
    vim.api.nvim_exec_autocmds('WinResized', {})
    H.eq(line(header + 1), 'v packages/…/routes/admin/a.lua', '宽宽度恢复目录')
  end)
end

-- Replace All 不能误用折叠后的可见行作为写入数据；逐文件比较完整字节
T['替换依据完整搜索模型写入折叠与展开的全部匹配'] = function()
  setup()
  child.lua_func(function()
    fold_a()
    vim.fn.confirm = function() return 1 end
    require('vv-replace.replace').replace_all(ctx)
    H.settle(ctx)
    H.assert_files(snapshot, function(bytes) return (bytes:gsub('foo', 'bar')) end)
  end)
end

return T
