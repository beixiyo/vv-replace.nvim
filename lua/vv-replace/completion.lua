-- 向补全宿主暴露当前输入字段
--
-- 候选生成由 vv-utils 路径 descriptor 或宿主已有 source 负责

local M = {}

---@return 'search'|'replace'|'include'|'exclude'|'cwd'|nil
function M.current_field()
  local ctx = require('vv-replace.buffer').current
  if not ctx or ctx.state.closed or not vim.api.nvim_buf_is_valid(ctx.buf) then return nil end
  if vim.api.nvim_get_current_buf() ~= ctx.buf then return nil end

  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  return require('vv-replace.inputs').field_at_row(ctx, row)
end

return M
