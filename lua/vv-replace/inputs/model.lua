-- 输入字段行定位、取值与写入

local Fields = require('vv-replace.inputs.fields')

local M = {}

-- 返回 field extmark 的当前行（动态获取，应对用户插入/删除行）
-- 若 extmark 失效（用户清空 buffer）返回 nil
---@param ctx VVReplaceCtx
---@param name string
---@return integer?
function M.field_row(ctx, name)
  local id = ctx.extmark_ids[name]
  if not id then return nil end

  local mark = vim.api.nvim_buf_get_extmark_by_id(ctx.buf, ctx.namespace, id, { details = true })
  if not mark or #mark == 0 then return nil end

  local row, details = mark[1], mark[3]
  if details and details.invalid then return nil end
  return row
end

-- 根据 0-based row 判断所在字段 name；非任何字段行返回 nil
---@param ctx VVReplaceCtx
---@param row integer
---@return string?
function M.field_at_row(ctx, row)
  for _, field in ipairs(Fields.visible(ctx)) do
    if M.field_row(ctx, field.name) == row then return field.name end
  end
  return nil
end

---@param ctx VVReplaceCtx
---@param name string
---@return string
function M.get_value(ctx, name)
  local row = M.field_row(ctx, name)
  if not row then return '' end

  local line = vim.api.nvim_buf_get_lines(ctx.buf, row, row + 1, false)[1] or ''
  for _, field in ipairs(Fields.ALL) do
    if field.name == name then
      if field.notrim then return line end
      break
    end
  end
  return vim.trim(line)
end

---@param ctx VVReplaceCtx
---@return table<string, string>
function M.get_values(ctx)
  local values = {}
  for _, field in ipairs(Fields.ALL) do
    values[field.name] = M.get_value(ctx, field.name)
  end
  return values
end

---清空光标所在的单行输入框，不删除 buffer 行，避免破坏表单布局
---@param ctx VVReplaceCtx
---@return boolean handled
function M.clear_current(ctx)
  if not vim.api.nvim_win_is_valid(ctx.win) then return false end

  local row = vim.api.nvim_win_get_cursor(ctx.win)[1] - 1
  if not M.field_at_row(ctx, row) then return false end

  local line = vim.api.nvim_buf_get_lines(ctx.buf, row, row + 1, false)[1] or ''
  vim.bo[ctx.buf].modifiable = true
  vim.api.nvim_buf_set_text(ctx.buf, row, 0, row, #line, { '' })
  pcall(vim.api.nvim_win_set_cursor, ctx.win, { row + 1, 0 })

  return true
end

-- 填充初始值。render 必须已调用过
-- 用 set_text 而非 set_lines：set_lines 会把同文件相邻字段的 left-gravity extmark
-- 连带 virt_lines_above 一起向上挤（Neovim 内部把 virt_line 视作 extmark 的前缀）
---@param ctx VVReplaceCtx
---@param values table<string, string>
function M.fill(ctx, values)
  vim.bo[ctx.buf].modifiable = true
  for _, field in ipairs(Fields.visible(ctx)) do
    local value = values[field.name]
    if value and value ~= '' then
      -- 输入框是单行 extmark，换行会让 nvim_buf_set_text 抛
      -- 'replacement string contains newlines'，跨行 prefill 统一压成首行
      local first_line = value:match('([^\r\n]*)') or ''
      if first_line ~= '' then
        local row = M.field_row(ctx, field.name)
        if row then
          local current = vim.api.nvim_buf_get_lines(ctx.buf, row, row + 1, false)[1] or ''
          vim.api.nvim_buf_set_text(ctx.buf, row, 0, row, #current, { first_line })
        end
      end
    end
  end
end

---@param ctx VVReplaceCtx
---@param name string
function M.goto_field(ctx, name)
  local row = M.field_row(ctx, name)
  if not row then return end

  local line = vim.api.nvim_buf_get_lines(ctx.buf, row, row + 1, false)[1] or ''
  pcall(vim.api.nvim_win_set_cursor, ctx.win, { row + 1, #line })
end

return M
