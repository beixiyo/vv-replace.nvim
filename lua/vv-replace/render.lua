-- 结果渲染：rg json 解析 + 按折叠状态和窗口宽度排版 + buffer 写入 + 高亮
--
-- 结构约定：
--   header_row（由 results_header extmark 定位）上方是输入区，下方是结果区
--   结果区布局：
--     row header     → 空行，virt_text 显示状态（"N 个匹配 / M 个文件"）
--     row header + 1 → <chevron> <目录/><文件名>  (N)   ← 路径按窗口可用宽度逐级压缩
--     row header + 2 →   <lnum>  <匹配行文本>  ← 单行 inline diff（匹配标红 + 替换绿色 virt_text）
--     row header + 3 → <下个文件> ...（文件组之间不留空行，chevron 已足够分隔）
--   折叠的文件只渲染文件行，匹配行不进 buffer
--
-- 数据分两层：
--   parse_results 把 rg json 解析成与布局无关的文件分组（ctx.state.result_files）
--   layout 按折叠集合与可用宽度排出行、行号 → mark 映射、高亮与 inline diff
--   折叠 / 窗口宽度变化只需 relayout，不重跑 rg；替换写回只读 last_json，不依赖 buffer 行

local Loading = require('vv-utils.loading')
local Path = require('vv-utils.path')

local M = {}

local DEFAULT_FOLD_OPEN = ''
local DEFAULT_FOLD_CLOSED = ''

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

M.header_row = get_header_row

---@param path string
---@return boolean
local function is_absolute_path(path)
  return path:sub(1, 1) == '/'
    or path:match('^%a:[/\\]') ~= nil
    or path:match('^[/\\][/\\]') ~= nil
end

