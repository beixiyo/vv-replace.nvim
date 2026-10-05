-- 替换写回
--
-- 策略（借鉴 grug-far 的 getReplacedContents）：
--   1. 复用 ctx.state.last_json —— 搜索时已带 --replace=<text>，submatch.replacement 直接可用
--   2. 对每个 match 文件：fs_read 整文件 → 按 match 的 absolute_offset 精确拼接 → fs_write
--      —— 不用 rg --passthrough 避免末尾换行问题
--   3. 读取拼接与事务写入都按文件分片（每片约 8ms 后经 uv timer 让出），结果区标题行的
--      loading 帧与进度 label 全程转动；全部完成后重跑搜索，帧持续到新结果渲染完毕
--      帧落在结果区标题行，与搜索共用 Render.acquire_loading 的同一 slot，生命周期各自独立
--
-- 面板中途关闭：读取拼接阶段尚未写盘，直接停止；写入阶段已开始的事务不可取消，
-- 照常写完或回滚（不留半写状态），结果改用 notify 告知

local Inputs = require('vv-replace.inputs')
local Search = require('vv-replace.search')
local Render = require('vv-replace.render')
local Transaction = require('vv-replace.transaction')
local fs = require('vv-utils.fs')

local uv = vim.uv

local M = {}

local SLICE_BUDGET_MS = 8

local STEP_LABELS = {
  validate = 'Checking',
  apply = 'Replacing',
  compensate = 'Rolling back',
}

local function count_label(count, singular, plural)
  return string.format('%d %s', count, count == 1 and singular or plural)
end

