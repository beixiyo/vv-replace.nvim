-- 真实 rg → prepare → 文件事务 → refresh；每个场景独立建盘面与面板
local T, child = dofile('tests/helpers.lua').new_set()

local function setup(blocked)
  child.lua_func(function(with_blocked)
    H = Helpers
    FILES = 32
    local files = {}
    for i = 1, FILES do
      -- 混合 CRLF、UTF-8、无末尾换行，损坏任何非匹配字节都必须失败
      files[string.format('batch-%d/item-%04d.txt', i % 4, i)] =
        'head TOKEN ' .. i .. '\r\nfiller 中文\r\nmiddle TOKEN\nfiller\ntail TOKEN'
    end
    if with_blocked then files['zz/last.txt'] = 'TOKEN\nuntouched\n' end
    root, snapshot = H.fixture(files)

    -- 强制每个真实文件操作后让出，避免依赖磁盘速度触发 8ms 预算
    -- sleep 不推进事件循环：若退化成同步写完再 schedule on_done，mid-write tick 仍为 0
    local IO = require('vv-utils.fs.io')
    local write = IO.write_all
    written = 0
    IO.write_all = function(path, bytes, opts)
      local result = write(path, bytes, opts)
      if path:match('%.txt$') then
        written = written + 1
        vim.uv.sleep(1)
      end
      return result
    end
    local Transaction = require('vv-replace.transaction')
    for _, name in ipairs({ 'apply_async', 'undo_async' }) do
      local original = Transaction[name]
      Transaction[name] = function(first, second)
        local opts = name == 'apply_async' and second or first
        opts.budget_ms = 0
        local progress = opts.on_progress
        opts.on_progress = function(value)
          -- 生产事务会 pcall progress，测试观测错误不能随之被静默吞掉
          local ok, err = pcall(function()
            if progress then progress(value) end
            if sample then observe() end
          end)
          if not ok then vim.notify('测试进度观察器出错：' .. tostring(err), vim.log.levels.ERROR) end
        end
        return original(first, second)
      end
    end
    -- 使用真实 mark/slot，只去掉显示延迟；搜索测试另覆盖默认延迟
    local Loading = require('vv-utils.loading')
    local mark = Loading.mark
    Loading.mark = function(opts)
      opts.delay_ms, opts.interval_ms = 0, 1
      local handle = mark(opts)
      handle:on_stop(function()
        -- 登记归零会撤帧，不能用 is_loading 作为检查前提，否则闪断反而漏报
        if sample and not sample.refresh_complete and not ctx.state.closed then
          sample.early_stops = sample.early_stops + 1
        end
      end)
      return handle
    end
    Render = require('vv-replace.render')
    local acquire = Render.acquire_loading
    Render.acquire_loading = function(ctx, label)
      local token = acquire(ctx, label)
      local release = token.release
      token.release = function()
        release()
        if sample then observe() end -- 精确检查写入 → 重搜交接，不靠采样恰好撞上空档
      end
      return token
    end
    local Search = require('vv-replace.search')
    local search_now = Search.search_now
    Search.search_now = function(panel, on_done)
      local current = sample
      local follow_up = current and written > 0 and not panel.state.replacing
      return search_now(panel, function()
        if on_done then on_done() end
        -- 真实 rg 已写入结果并完成 summary 渲染；不依赖 loading 的被测状态判断结束
        if follow_up then current.refresh_complete = true end
      end)
    end
    Action = require('vv-replace.replace')
    Replace = require('vv-replace')
    vim.fn.confirm = function() return 1 end
    ctx = H.open_project(root)
    H.fill(ctx, { search = 'TOKEN', replace = 'DONE', cwd = root })
    H.search(ctx)

    function notified(pattern)
      for _, item in ipairs(notifications) do if item.msg:find(pattern) then return item.msg end end
    end
    function replaced(bytes) return (bytes:gsub('TOKEN', 'DONE')) end
    function observe()
      if ctx.state.closed then return end
      local text = H.loading_text(ctx)
      if text then sample.labels[text] = true end
      if not sample.refresh_complete and not text then sample.gaps = sample.gaps + 1 end
    end
    function seen_progress(verb)
      for text in pairs(sample.labels) do
        local done, total = text:match(verb .. ' (%d+)/(%d+)')
        if done and tonumber(done) > 0 and tonumber(done) < tonumber(total) then return true end
      end
      return false
    end
    function run_sampled(action)
      written = 0
      sample = { labels = {}, gaps = 0, early_stops = 0, midwrite_ticks = 0, refresh_complete = false }
      local timer = assert(vim.uv.new_timer())
      local callback_error
      timer:start(0, 1, vim.schedule_wrap(function()
        local ok, err = pcall(function()
          observe()
          if written > 0 and written < FILES and ctx.state.replacing then
            sample.midwrite_ticks = sample.midwrite_ticks + 1
          end
        end)
        if not ok then callback_error = err end
      end))
      local ok, err = pcall(function()
        action()
        assert(ctx.state.replacing and written < FILES, '动作必须在写入完成前返回')
        H.settle(ctx)
        assert(not callback_error, callback_error)
      end)
      timer:stop()
      timer:close()
      assert(ok, err)
      assert(sample.midwrite_ticks > 0, '事件循环必须在真实文件写入之间推进，而不是只在完成后')
      assert(sample.refresh_complete, '真实的后续搜索必须在动作结束前完成渲染')
      H.eq(sample.early_stops, 0, '可见加载指示不得在真实刷新渲染前停止')
      H.eq(sample.gaps, 0, '真实加载帧在刷新交接期间保持连续')
      H.eq(H.loading_text(ctx), nil, '帧只在最终渲染后移除')
    end
  end, blocked)
