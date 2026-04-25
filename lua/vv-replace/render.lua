-- 结果渲染：rg json 解析 + buffer 写入 + 高亮
--
-- 结构约定：
--   header_row（由 results_header extmark 定位）上方是输入区，下方是结果区。
--   结果区布局：
--     row header     → 空行，virt_text 显示状态（"N 个匹配 / M 个文件"）
--     row header + 1 → <文件路径>  (N)
--     row header + 2 →   <lnum>: <匹配行文本>        ← 搜索行
--     row header + 3 →   <lnum>: <替换后文本>        ← 有 replace 时
--     row header + 4 → 空行
--     row header + 5 → <下个文件路径> ...

local M = {}

---@class VVReplaceResultMark
---@field row integer  buffer 内 0-based 行
---@field kind 'file'|'match'  file=文件 header，match=匹配源
---@field filename string
---@field lnum integer?  match 时的文件内 1-based 行号
---@field col integer?  match 时的列号（1-based）
---@field text string?  匹配行原文本

---@class VVReplaceParsed
---@field lines string[]  要写入 buffer 的所有行（不含 header 分隔行）
---@field marks VVReplaceResultMark[]  每行的元数据
---@field highlights VVReplaceHighlight[]  高亮范围
---@field stats { files: integer, matches: integer }

---@class VVReplaceHighlight
---@field row integer
---@field col_start integer
---@field col_end integer
---@field hl_group string

---@param ctx VVReplaceCtx
---@return integer
local function get_header_row(ctx)
  local id = ctx.extmark_ids.results_header
  if id then
    local mark = vim.api.nvim_buf_get_extmark_by_id(ctx.buf, ctx.namespace, id, {})
    if mark and mark[1] then return mark[1] end
  end
  return require('vv-replace.inputs').results_header_row(ctx)
end

