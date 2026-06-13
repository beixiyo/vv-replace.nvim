-- 替换写回
--
-- 策略（借鉴 grug-far 的 getReplacedContents）：
--   1. 复用 ctx.state.last_json —— 搜索时已带 --replace=<text>，submatch.replacement 直接可用
--   2. 对每个 match 文件：fs_read 整文件 → 按 match 的 absolute_offset 精确拼接 → fs_write
--      —— 不用 rg --passthrough 避免末尾换行问题
--   3. 每写完一个文件就刷进度；全部完成后重跑搜索刷新结果

local Inputs = require('vv-replace.inputs')
local Search = require('vv-replace.search')
local Render = require('vv-replace.render')
local fs = require('vv-utils.fs')

local M = {}

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

---@param ctx VVReplaceCtx
---@param researched boolean?  内部用：true 表示刚为本次替换重搜过，跳过新鲜度判定防无限递归
function M.replace_all(ctx, researched)
  if ctx.state.replacing then
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
    string.format('Replace %d matches in %d files?', total_matches, #files),
    '&Yes\n&No', 1, 'Question'
  )
  if choice ~= 1 then return end

  ctx.state.replacing = true
  vim.bo[ctx.buf].modifiable = false
  Render.render_status(ctx, 'Replacing 0/' .. #files)

  -- 串行（简单 + 对 fs 压力友好；MVP 够用）
  local ok_count = 0
  local fail = {}
  local function step(i)
    -- 面板已关闭 / buffer 已被 wipe 时安全中止：剩余文件可重新搜索替换补齐，
    -- 已替换的内容不会再命中，故中止可恢复，不会留下半成品状态
    if ctx.state.closed or not vim.api.nvim_buf_is_valid(ctx.buf) then
      ctx.state.replacing = false
      return
    end
    if i > #files then
      -- 完成
      -- buf 可能在最后一个 step 排队后才失效，这里再判一次再写 modifiable
      if vim.api.nvim_buf_is_valid(ctx.buf) then
        vim.bo[ctx.buf].modifiable = true
      end
      ctx.state.replacing = false
      if #fail > 0 then
        Render.render_status(ctx, string.format('%d done, %d failed', ok_count, #fail), true)
        vim.notify('vv-replace: failed files:\n' .. table.concat(fail, '\n'), vim.log.levels.ERROR)
      else
        Render.render_status(ctx, string.format('Replaced %d files', ok_count))
      end
      -- 刷新 buffer 视图 + 重跑搜索（已替换的匹配应消失）
      vim.schedule(function()
        -- 让已打开的 buffer 重新 checktime 加载磁盘新内容
        vim.cmd('silent! checktime')
        Search.search_now(ctx)
      end)
      return
    end
    local file = files[i]
    vim.schedule(function()
      Render.render_status(ctx, string.format('Replacing %d/%d', i, #files))
      local ok_read, old = pcall(fs.read_all, file)
      if not ok_read then
        fail[#fail + 1] = file .. ' (read failed: ' .. tostring(old) .. ')'
      else
        local ok_new, new_content = pcall(compute_new_content, old, grouped[file])
        if not ok_new then
          -- 陈旧/非法字节等导致拼接失败：不写入，列入失败清单，文件保持原样
          fail[#fail + 1] = file .. ' (' .. tostring(new_content) .. ')'
        elseif new_content ~= old then
          local ok_write, werr = pcall(fs.write_all, file, new_content)
          if not ok_write then
            fail[#fail + 1] = file .. ' (' .. tostring(werr) .. ')'
          else
            ok_count = ok_count + 1
          end
        end
      end
      step(i + 1)
    end)
  end
  step(1)
end

return M
