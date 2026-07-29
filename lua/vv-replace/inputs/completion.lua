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
---@param defaults? VVCompletionDefaults
---@param callback? fun(result: vv-utils.path_completion.Result)
---@return vv-utils.path_completion.Result|fun()|nil
function M.get(ctx, row, line, cursor_col, defaults, callback)
  local name = Model.field_at_row(ctx, row)
  if name ~= 'include' and name ~= 'exclude' and name ~= 'cwd' then return nil end

  local opts = {
    cwd = name == 'cwd' and ctx.cwd or effective_cwd(ctx),
    cursor = cursor_col,
    max_items = defaults and defaults.max_items,
    scan_max_items = defaults and defaults.scan_max_items,
    timeout_ms = defaults and defaults.timeout_ms,
  }

  if callback then
    if name == 'cwd' then return PathCompletion.directory_async(line, opts, callback) end
    return PathCompletion.glob_async(line, opts, callback)
  end

  return name == 'cwd'
    and PathCompletion.directory(line, opts)
    or PathCompletion.glob(line, opts)
end

return M
