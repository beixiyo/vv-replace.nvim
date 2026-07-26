-- 输入字段声明与 scope 过滤

local View = require('vv-replace.inputs.view')

local M = {}

---@class VVReplaceField
---@field name string
---@field label string
---@field placeholder string
---@field scopes table<string, true>  哪些 scope 下可见（'file' / 'project'）
---@field notrim? boolean  取值时不做 vim.trim，保留首尾空白（replace 内容字段需要）
---@field render_label fun(ctx: VVReplaceCtx, field: VVReplaceField): table[]

---@type VVReplaceField[]
M.ALL = {
  {
    name = 'search',
    label = 'Search',
    placeholder = 'Search pattern...',
    scopes = { file = true, project = true },
    render_label = View.search_label,
  },
  {
    name = 'replace',
    label = 'Replace',
    placeholder = 'Replace (empty = delete matches)',
    scopes = { file = true, project = true },
    notrim = true,
    render_label = View.replace_label,
  },
  {
    name = 'include',
    label = 'Include',
    placeholder = 'e.g. *.lua, core/src, ./src',
    scopes = { project = true },
    render_label = View.completion_label,
  },
  {
    name = 'exclude',
    label = 'Exclude',
    placeholder = 'e.g. *.log, test, ./generated',
    scopes = { project = true },
    render_label = View.completion_label,
  },
  {
    name = 'cwd',
    label = 'Cwd',
    placeholder = 'default: current cwd',
    scopes = { project = true },
    render_label = View.completion_label,
  },
}

---@param ctx VVReplaceCtx
---@return VVReplaceField[]
function M.visible(ctx)
  local list = {}
  for _, field in ipairs(M.ALL) do
    if field.scopes[ctx.scope] then list[#list + 1] = field end
  end
  return list
end

---@param ctx VVReplaceCtx
---@return integer
function M.results_header_row(ctx)
  return #M.visible(ctx)
end

return M