-- 把一条 rg match 解析成布局无关的匹配项；高亮与 inline 列号相对匹配行文本
---@param obj any
---@param filename string
---@param has_replace boolean
---@return VVReplaceMatchItem
local function parse_match(obj, filename, has_replace)
  local data = obj.data
  local submatches = data.submatches or {}

  local raw_text = data.lines and (data.lines.text or '') or ''
  raw_text = raw_text:gsub('\r?\n$', '')
  local first_line = raw_text:match('([^\n]*)') or ''

  local item = {
    kind = 'match',
    filename = filename,
    lnum = data.line_number or 0,
    col = (submatches[1] and submatches[1].start + 1) or 1,
    text = first_line,
    submatches = submatches,
    highlights = {},
    inlines = {},
  }

  for _, sub in ipairs(submatches) do
    local s = sub.start
    local e = sub['end']
    if s and e and s < #first_line then
      item.highlights[#item.highlights + 1] = {
        col_start = s,
        col_end = math.min(e, #first_line),
        hl_group = has_replace and 'VVReplaceMatchRemoved' or 'VVReplaceMatch',
      }

      -- 有替换时：inline virtual text 紧跟匹配末尾
      if has_replace and sub.replacement then
        local rep = (sub.replacement.text or ''):match('([^\n]*)') or ''
        if rep ~= '' then
          item.inlines[#item.inlines + 1] = {
            col = math.min(e, #first_line),
            text = rep,
            hl_group = 'VVReplaceMatchAdded',
          }
        end
      end
    end
  end

  return item
end

-- 按折叠集合与可用宽度把文件分组排成 buffer 行
-- row 均为结果区内 0-based 偏移（写入时再加 header_row + 1）
---@param files VVReplaceFileGroup[]
---@param opts? VVReplaceLayoutOpts
---@return VVReplaceParsed
function M.layout(files, opts)
  opts = opts or {}
  local folded_files = opts.folded or {}
  local icons = opts.icons or {}
  local lines = {}
  local marks = {}
  local highlights = {}
  local inlines = {}

  for index, file in ipairs(files) do
    local folded = folded_files[file.filename] == true
    local count = #file.matches
    local glyph
    if folded then
      glyph = icons.fold_closed or DEFAULT_FOLD_CLOSED
    else
      glyph = icons.fold_open or DEFAULT_FOLD_OPEN
    end
    local chevron = glyph .. ' '
    -- 路径可用列 = 窗口文本区 - chevron - eol 计数 virt_text - 1 列余量
    local available = opts.width
      and (opts.width - vim.fn.strdisplaywidth(chevron) - vim.fn.strdisplaywidth(M.count_text(count)) - 1)
    local shown = Path.collapse_middle(file.display_path, { head = 1, tail = 3, max_width = available })
    local dir = shown:match('^(.*[/\\])') or ''

    local file_row = #lines
    lines[#lines + 1] = chevron .. shown
    marks[#marks + 1] = {
      row = file_row,
      kind = 'file',
      filename = file.filename,
      folded = folded,
      count = count,
    }
    highlights[#highlights + 1] = {
      row = file_row,
      col_start = 0,
      col_end = #chevron,
      hl_group = 'VVReplaceFoldIcon',
    }
    if dir ~= '' then
      highlights[#highlights + 1] = {
        row = file_row,
        col_start = #chevron,
        col_end = #chevron + #dir,
        hl_group = 'VVReplaceFileDir',
      }
    end
    highlights[#highlights + 1] = {
      row = file_row,
      col_start = #chevron + #dir,
      col_end = #chevron + #shown,
      hl_group = 'VVReplaceFilePath',
    }

    if not folded then
      for _, item in ipairs(file.matches) do
        local prefix = string.format('  %d  ', item.lnum)
        local row = #lines
        lines[#lines + 1] = prefix .. item.text

        marks[#marks + 1] = {
          row = row,
          kind = 'match',
          filename = item.filename,
          lnum = item.lnum,
          col = item.col,
          text = item.text,
          submatches = item.submatches,
        }
        highlights[#highlights + 1] = {
          row = row,
          col_start = 0,
          col_end = #prefix,
          hl_group = 'VVReplaceLineNumber',
        }
        for _, hl in ipairs(item.highlights) do
          highlights[#highlights + 1] = {
            row = row,
            col_start = #prefix + hl.col_start,
            col_end = #prefix + hl.col_end,
            hl_group = hl.hl_group,
          }
        end
        for _, il in ipairs(item.inlines) do
          inlines[#inlines + 1] = {
            row = row,
            col = #prefix + il.col,
            text = il.text,
            hl_group = il.hl_group,
          }
        end
      end
    end
  end

  return { files = files, lines = lines, marks = marks, highlights = highlights, inlines = inlines }
end

-- 文件行 eol 的匹配计数文本；layout 扣宽度与 render 绘制共用，保证两边一致
---@param count integer
---@return string
function M.count_text(count)
  return '  (' .. count .. ')'
end

-- 根据 rg 的 --json 流结果生成文件分组，并按 opts 排出一份默认布局
---@param json_matches any[]  rg NDJSON 解析后对象数组
---@param has_replace boolean
---@param opts? VVReplaceParseOpts
---@return VVReplaceParsed
function M.parse_results(json_matches, has_replace, opts)
  opts = opts or {}
  ---@type VVReplaceFileGroup[]
  local files = {}
  local stats = { files = 0, matches = 0 }
  local current = nil

  for _, obj in ipairs(json_matches) do
    if obj.type == 'begin' then
      stats.files = stats.files + 1
      local filename = obj.data.path.text or obj.data.path.bytes or '?'
      if opts.root and not is_absolute_path(filename) then
        filename = vim.fs.joinpath(opts.root, filename)
      end
      filename = vim.fs.normalize(filename)

      local display_path = opts.root and vim.fs.relpath(opts.root, filename) or nil
      current = {
        filename = filename,
        display_path = display_path or filename,
        matches = {},
      }
      files[#files + 1] = current

    elseif obj.type == 'match' and current then
      stats.matches = stats.matches + #(obj.data.submatches or {})
      current.matches[#current.matches + 1] = parse_match(obj, current.filename, has_replace)
    end
  end

  local parsed = M.layout(files, opts)
  parsed.stats = stats
  return parsed
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
  ctx.state.result_files = {}
  ctx.state.result_matches = {}
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

-- 结果窗口文本区宽度（扣除 number / sign 等列）；窗口无效时不压缩
---@param ctx VVReplaceCtx
---@return integer?
local function text_width(ctx)
  if not vim.api.nvim_win_is_valid(ctx.win) then return nil end
  local info = vim.fn.getwininfo(ctx.win)[1]
  if not info then return nil end
  return info.width - info.textoff
end

-- 按 ctx 的折叠集合与当前宽度重排 result_files 并整体重写结果区
-- 状态行 extmark 由 render_status 负责，这里只在 header 行之下写入
---@param ctx VVReplaceCtx
local function paint(ctx)
  local buf = ctx.buf
  local was_modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true

  -- 只删结果区 extmark，保留状态行 virt_text（折叠 / resize 不应抹掉 "N matches" 状态）
  for _, id in ipairs(ctx.state.result_extmark_ids or {}) do
    pcall(vim.api.nvim_buf_del_extmark, buf, ctx.namespace, id)
  end
  ctx.state.result_extmark_ids = {}

  local width = text_width(ctx)
  ctx.state.layout_width = width
  local layout = M.layout(ctx.state.result_files or {}, {
    width = width,
    folded = ctx.state.folded_files,
    icons = ctx.config and ctx.config.icons,
  })

  local header_row = get_header_row(ctx)
  local line_count = vim.api.nvim_buf_line_count(buf)
  if line_count <= header_row then
    vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, { '' })
    line_count = line_count + 1
  end

  -- header 行（空占位，靠状态 virt_text 装饰）保持不动，其下整体替换为结果
  vim.api.nvim_buf_set_lines(buf, header_row + 1, line_count, false, layout.lines)

  local ids = ctx.state.result_extmark_ids

  -- 应用高亮
  for _, hl in ipairs(layout.highlights) do
    ids[#ids + 1] = vim.api.nvim_buf_set_extmark(buf, ctx.namespace, header_row + 1 + hl.row, hl.col_start, {
      end_col = hl.col_end,
      hl_group = hl.hl_group,
    })
  end

  -- 应用 inline virtual text（替换预览）
  for _, il in ipairs(layout.inlines) do
    ids[#ids + 1] = vim.api.nvim_buf_set_extmark(buf, ctx.namespace, header_row + 1 + il.row, il.col, {
      virt_text = { { il.text, il.hl_group } },
      virt_text_pos = 'inline',
    })
  end

  -- 保存 marks 映射（行号要加上 header_row + 1 偏移）；文件行附 "(N)" 匹配数
  ctx.state.result_marks = {}
  for _, mark in ipairs(layout.marks) do
    local buf_row = header_row + 1 + mark.row
    mark.row = buf_row
    ctx.state.result_marks[buf_row] = mark

    if mark.kind == 'file' then
      ids[#ids + 1] = vim.api.nvim_buf_set_extmark(buf, ctx.namespace, buf_row, 0, {
        virt_text = { { M.count_text(mark.count or 0), 'VVReplaceFileCount' } },
        virt_text_pos = 'eol',
      })
    end
  end

  vim.bo[buf].modifiable = was_modifiable
end

---@param ctx VVReplaceCtx
---@param parsed VVReplaceParsed
function M.render_results(ctx, parsed)
  clear_results_extmarks(ctx)

  local files = parsed.files or {}
  ctx.state.result_files = files

  -- 全部匹配（含折叠文件里不渲染的）供源窗口预览 diff 使用
  local matches = {}
  local present = {}
  for _, file in ipairs(files) do
    present[file.filename] = true
    for _, item in ipairs(file.matches) do matches[#matches + 1] = item end
  end
  ctx.state.result_matches = matches

  -- 折叠按文件路径保留：仍在新结果里的文件保持折叠，消失的文件丢弃
  local folded = {}
  for filename in pairs(ctx.state.folded_files or {}) do
    if present[filename] then folded[filename] = true end
  end
  ctx.state.folded_files = folded

  paint(ctx)
end

-- 不重跑搜索，按当前折叠集合与窗口宽度重排结果区；光标留在原来的结果项上
---@param ctx VVReplaceCtx
function M.relayout(ctx)
  if ctx.state.closed or not vim.api.nvim_buf_is_valid(ctx.buf) then return end

  local cursor
  local anchor
  if vim.api.nvim_win_is_valid(ctx.win) then
    cursor = vim.api.nvim_win_get_cursor(ctx.win)
    anchor = ctx.state.result_marks[cursor[1] - 1]
  end

  paint(ctx)

  if not anchor then return end
  local target = M.find_row(ctx, function(mark)
    return mark.kind == anchor.kind and mark.filename == anchor.filename and mark.lnum == anchor.lnum
  end) or M.find_row(ctx, function(mark)
    return mark.kind == 'file' and mark.filename == anchor.filename
  end)
  if target then pcall(vim.api.nvim_win_set_cursor, ctx.win, { target + 1, cursor[2] }) end
end

-- 窗口宽度变化时重排；宽度未变（如别的窗口 resize）直接跳过
---@param ctx VVReplaceCtx
function M.on_resize(ctx)
  if not ctx.state.result_files or #ctx.state.result_files == 0 then return end
  if text_width(ctx) == ctx.state.layout_width then return end
  M.relayout(ctx)
end

-- 设置某文件的折叠状态并重排；状态未变时不重写 buffer
---@param ctx VVReplaceCtx
---@param filename string
---@param folded boolean
function M.set_folded(ctx, filename, folded)
  ctx.state.folded_files = ctx.state.folded_files or {}
  if (ctx.state.folded_files[filename] == true) == folded then return end

  ctx.state.folded_files[filename] = folded or nil
  paint(ctx)
end

-- 按行号升序找第一个满足条件的结果行（0-based buffer row）
---@param ctx VVReplaceCtx
---@param predicate fun(mark: VVReplaceResultMark): boolean
---@return integer?
function M.find_row(ctx, predicate)
  local found
  for row, mark in pairs(ctx.state.result_marks or {}) do
    if (not found or row < found) and predicate(mark) then found = row end
  end
  return found
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
    local is_current = ctx.state.flash_timer == t
    -- 一次性 timer 触发后自行关闭，避免 handle 泄漏
    pcall(function() t:stop(); t:close() end)
    if is_current then ctx.state.flash_timer = nil end
    if ctx.state.closed then return end
    -- 已被新的 flash 取代时，新 toast 正在显示，不应被旧的 last_status 覆盖
    if not is_current then return end
    local last = ctx.state.last_status
    if last then
      M._paint_status(ctx, last.text, last.is_error and 'VVReplaceStatusError' or 'VVReplaceStatus')
    else
      M._paint_status(ctx, '', nil)
    end
  end))
end

-- header 行的共享 loading：搜索与替换各自 acquire 同一个 slot，引用计数归零才撤帧，
-- 文案取最近一次仍在途的请求；与状态文案共用同一 overlay 落点，故 slot 忙时状态只记录不绘制，
-- 帧撤掉后还原 last_status。150ms 内结束的请求不画帧，避免快速搜索 / 小批量替换闪一下
---@param ctx VVReplaceCtx
---@return vv-utils.loading.Slot
local function loading_slot(ctx)
  local slot = ctx.state.loading_slot
  if slot then return slot end

  slot = Loading.slot(function()
    local handle = Loading.mark({
      buf = ctx.buf,
      get_pos = function() return { row = get_header_row(ctx) + 1, col = 0 } end,
      pos = 'overlay',
      delay_ms = 150,
    })
    handle:on_stop(function()
      if ctx.state.loading_slot:is_busy() then return end
      local last = ctx.state.last_status
      if last then
        M._paint_status(ctx, last.text, last.is_error and 'VVReplaceStatusError' or 'VVReplaceStatus')
      end
    end)
    return handle
  end)
  ctx.state.loading_slot = slot
  return slot
end

-- 登记一个在途请求，在 header 行显示帧 + label；返回的 release 幂等
-- set_label 先登记新文案再释放旧登记，计数不归零，帧不会中断
---@param ctx VVReplaceCtx
---@param label string
---@return VVReplaceLoadingToken
function M.acquire_loading(ctx, label)
  -- 面板已关闭：没有可画的位置，返回空登记，调用方无需区分
  if ctx.state.closed or not vim.api.nvim_buf_is_valid(ctx.buf) then
    return { set_label = function() end, release = function() end }
  end

  local slot = loading_slot(ctx)
  local release = slot:acquire(label)
  M._paint_status(ctx, '', nil)

  local released = false
  return {
    set_label = function(next_label)
      if released or ctx.state.closed or not vim.api.nvim_buf_is_valid(ctx.buf) then return end
      local previous = release
      release = slot:acquire(next_label)
      previous()
    end,
    release = function()
      if released then return end
      released = true
      release()
    end,
  }
end

---@param ctx VVReplaceCtx
---@return boolean
function M.is_loading(ctx)
  return ctx.state.loading_slot ~= nil and ctx.state.loading_slot:is_busy()
end

-- 面板关闭时释放全部登记，幂等
---@param ctx VVReplaceCtx
function M.dispose_loading(ctx)
  if ctx.state.loading_slot then ctx.state.loading_slot:dispose() end
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

  if text == '' or M.is_loading(ctx) then return end
  ctx.extmark_ids.status = vim.api.nvim_buf_set_extmark(buf, ctx.namespace, header_row, 0, {
    virt_text = { { '── ' .. text:gsub('[\r\n]+', ' ') .. ' ──', hl_group or 'VVReplaceStatus' } },
    virt_text_pos = 'overlay',
    right_gravity = false,
  })
end

-- 获取 cursor 所在结果行的 mark（供跳转 action 用）
---@param ctx VVReplaceCtx
---@return VVReplaceResultMark?
function M.mark_at_cursor(ctx)
  local win = ctx.win
  if not vim.api.nvim_win_is_valid(win) then
    -- ctx.win 已失效（如原窗口被关、buffer 在别处 split 存活）：退回当前窗口（须显示同 buffer），否则安全返回 nil
    win = vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= ctx.buf then
      return nil
    end
  end
  local row = vim.api.nvim_win_get_cursor(win)[1] - 1
  return ctx.state.result_marks[row]
end

return M

---@class VVReplaceLoadingToken
---@field set_label fun(label: string)  更新本请求的文案（本请求不是最新登记时会被提到最前）
---@field release fun()  释放本请求，幂等
