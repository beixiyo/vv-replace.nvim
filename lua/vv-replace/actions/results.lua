-- 结果区的光标移动与按文件折叠
--
-- 只作用于 header_row 之下的结果区；输入区和 header 行之上的按键由调用方回落到原生行为
-- 可停留行：匹配行 + 已折叠的文件行（语义同 vv-utils.tree_panel 的 navigable = 'folded'）
--   * 展开的文件行只是分组标签，j/k 跳过
--   * 折叠后文件行是该组唯一可见行，必须可停留，否则无法再展开

local Render = require('vv-replace.render')

local M = {}

---@param mark VVReplaceResultMark
---@return boolean
local function is_navigable(mark)
  return mark.kind == 'match' or (mark.kind == 'file' and mark.folded == true)
end

---@param ctx VVReplaceCtx
---@return integer[] rows  升序 0-based buffer row
local function navigable_rows(ctx)
  local rows = {}
  for row, mark in pairs(ctx.state.result_marks or {}) do
    if is_navigable(mark) then rows[#rows + 1] = row end
  end
  table.sort(rows)
  return rows
end

---@param ctx VVReplaceCtx
---@return integer? row  光标所在 0-based 行；面板窗口失效时 nil
local function cursor_row(ctx)
  if not vim.api.nvim_win_is_valid(ctx.win) then return nil end
  return vim.api.nvim_win_get_cursor(ctx.win)[1] - 1
end

---@param ctx VVReplaceCtx
---@param filename string
---@return integer?
local function file_row(ctx, filename)
  return Render.find_row(ctx, function(mark)
    return mark.kind == 'file' and mark.filename == filename
  end)
end

-- j/k：在可停留行之间移动 count 步，跳过展开的文件行
-- header 行上向下进入第一个结果；结果区顶部再向上越过状态行回到最后一个输入框
---@param ctx VVReplaceCtx
---@param direction 1|-1
---@param count? integer @default 1
---@return boolean handled  false 表示光标不在结果区，调用方执行原生按键
function M.move(ctx, direction, count)
  local row = cursor_row(ctx)
  if not row then return false end

  local header_row = Render.header_row(ctx)
  if row < header_row or (row == header_row and direction < 0) then return false end

  local rows = navigable_rows(ctx)
  local target = row
  for _ = 1, math.max(count or 1, 1) do
    local next_row
    if direction > 0 then
      for _, candidate in ipairs(rows) do
        if candidate > target then
          next_row = candidate
          break
        end
      end
    else
      for index = #rows, 1, -1 do
        if rows[index] < target then
          next_row = rows[index]
          break
        end
      end
    end
    if not next_row then break end
    target = next_row
  end

  local col = vim.api.nvim_win_get_cursor(ctx.win)[2]
  if target ~= row then
    pcall(vim.api.nvim_win_set_cursor, ctx.win, { target + 1, col })
  elseif direction < 0 and header_row > 0 then
    -- 上方已无可停留的结果行：状态行与文件行都没有意义，直接回到最后一个输入框
    pcall(vim.api.nvim_win_set_cursor, ctx.win, { header_row, col })
  end
  return true
end

-- h：折叠光标所在文件并把光标放到文件行；已折叠的文件行上无操作
---@param ctx VVReplaceCtx
---@return boolean handled  false 表示不在结果项上，调用方执行原生按键
function M.fold(ctx)
  local row = cursor_row(ctx)
  if not row or row <= Render.header_row(ctx) then return false end

  local mark = ctx.state.result_marks[row]
  if not mark then return false end
  if mark.kind == 'file' and mark.folded then return true end

  Render.set_folded(ctx, mark.filename, true)
  local target = file_row(ctx, mark.filename)
  if target then pcall(vim.api.nvim_win_set_cursor, ctx.win, { target + 1, 0 }) end
  return true
end

-- l：展开折叠的文件行并进入第一个匹配；其它行返回 false 保留原生 l
---@param ctx VVReplaceCtx
---@return boolean handled
function M.unfold(ctx)
  local row = cursor_row(ctx)
  if not row or row <= Render.header_row(ctx) then return false end

  local mark = ctx.state.result_marks[row]
  if not mark or mark.kind ~= 'file' or not mark.folded then return false end

  local filename = mark.filename
  Render.set_folded(ctx, filename, false)

  local header = file_row(ctx, filename)
  if not header then return true end
  local first = ctx.state.result_marks[header + 1]
  local target = (first and first.kind == 'match' and first.filename == filename) and header + 1 or header
  pcall(vim.api.nvim_win_set_cursor, ctx.win, { target + 1, 0 })
  return true
end

return M
