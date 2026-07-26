-- 输入字段历史状态与导航

local Fields = require('vv-replace.inputs.fields')
local History = require('vv-utils.history')
local Model = require('vv-replace.inputs.model')

local M = {}

---@type vv-utils.history.History?
local history
local history_persist = false

---@return vv-utils.history.History
local function get_history()
  if not history then
    history = History.new({ name = 'vv-replace' })
    history_persist = false
  end
  return history
end

---配置当前插件使用的通用历史实例
---@param opts { persist: boolean }
function M.setup(opts)
  if history and history_persist == opts.persist then return end

  history = History.new({
    name = 'vv-replace',
    max_entries = 50,
    persist = opts.persist,
  })
  history_persist = opts.persist
end

---记录当前光标所在输入框的值
---@param ctx VVReplaceCtx
function M.record_current(ctx)
  local row = vim.api.nvim_win_get_cursor(ctx.win)[1] - 1
  local name = Model.field_at_row(ctx, row)
  local value = name and Model.get_value(ctx, name) or ''
  if name then get_history():record(name, value) end
end

---记录全部可见输入框，供关闭面板时跨会话回溯
---@param ctx VVReplaceCtx
function M.record_all(ctx)
  local records = {}
  for _, field in ipairs(Fields.visible(ctx)) do
    records[#records + 1] = {
      field = field.name,
      value = Model.get_value(ctx, field.name),
    }
  end
  get_history():record_many(records)
end

---在当前输入框浏览历史。光标不在输入框时返回 false，让调用方保留原按键行为
---@param ctx VVReplaceCtx
---@param direction 1|-1
---@return boolean handled
function M.navigate(ctx, direction)
  local row = vim.api.nvim_win_get_cursor(ctx.win)[1] - 1
  local name = Model.field_at_row(ctx, row)
  if not name then return false end

  local current = Model.get_value(ctx, name)
  local value = direction < 0
    and get_history():previous(name, current)
    or get_history():next(name, current)
  if value == nil then return true end

  local line = vim.api.nvim_buf_get_lines(ctx.buf, row, row + 1, false)[1] or ''
  vim.bo[ctx.buf].modifiable = true
  vim.api.nvim_buf_set_text(ctx.buf, row, 0, row, #line, { value })
  pcall(vim.api.nvim_win_set_cursor, ctx.win, { row + 1, #value })

  return true
end

return M
