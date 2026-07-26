-- 结果匹配导航与源文件跳转

local Bufdelete = require('vv-utils.bufdelete')
local Render = require('vv-replace.render')

local M = {}

---@param ctx VVReplaceCtx
local function focus_prev_win(ctx)
  if vim.api.nvim_win_is_valid(ctx.prev_win) then
    pcall(vim.api.nvim_set_current_win, ctx.prev_win)
  else
    pcall(vim.cmd, 'wincmd p')
  end
end

---@param filename string
local function edit_file(filename)
  local previous_buf = vim.api.nvim_get_current_buf()
  vim.cmd('edit ' .. vim.fn.fnameescape(filename))
  Bufdelete.wipe_if_throwaway(previous_buf)
end

---@param ctx VVReplaceCtx
function M.goto_under_cursor(ctx)
  local mark = Render.mark_at_cursor(ctx)
  if not mark then return end

  if mark.kind == 'file' then
    focus_prev_win(ctx)
    edit_file(mark.filename)
    return
  end
  if mark.kind ~= 'match' then return end

  focus_prev_win(ctx)
  edit_file(mark.filename)
  pcall(vim.api.nvim_win_set_cursor, 0, { mark.lnum or 1, (mark.col or 1) - 1 })
  vim.cmd('normal! zz')
end

-- 结果区是否有任意匹配行（无结果时 C-n/C-p 静默不打扰）
---@param ctx VVReplaceCtx
---@return boolean
function M.has_match(ctx)
  for _, mark in pairs(ctx.state.result_marks or {}) do
    if mark.kind == 'match' then return true end
  end
  return false
end

-- 把面板光标移到下一个（dir=1）/上一个（dir=-1）匹配行，到头回绕
-- 只移面板光标，CursorMoved autocmd 会自动预览对应源文件行
---@param ctx VVReplaceCtx
---@param direction 1|-1
function M.goto_relative(ctx, direction)
  if not vim.api.nvim_win_is_valid(ctx.win) then return end

  local rows = {}
  for row, mark in pairs(ctx.state.result_marks or {}) do
    if mark.kind == 'match' then rows[#rows + 1] = row end
  end
  if #rows == 0 then return end
  table.sort(rows)

  local current = vim.api.nvim_win_get_cursor(ctx.win)[1] - 1
  local target
  if direction > 0 then
    for _, row in ipairs(rows) do
      if row > current then
        target = row
        break
      end
    end
    target = target or rows[1]
  else
    for i = #rows, 1, -1 do
      if rows[i] < current then
        target = rows[i]
        break
      end
    end
    target = target or rows[#rows]
  end

  pcall(vim.api.nvim_win_set_cursor, ctx.win, { target + 1, 0 })
end

return M
