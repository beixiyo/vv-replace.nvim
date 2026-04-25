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
      out[#out + 1] = old:sub(last + 1, offset)
      local match_text = m.data.lines.text or ''
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
function M.replace_all(ctx)
  if ctx.state.replacing then
    vim.notify('vv-replace: replace in progress', vim.log.levels.WARN)
    return
  end
  if ctx.state.searching then
    vim.notify('vv-replace: wait for search to finish', vim.log.levels.WARN)
    return
  end

  local values = Inputs.get_values(ctx)
  if not values.search or values.search == '' then
    vim.notify('vv-replace: search is empty', vim.log.levels.WARN)
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
    if i > #files then
      -- 完成
      vim.bo[ctx.buf].modifiable = true
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
        local new_content = compute_new_content(old, grouped[file])
        if new_content ~= old then
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