end

-- 捕获同步写入退化、重入覆盖、交接闪断、只替换部分文件或破坏无关字节
T['替换写入期间让出事件循环并将加载指示交接给真实刷新'] = function()
  setup(false)
  child.lua_func(function()
    run_sampled(function()
      Action.replace_all(ctx)
      H.eq(vim.bo[ctx.buf].modifiable, false, 'replace 期间面板只读')
      Action.replace_all(ctx)
      assert(notified('replace in progress'), '第二次 replace 必须被拒绝')
    end)
    assert(seen_progress('Replacing'), '真实头部显示部分写入进度')
    local searching = false
    for text in pairs(sample.labels) do if text:find('Searching', 1, true) then searching = true end end
    assert(searching, '同一 loading 槽位显示后续搜索')
    H.assert_files(snapshot, replaced)
    H.eq(H.status_text(ctx), '── Replaced 32 files · 0 matches in 0 files ──', '结果摘要在刷新后保留')
    H.eq(vim.bo[ctx.buf].modifiable, true, 'refresh 后面板可编辑')
  end)
end

-- 撤回必须独立完成一次真实替换，不依赖前一个 case 的快照
T['撤回逐字节还原且加载指示持续推进直到刷新完成'] = function()
  setup(false)
  child.lua_func(function()
    Action.replace_all(ctx)
    H.settle(ctx)
    H.assert_files(snapshot, replaced)
    run_sampled(function() Action.undo_last(ctx) end)
    assert(seen_progress('Restoring'), '真实头部显示部分撤回进度')
    H.assert_files(snapshot)
    H.eq(H.status_text(ctx), '── Restored 32 files · 96 matches in 32 files ──', '撤回摘要在刷新后保留')
    H.eq(vim.bo[ctx.buf].modifiable, true, 'undo 后面板可编辑')
  end)
end

-- 最后一个目录无法建立临时文件；必须真实回滚所有先前写入，而非只还原匹配行
T['写入失败回滚完整文件并释放加载指示'] = function()
  setup(true)
  child.lua_func(function()
    allowed_errors = { 'vv%-replace: .*last%.txt' }
    assert(vim.uv.fs_chmod(root .. '/zz', 365)) -- post_case 失败路径也恢复权限
    run_sampled(function() Action.replace_all(ctx) end)
    assert(vim.uv.fs_chmod(root .. '/zz', 493))
    assert(notified('vv%-replace: .*last%.txt'), '真实权限失败必须被上报')
    assert(seen_progress('Rolling back'), '头部显示真实补偿进度')
    H.assert_files(snapshot)
    assert((H.status_text(ctx) or ''):find('Replacement cancelled', 1, true), '失败状态在 refresh 后保留')
    H.eq(vim.bo[ctx.buf].modifiable, true, '失败后面板可编辑')
  end)
end

-- 只在真实部分写入后关闭；后台必须完成全部文件且不能重建 UI
T['部分写入后关闭仍完成全部文件且不重建面板'] = function()
  setup(false)
  child.lua_func(function()
    written = 0
    Action.replace_all(ctx)
    H.wait(function() return written > 0 and written < FILES end, '必须到达部分磁盘写入阶段')
    Replace.close()
    assert(ctx.state.closed, '事务进行中已关闭')
    H.wait(function() return notified('replaced %d+ files') ~= nil end, '后台完成通知')
    H.assert_files(snapshot, replaced)
    H.eq(require('vv-replace.buffer').current, nil, '迟到的完成不重建 UI')
    H.eq(vim.api.nvim_buf_is_valid(ctx.buf), false, '已关闭面板保持清空')
    H.eq(Render.is_loading(ctx), false, '已关闭面板无 loading 登记')
  end)
end

return T