-- 根据 rg 的 --json 流结果生成渲染数据
---@param json_matches any[]  rg NDJSON 解析后对象数组
---@param has_replace boolean
---@return VVReplaceParsed
function M.parse_results(json_matches, has_replace)
  local lines = {}
  local marks = {}
  local highlights = {}
  local stats = { files = 0, matches = 0 }
  local current_file = nil

  for _, obj in ipairs(json_matches) do
    if obj.type == 'begin' then
      stats.files = stats.files + 1
      current_file = obj.data.path.text or obj.data.path.bytes or '?'
      current_file = vim.fs.normalize(current_file)
      -- 文件 header 行（真正的计数稍后回填）
      local header_row = #lines
      lines[#lines + 1] = current_file
      marks[#marks + 1] = {
        row = header_row,
        kind = 'file',
        filename = current_file,
      }
      highlights[#highlights + 1] = {
        row = header_row,
        col_start = 0,
        col_end = #current_file,
        hl_group = 'VVReplaceFilePath',
      }
      -- 文件头占位：count 稍后用 virt_text 覆盖右端，不走 lines

    elseif obj.type == 'match' and current_file then
      local data = obj.data
      local submatches = data.submatches or {}
      stats.matches = stats.matches + #submatches

      -- rg 的 lines.text 可能含换行（多行匹配）；MVP 保守取第一行作为单行渲染
      local raw_text = data.lines and (data.lines.text or '') or ''
      raw_text = raw_text:gsub('\r?\n$', '')  -- 去尾换行
      local first_line = raw_text:match('([^\n]*)') or ''

      local lnum = data.line_number or 0
      local prefix = string.format('  %d: ', lnum)

      -- 搜索行
      local search_row = #lines
      local search_line = prefix .. first_line
      lines[#lines + 1] = search_line
      marks[#marks + 1] = {
        row = search_row,
        kind = 'match',
        filename = current_file,
        lnum = lnum,
        col = (submatches[1] and submatches[1].start + 1) or 1,
        text = first_line,
      }
      highlights[#highlights + 1] = {
        row = search_row,
        col_start = 0,
        col_end = #prefix,
        hl_group = 'VVReplaceLineNumber',
      }
      for _, sub in ipairs(submatches) do
        -- rg 的 submatch.start 是相对整个 match lines.text 的字节偏移；
        -- 单行情况下 = 相对 first_line 的字节偏移
        local s = sub.start
        local e = sub['end']
        if s and e and s < #first_line then
          highlights[#highlights + 1] = {
            row = search_row,
            col_start = #prefix + s,
            col_end = #prefix + math.min(e, #first_line),
            hl_group = has_replace and 'VVReplaceMatchRemoved' or 'VVReplaceMatch',
          }
        end
      end

      -- 替换行（如有）
      if has_replace and submatches[1] and submatches[1].replacement then
        local replaced_text = ''
        local last = 0
        local add_ranges = {}
        for _, sub in ipairs(submatches) do
          local seg = first_line:sub(last + 1, sub.start)
          replaced_text = replaced_text .. seg
          local add_start = #replaced_text
          local rep = (sub.replacement and sub.replacement.text) or ''
          -- 多行替换保守取首行
          rep = rep:match('([^\n]*)') or ''
          replaced_text = replaced_text .. rep
          add_ranges[#add_ranges + 1] = { add_start, #replaced_text }
          last = sub['end']
        end
        if last < #first_line then
          replaced_text = replaced_text .. first_line:sub(last + 1)
        end

        local replace_row = #lines
        local replace_line = prefix .. replaced_text
        lines[#lines + 1] = replace_line
        -- 替换行继承源行 mark（跳转跳源文件的源 lnum/col）
        marks[#marks + 1] = {
          row = replace_row,
          kind = 'match',
          filename = current_file,
          lnum = lnum,
          col = (submatches[1] and submatches[1].start + 1) or 1,
          text = first_line,
        }
        highlights[#highlights + 1] = {
          row = replace_row,
          col_start = 0,
          col_end = #prefix,
          hl_group = 'VVReplaceLineNumber',
        }
        for _, rng in ipairs(add_ranges) do
          highlights[#highlights + 1] = {
            row = replace_row,
            col_start = #prefix + rng[1],
            col_end = #prefix + rng[2],
            hl_group = 'VVReplaceMatchAdded',
          }
        end
      end

    elseif obj.type == 'end' then
      lines[#lines + 1] = ''  -- 文件之间空行
    end
  end

  -- 如果最后一行是空行，去掉
  while #lines > 0 and lines[#lines] == '' do lines[#lines] = nil end

  return { lines = lines, marks = marks, highlights = highlights, stats = stats }
end

---@param ctx VVReplaceCtx
local function clear_results_extmarks(ctx)
  local buf = ctx.buf
  -- results 区 extmark 都存在 result_extmark_ids（我们自己维护）
  for _, id in ipairs(ctx.state.result_extmark_ids or {}) do
    pcall(vim.api.nvim_buf_del_extmark, buf, ctx.namespace, id)
  end
  ctx.state.result_extmark_ids = {}
  -- 额外清除 header 行的 virt_text（状态提示）
  if ctx.extmark_ids.status then
    pcall(vim.api.nvim_buf_del_extmark, buf, ctx.namespace, ctx.extmark_ids.status)
    ctx.extmark_ids.status = nil
  end
  ctx.state.result_marks = {}
end

---@param ctx VVReplaceCtx
function M.clear_results(ctx)
  vim.bo[ctx.buf].modifiable = true
  clear_results_extmarks(ctx)
  local header_row = get_header_row(ctx)
  local line_count = vim.api.nvim_buf_line_count(ctx.buf)
  if line_count > header_row + 1 then
    vim.api.nvim_buf_set_lines(ctx.buf, header_row + 1, -1, false, {})
  end
  -- 确保 header 行存在且为空
  local header_line = vim.api.nvim_buf_get_lines(ctx.buf, header_row, header_row + 1, false)[1]
  if header_line == nil then
    vim.api.nvim_buf_set_lines(ctx.buf, header_row, header_row, false, { '' })
  end
end

---@param ctx VVReplaceCtx
---@param parsed VVReplaceParsed
function M.render_results(ctx, parsed)
  vim.bo[ctx.buf].modifiable = true
  clear_results_extmarks(ctx)

  local buf = ctx.buf
  local header_row = get_header_row(ctx)
  local line_count = vim.api.nvim_buf_line_count(buf)

  -- 先写入 header 行（空占位，靠 virt_text 装饰）+ 结果
  local to_write = { '' }
  for _, line in ipairs(parsed.lines) do to_write[#to_write + 1] = line end
  vim.api.nvim_buf_set_lines(buf, header_row, line_count, false, to_write)

  -- 应用高亮
  ctx.state.result_extmark_ids = ctx.state.result_extmark_ids or {}
  for _, hl in ipairs(parsed.highlights) do
    local id = vim.api.nvim_buf_set_extmark(buf, ctx.namespace, header_row + 1 + hl.row, hl.col_start, {
      end_col = hl.col_end,
      hl_group = hl.hl_group,
    })
    ctx.state.result_extmark_ids[#ctx.state.result_extmark_ids + 1] = id
  end

  -- 保存 marks 映射（行号要加上 header_row + 1 偏移）
  ctx.state.result_marks = {}
  for _, mark in ipairs(parsed.marks) do
    local buf_row = header_row + 1 + mark.row
    ctx.state.result_marks[buf_row] = mark
  end

  -- 文件 header 的 virt_text（"(N)" 匹配数）
  -- 实现：parse 时没有直接带 count，这里按 marks 分组统计
  local per_file_count = {}
  for _, mark in ipairs(parsed.marks) do
    if mark.kind == 'match' then
      per_file_count[mark.filename] = (per_file_count[mark.filename] or 0) + 1
    end
  end
  for _, mark in ipairs(parsed.marks) do
    if mark.kind == 'file' then
      local count = per_file_count[mark.filename] or 0
      local id = vim.api.nvim_buf_set_extmark(buf, ctx.namespace, header_row + 1 + mark.row, 0, {
        virt_text = { { '  (' .. count .. ')', 'VVReplaceFileCount' } },
        virt_text_pos = 'eol',
      })
      ctx.state.result_extmark_ids[#ctx.state.result_extmark_ids + 1] = id
    end
  end
end

-- 在 header_row 那行显示状态（"搜索中..." / "N 个匹配 / M 个文件" / "错误: ..."）
-- 记录到 ctx.state.last_status，便于 flash_status 覆盖后还原
---@param ctx VVReplaceCtx
---@param text string
---@param is_error? boolean
function M.render_status(ctx, text, is_error)
  ctx.state.last_status = { text = text, is_error = is_error }
  M._paint_status(ctx, text, is_error and 'VVReplaceStatusError' or 'VVReplaceStatus')
end

-- 临时 toast：覆盖状态栏 duration ms，到点还原 last_status
---@param ctx VVReplaceCtx
---@param text string
---@param duration? integer  默认 1500ms
function M.flash_status(ctx, text, duration)
  M._paint_status(ctx, text, 'VVReplaceToast')
  duration = duration or 1500
  if ctx.state.flash_timer then
    pcall(function() ctx.state.flash_timer:stop(); ctx.state.flash_timer:close() end)
  end
  local t = vim.uv.new_timer()
  ctx.state.flash_timer = t
  if not t then return end
  t:start(duration, 0, vim.schedule_wrap(function()
    if ctx.state.closed then return end
    local last = ctx.state.last_status
    if last then
      M._paint_status(ctx, last.text, last.is_error and 'VVReplaceStatusError' or 'VVReplaceStatus')
    else
      M._paint_status(ctx, '', nil)
    end
  end))
end

---@param ctx VVReplaceCtx
---@param text string
---@param hl_group string?
function M._paint_status(ctx, text, hl_group)
  local buf = ctx.buf
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local header_row = get_header_row(ctx)
  if ctx.extmark_ids.status then
    pcall(vim.api.nvim_buf_del_extmark, buf, ctx.namespace, ctx.extmark_ids.status)
    ctx.extmark_ids.status = nil
  end
  if text == '' then return end
  ctx.extmark_ids.status = vim.api.nvim_buf_set_extmark(buf, ctx.namespace, header_row, 0, {
    virt_text = { { '── ' .. text .. ' ──', hl_group or 'VVReplaceStatus' } },
    virt_text_pos = 'overlay',
    right_gravity = false,
  })
end

-- 获取 cursor 所在结果行的 mark（供跳转 action 用）
---@param ctx VVReplaceCtx
---@return VVReplaceResultMark?
function M.mark_at_cursor(ctx)
  local row = vim.api.nvim_win_get_cursor(ctx.win)[1] - 1
  return ctx.state.result_marks[row]
end

return M
