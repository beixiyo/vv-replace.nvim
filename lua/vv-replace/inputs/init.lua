-- 输入区公开接口与模块组合

local Completion = require('vv-replace.inputs.completion')
local Fields = require('vv-replace.inputs.fields')
local History = require('vv-replace.inputs.history')
local Model = require('vv-replace.inputs.model')
local View = require('vv-replace.inputs.view')

local M = {
  FIELDS = Fields.ALL,
  clear_current = Model.clear_current,
  field_at_row = Model.field_at_row,
  fill = Model.fill,
  get_value = Model.get_value,
  get_values = Model.get_values,
  goto_field = Model.goto_field,
  mode_display = View.mode_display,
  navigate_history = History.navigate,
  path_completion = Completion.get,
  record_all = History.record_all,
  record_current = History.record_current,
  results_header_row = Fields.results_header_row,
  setup_history = History.setup,
  visible_fields = Fields.visible,
}

---@param ctx VVReplaceCtx
function M.render(ctx)
  View.render(ctx, Fields.visible(ctx), Fields.ALL)
end

-- Tab 循环切换：当前在字段 i → 跳到 i+1（末尾回 1）。光标不在任何字段时跳 search
---@param ctx VVReplaceCtx
---@param direction 1|-1
function M.goto_sibling(ctx, direction)
  local fields = Fields.visible(ctx)
  local cursor_row = vim.api.nvim_win_get_cursor(ctx.win)[1] - 1
  local current_name = Model.field_at_row(ctx, cursor_row)
  local idx = 1

  if current_name then
    History.record_current(ctx)
    for i, field in ipairs(fields) do
      if field.name == current_name then
        idx = i
        break
      end
    end
    idx = ((idx - 1 + direction) % #fields) + 1
  end

  Model.goto_field(ctx, fields[idx].name)
end

-- Shift-Tab（normal）切换模式；insert 模式下走 toggle_mode（由 actions 分派）
---@param ctx VVReplaceCtx
function M.toggle_mode(ctx)
  ctx.mode = ctx.mode == 'plainText' and 'regex' or 'plainText'
  M.render(ctx)
end

-- 切换是否搜索隐藏文件（重渲染 Search 徽章）
---@param ctx VVReplaceCtx
function M.toggle_hidden(ctx)
  ctx.show_hidden = not ctx.show_hidden
  M.render(ctx)
end

-- 切换是否搜索 .gitignore 忽略文件（重渲染 Search 徽章）
---@param ctx VVReplaceCtx
function M.toggle_gitignored(ctx)
  ctx.show_ignored = not ctx.show_ignored
  M.render(ctx)
end

return M
