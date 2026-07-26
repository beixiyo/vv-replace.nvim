-- Include、Exclude 与 Cwd 字段的路径补全

local Model = require('vv-replace.inputs.model')
local PathCompletion = require('vv-utils.path_completion')

local M = {}

---@param path string
---@return boolean
local function is_absolute_path(path)
  return path:sub(1, 1) == '/'
    or path:match('^%a:[/\\]') ~= nil
    or path:match('^[/\\][/\\]') ~= nil
end

---@param ctx VVReplaceCtx
---@return string
local function effective_cwd(ctx)
  local value = Model.get_value(ctx, 'cwd')
  if value == '' then return ctx.cwd end

  value = vim.fn.expand(value)
  if not is_absolute_path(value) then value = vim.fs.joinpath(ctx.cwd, value) end
  return vim.fs.normalize(value)
end

---生成 Include / Exclude / Cwd 当前字段的路径候选
---@param ctx VVReplaceCtx
---@param row integer 0-based
---@param line string
---@param cursor_col integer 0-based byte offset
---@return vv-utils.path_completion.Result?
function M.get(ctx, row, line, cursor_col)
  local name = Model.field_at_row(ctx, row)
  if name ~= 'include' and name ~= 'exclude' and name ~= 'cwd' then return nil end

  return name == 'cwd'
    and PathCompletion.directory(line, { cwd = ctx.cwd, cursor = cursor_col })
    or PathCompletion.glob(line, { cwd = effective_cwd(ctx), cursor = cursor_col })
end

return M
