-- 真实 rg 的结果、状态与 loading 生命周期；各 case 独立建立旧状态
local T, child = dofile('tests/helpers.lua').new_set()

local function setup()
  child.lua_func(function()
    H = Helpers
    local files = {}
    for i = 1, 20 do files[string.format('f%02d.txt', i)] = 'alpha ' .. i .. '\nbeta\n' end
    root = H.fixture(files)
    ctx = H.open_project(root)
    Render = require('vv-replace.render')
    Search = require('vv-replace.search')
    Replace = require('vv-replace')
    function fill(values)
      H.fill(ctx, vim.tbl_extend('force', { search = '', replace = '', include = '', exclude = '', cwd = root }, values))
    end
  end)
end

-- 完成时必须渲染本次结果、恢复状态，且不泄漏 loading 登记
T['完成后移除帧并渲染新状态'] = function()
  setup()
  child.lua_func(function()
    fill({ search = 'alpha' })
    H.search(ctx)
    H.eq(H.status_text(ctx), '── 20 matches in 20 files ──', '首次搜索后的状态')
    H.eq(#ctx.state.result_matches, 20, '真实搜索结果已渲染')
    H.eq(H.loading_text(ctx), nil, '搜索完成后无帧')
  end)
end

-- 长 debounce 只用于隔离默认 150ms 出帧条件，不以 250/400ms 窄时间窗判断正确性
T['防抖隐藏过期状态并延迟显示加载帧'] = function()
  setup()
  child.lua_func(function()
    fill({ search = 'alpha' })
    H.search(ctx)
    fill({ search = 'beta' })
    Search.on_change(ctx)
    assert(Render.is_loading(ctx), 'on_change 在 debounce 触发前登记 loading')
    H.eq(H.status_text(ctx), nil, '过期计数立即隐藏')
    H.eq(H.loading_text(ctx), nil, '默认延迟避免立即闪烁')
    H.wait(function() return H.loading_text(ctx) ~= nil end, 'pending debounce 期间的延迟帧')
    assert(not ctx.state.searching, '帧在真实 rg 启动前出现')
    assert(H.loading_text(ctx):find('Searching', 1, true), '真实头部显示 Searching')
    -- 改短配置并再次走生产 on_change，验证真正的 debounce callback，而非手动触发搜索
    ctx.config.debounce_ms = 1
    fill({ search = 'alpha' })
    Search.on_change(ctx)
    H.settle(ctx)
    H.eq(H.status_text(ctx), '── 20 matches in 20 files ──', '防抖搜索渲染新状态')
    H.eq(H.loading_text(ctx), nil, '帧在 debounce 与 rg 完成后释放')
  end)
end

-- latest-wins 和手动搜索接管 debounce 时，旧任务不得覆盖结果或泄漏登记
T['取代搜索与手动搜索释放旧登记'] = function()
  setup()
  child.lua_func(function()
    fill({ search = 'alpha 1' })
    Search.search_now(ctx)
    fill({ search = 'alpha 3' })
    Search.search_now(ctx)
    assert(Render.is_loading(ctx), '取代搜索保持 loading 登记')
    H.settle(ctx)
    H.eq(H.status_text(ctx), '── 1 matches in 1 files ──', '最新计数获胜')
    H.eq(ctx.state.result_matches[1].filename, root .. '/f03.txt', '最新文件获胜，而非仅计数恰好相等')
    fill({ search = 'beta' })
    Search.on_change(ctx)
    H.search(ctx)
    H.eq(H.status_text(ctx), '── 20 matches in 20 files ──', '手动搜索接管 pending debounce')
    assert(not Render.is_loading(ctx), '全部旧登记已释放')
  end)
end

T['非法通配模式同步释放加载指示'] = function()
  setup()
  child.lua_func(function()
    fill({ search = 'beta', include = '*.{ts' })
    Search.search_now(ctx)
    assert(not Render.is_loading(ctx), '参数错误同步释放 loading')
    assert((H.status_text(ctx) or ''):find('Error: Include', 1, true), '非法 glob 有可见错误状态')
  end)
end

-- 同时保留真实搜索的非空结果/last_json 和旧计数；全新空面板无法捕获“忘记清空”
T['空查询清空旧结果、缓存 JSON 与状态并取消防抖'] = function()
  setup()
  child.lua_func(function()
    fill({ search = 'alpha' })
    H.search(ctx)
    assert(#ctx.state.result_matches > 0 and #ctx.state.last_json > 0, '前置条件：真实缓存且已渲染的匹配')
    H.eq(H.status_text(ctx), '── 20 matches in 20 files ──', '前置条件：真实的非空旧状态')
    fill({ search = 'gamma' })
    Search.on_change(ctx)
    assert(Render.is_loading(ctx), 'pending debounce 已登记')
    assert(#ctx.state.last_json > 0, 'pending debounce 仍持有旧缓存结果')
    fill({ search = '' })
    Search.on_change(ctx)
    assert(not Render.is_loading(ctx), '空查询释放 debounce 登记')
    H.eq(H.status_text(ctx), nil, '旧计数被清空，loading 结束时不恢复')
    H.eq(ctx.state.last_status.text, '', '保存的状态同样被清空')
    H.eq(ctx.state.last_json, nil, '缓存 json 不能被 replace 复用')
    H.eq(ctx.state.result_matches, {}, '预览模型已清空')
    H.eq(ctx.state.result_marks, {}, '已渲染结果标记已清空')
    local header = Render.header_row(ctx)
    H.eq(vim.api.nvim_buf_get_lines(ctx.buf, header + 1, -1, false), {}, '可见结果行已清空')
  end)
end

T['防抖期间关闭会释放加载指示与定时器'] = function()
  setup()
  child.lua_func(function()
    fill({ search = 'alpha' })
    Search.on_change(ctx)
    assert(Render.is_loading(ctx), 'close 前 debounce 已登记')
    local timer = ctx.state.search_timer
    Replace.close()
    assert(not Render.is_loading(ctx), 'close 释放 loading')
    assert(timer:is_closing(), 'close 物理取消 debounce timer')
    H.eq(require('vv-replace.buffer').current, nil, 'close 释放面板 context')
  end)
end

-- 使用真实 rg 输出；只控制 exit 的交付时序，不伪造搜索结果或渲染器
T['旧搜索已退出但结果尚未交付时新搜索阻止旧写回'] = function()
  setup()
  child.lua_func(function()
    local system = vim.system
    local handoff = false
    local obsolete_done, latest_done = false, false
    vim.system = function(command, opts, on_exit)
      if command[1] ~= 'rg' or handoff then return system(command, opts, on_exit) end
      handoff = true
      return system(command, opts, function(result)
        vim.schedule(function()
          on_exit(result) -- A 已退出，生产代码把结果发布排进 schedule 队列
          fill({ search = 'alpha 3' })
          Search.search_now(ctx, function() latest_done = true end) -- 同一轮立即启动 B
        end)
      end)
    end

    local ok, err = pcall(function()
      fill({ search = 'alpha 1' })
      Search.search_now(ctx, function() obsolete_done = true end)
      H.wait(function() return latest_done end, '新搜索必须完成真实 rg 交付')
      assert(not obsolete_done, '旧 scheduled 结果不得渲染或触发旧 on_done（替换可能挂在它上面）')
      H.eq(ctx.state.last_searched_inputs.search, 'alpha 3', '结果缓存来源必须是新搜索')
      H.eq(ctx.state.result_matches[1].filename, root .. '/f03.txt', '实际预览结果必须来自新搜索')
      assert(not Render.is_loading(ctx), '被取代的已退出搜索也必须释放自己的 loading')
    end)
    vim.system = system
    assert(ok, err)
  end)
end

return T
