-- 输入区滚动、可编辑状态与源窗口预览生命周期

local Inputs = require('vv-replace.inputs')
local Preview = require('vv-replace.actions.preview')

local M = {}

---@param ctx VVReplaceCtx
function M.attach(ctx)
  local buf = ctx.buf

  -- virt_lines_above 在 row 0 上方默认不显示，强制保留一行 topfill
  local function fix_top_virt_line()
    if ctx.state.closed or not vim.api.nvim_win_is_valid(ctx.win) then return end

    local top = vim.fn.screenpos(ctx.win, 1, 0)
    if top.row ~= 0 then
      vim.api.nvim_win_call(ctx.win, function()
        vim.fn.winrestview({ topfill = 1 })
      end)
    end
  end

  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufEnter', 'WinScrolled' }, {
    group = ctx.augroup,
    buffer = buf,
    callback = fix_top_virt_line,
  })
  vim.schedule(fix_top_virt_line)

  -- 输入区可编辑，结果区只读
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = ctx.augroup,
    buffer = buf,
    callback = function()
      if ctx.state.replacing or ctx.state.closed then return end

      local row = vim.api.nvim_win_get_cursor(ctx.win)[1] - 1
      local in_input = Inputs.field_at_row(ctx, row) ~= nil
      if vim.bo[buf].modifiable ~= in_input then
        vim.bo[buf].modifiable = in_input
      end
    end,
  })

  Preview.attach(ctx)
end

return M