-- 按文件名拆分 rg json 流 → { [filename] = [match_obj, ...] }
---@param json_matches any[]
---@return table<string, any[]>
local function group_matches_by_file(json_matches)
  local grouped = {}
  local current = nil
  for _, obj in ipairs(json_matches) do
    if obj.type == 'begin' then
      current = vim.fs.normalize(obj.data.path.text or obj.data.path.bytes or '?')
      grouped[current] = grouped[current] or {}
    elseif obj.type == 'match' and current then
      grouped[current][#grouped[current] + 1] = obj
    elseif obj.type == 'end' then
      current = nil
    end
  end
  return grouped
end

-- 用 match 数组拼新文件内容
---@param old string
---@param matches any[]
---@return string
local function compute_new_content(old, matches)
  table.sort(matches, function(a, b) return a.data.absolute_offset < b.data.absolute_offset end)
  local out = {}
  local last = 0
  for _, m in ipairs(matches) do
    local offset = m.data.absolute_offset
    if offset >= last then
      -- lines.text 仅对合法 UTF-8 行存在；含非法字节的行 rg 只给 lines.bytes(base64)
      -- 回退解码原始字节，与 group_matches_by_file 对 path 的处理一致
      local L = m.data.lines
      local match_text = L.text or (L.bytes and vim.base64.decode(L.bytes)) or ''
      -- 陈旧守卫：搜索后文件若在磁盘上改动，缓存的 offset 会指向错误字节并悄悄损坏文件
      -- 拼接前校验缓存行仍处在 offset 所指位置，不符就报错（外层 pcall 接住，文件保持完整）
      if old:sub(offset + 1, offset + #match_text) ~= match_text then
        error('stale: file changed on disk since search')
      end
      out[#out + 1] = old:sub(last + 1, offset)
      local sub_last = 0
      local rebuilt = {}
      for _, sub in ipairs(m.data.submatches or {}) do
        rebuilt[#rebuilt + 1] = match_text:sub(sub_last + 1, sub.start)
        local rep = sub.replacement and sub.replacement.text or ''
        rebuilt[#rebuilt + 1] = rep
        sub_last = sub['end']
      end
      if sub_last < #match_text then
        rebuilt[#rebuilt + 1] = match_text:sub(sub_last + 1)
      end
      out[#out + 1] = table.concat(rebuilt)
      last = offset + #match_text
    end
  end
  if last < #old then
    out[#out + 1] = old:sub(last + 1)
  end
  return table.concat(out)
end

---@param verb string
---@param done integer
---@param total integer
---@return string
local function progress_label(verb, done, total)
  return string.format('%s %d/%d', verb, done, total)
end

-- 按文件分片读取并拼接新内容：每片按时间预算处理若干文件后经 uv timer 让出主线程
-- 只读不写；is_cancelled 为真时在下一片开始前停止并以 cancelled 结束
---@param files string[]
---@param grouped table<string, any[]>
---@param opts VVReplacePrepareOpts
local function prepare_entries(files, grouped, opts)
  ---@type vv-utils.fs.TransactionEntry[]
  local entries = {}
  local index = 1
  local timer = uv.new_timer()

  local function finish(result)
    if timer and not timer:is_closing() then timer:close() end
    opts.on_done(result)
  end

  local function step()
    if opts.is_cancelled() then return finish({ cancelled = true }) end

    local started = uv.hrtime()
    while index <= #files and (uv.hrtime() - started) / 1e6 < SLICE_BUDGET_MS do
      local file = files[index]
      index = index + 1

      local ok_read, old = pcall(fs.read_all, file)
      if not ok_read then
        return finish({ error = 'read failed: ' .. file .. '\n' .. tostring(old) })
      end
      local ok_new, new_content = pcall(compute_new_content, old, grouped[file])
      if not ok_new then
        return finish({ error = file .. '\n' .. tostring(new_content) })
      end
      if new_content ~= old then
        entries[#entries + 1] = { path = file, old = old, new = new_content }
      end
    end

    opts.on_progress(index - 1, #files)
    if index > #files then return finish({ entries = entries }) end
    if not timer then return finish({ error = 'could not create timer' }) end
    timer:start(0, 0, vim.schedule_wrap(step))
  end

  step()
end

-- 写入后的收尾：summary 先记为状态，再发起重搜；重搜在同一 slot 登记 Searching 后才释放本次登记，
-- 帧不中断地持续到新结果渲染完。重搜写出的 "N matches in M files" 与 summary 拼接，
-- 避免替换结果被随后的搜索状态覆盖
---@param ctx VVReplaceCtx
---@param loading VVReplaceLoadingToken
---@param summary string
---@param is_error? boolean
local function refresh_after_write(ctx, loading, summary, is_error)
  Render.render_status(ctx, summary, is_error)
  Search.search_now(ctx, function()
    local last = ctx.state.last_status
    if last and last.text ~= '' and not last.is_error then
      Render.render_status(ctx, summary .. ' · ' .. last.text, is_error)
    end
  end)
  loading.release()
end

---@param ctx VVReplaceCtx
---@param researched boolean?  内部用：true 表示刚为本次替换重搜过，跳过新鲜度判定防无限递归
function M.replace_all(ctx, researched)
  if ctx.state.replacing or Transaction.is_busy() then
    vim.notify('vv-replace: replace in progress', vim.log.levels.WARN)
    return
  end

  local values = Inputs.get_values(ctx)
  -- search 为空守卫前置：空搜索直接退出，不触发重搜
  if not values.search or values.search == '' then
    vim.notify('vv-replace: search is empty', vim.log.levels.WARN)
    return
  end

  -- 新鲜度判定：on_change 会「立刻」更新 last_inputs 但 debounce 后才真正搜索，
  -- 故不能用 last_inputs 判陈旧；要看 last_json 实际是用哪次输入算出来的（last_searched_inputs）
  -- 用户改 Replace 框后 debounce 内立即按替换时，last_json 仍是旧快照，必须先用当前输入重搜再替换
  local fresh = ctx.state.last_searched_inputs
    and vim.deep_equal(values, ctx.state.last_searched_inputs)
    and not ctx.state.searching
  if not researched and not fresh then
    Search.search_now(ctx, function()
      if ctx.state.closed or ctx.state.replacing then return end
      M.replace_all(ctx, true)
    end)
    return
  end
  if not values.replace or values.replace == '' then
    -- 空替换 = 删除匹配，VSCode 同样允许，但要额外确认
    local c = vim.fn.confirm('Replace is empty. Delete all matches?', '&Yes\n&No', 2, 'Question')
    if c ~= 1 then return end
  end

  local last = ctx.state.last_json
  if not last or #last == 0 then
    vim.notify('vv-replace: no search results', vim.log.levels.WARN)
    return
  end

  local grouped = group_matches_by_file(last)
  local files = {}
  local total_matches = 0
  for file, matches in pairs(grouped) do
    files[#files + 1] = file
    for _, m in ipairs(matches) do
      total_matches = total_matches + #(m.data.submatches or {})
    end
  end
  table.sort(files)

  if #files == 0 then
    vim.notify('vv-replace: no matching files', vim.log.levels.WARN)
    return
  end

  local choice = vim.fn.confirm(
    string.format(
      'Replace %s in %s?',
      count_label(total_matches, 'match', 'matches'),
      count_label(#files, 'file', 'files')
    ),
    '&Yes\n&No', 1, 'Question'
  )
  if choice ~= 1 then return end

  ctx.state.replacing = true
  local was_modifiable = vim.bo[ctx.buf].modifiable
  vim.bo[ctx.buf].modifiable = false
  local loading = Render.acquire_loading(ctx, progress_label('Preparing', 0, #files))

  local function release_panel()
    ctx.state.replacing = false
    if vim.api.nvim_buf_is_valid(ctx.buf) then
      vim.bo[ctx.buf].modifiable = was_modifiable
    end
  end

  ---@param entries vv-utils.fs.TransactionEntry[]
  local function write(entries)
    Transaction.apply_async(entries, {
      on_progress = function(progress)
        loading.set_label(progress_label(STEP_LABELS[progress.step], progress.done, progress.total))
      end,
      on_done = function(ok, err, touched)
        release_panel()
        if ok or touched then vim.cmd('silent! checktime') end

        if ctx.state.closed then
          loading.release()
          if ok then
            vim.notify('vv-replace: replaced ' .. count_label(#entries, 'file', 'files'), vim.log.levels.INFO)
          else
            vim.notify('vv-replace: ' .. tostring(err), vim.log.levels.ERROR)
          end
          return
        end

        if not ok then
          vim.notify('vv-replace: ' .. tostring(err), vim.log.levels.ERROR)
          if touched then
            refresh_after_write(ctx, loading, 'Replacement cancelled', true)
          else
            Render.render_status(ctx, 'Replacement cancelled', true)
            loading.release()
          end
          return
        end

        Inputs.render(ctx)
        refresh_after_write(ctx, loading, 'Replaced ' .. count_label(#entries, 'file', 'files'))
      end,
    })
  end

  prepare_entries(files, grouped, {
    is_cancelled = function() return ctx.state.closed end,
    on_progress = function(done, total)
      loading.set_label(progress_label('Preparing', done, total))
    end,
    on_done = function(result)
      if result.cancelled then
        loading.release()
        release_panel()
        return
      end
      if result.error then
        release_panel()
        Render.render_status(ctx, 'Replacement cancelled', true)
        loading.release()
        vim.notify('vv-replace: ' .. result.error, vim.log.levels.ERROR)
        return
      end
      write(result.entries)
    end,
  })
end

-- 撤回最近一次替换；面板打开时在结果区标题行显示进度，面板关闭时只经 notify 告知
---@param ctx VVReplaceCtx?
function M.undo_last(ctx)
  local panel = ctx and not ctx.state.closed and vim.api.nvim_buf_is_valid(ctx.buf) and ctx or nil
  if (panel and panel.state.replacing) or Transaction.is_busy() then
    vim.notify('vv-replace: replace in progress', vim.log.levels.WARN)
    return
  end

  -- 无可撤回（无记录 / 已锁定）时同步拒绝且无副作用，直接复用其错误信息，不闪 loading
  if not Transaction.can_undo() then
    local _, err = Transaction.undo()
    vim.notify('vv-replace: ' .. tostring(err), vim.log.levels.WARN)
    if panel then Render.render_status(panel, 'Undo cancelled', true) end
    return
  end

  local loading, was_modifiable
  if panel then
    panel.state.replacing = true
    was_modifiable = vim.bo[panel.buf].modifiable
    vim.bo[panel.buf].modifiable = false
    loading = Render.acquire_loading(panel, 'Restoring')
  end

  Transaction.undo_async({
    on_progress = function(progress)
      if not loading then return end
      local verb = progress.step == 'validate' and 'Checking' or 'Restoring'
      loading.set_label(progress_label(verb, progress.done, progress.total))
    end,
    on_done = function(ok, err, count, touched)
      if panel then
        panel.state.replacing = false
        if vim.api.nvim_buf_is_valid(panel.buf) then
          vim.bo[panel.buf].modifiable = was_modifiable
        end
      end
      if ok or touched then vim.cmd('silent! checktime') end
      local open = panel and not panel.state.closed

      if not ok then
        vim.notify('vv-replace: ' .. tostring(err), vim.log.levels.WARN)
        if not open then
          if loading then loading.release() end
        elseif touched then
          refresh_after_write(panel, loading, 'Undo cancelled', true)
        else
          Render.render_status(panel, 'Undo cancelled', true)
          loading.release()
        end
        return
      end

      local restored = count_label(count or 0, 'file', 'files')
      vim.notify('vv-replace: restored ' .. restored, vim.log.levels.INFO)
      if not open then
        if loading then loading.release() end
        return
      end
      Inputs.render(panel)
      refresh_after_write(panel, loading, 'Restored ' .. restored)
    end,
  })
end

---@return boolean
function M._can_undo()
  return Transaction.can_undo()
end

return M

---@class VVReplacePrepareResult
---@field entries? vv-utils.fs.TransactionEntry[]  内容有变化的文件
---@field error? string  首个读取或拼接失败
---@field cancelled? boolean  is_cancelled 为真提前停止

---@class VVReplacePrepareOpts
---@field is_cancelled fun(): boolean  每片开始前检查
---@field on_progress fun(done: integer, total: integer)  每片结束后触发
---@field on_done fun(result: VVReplacePrepareResult)  只触发一次
