-- 动作模块公开接口与生命周期组合

local Lifecycle = require('vv-replace.actions.lifecycle')
local Mappings = require('vv-replace.actions.mappings')
local Preview = require('vv-replace.actions.preview')

local M = {
  _apply_file_diff = Preview.apply_file_diff,
  _clear_all_preview_diff = Preview.clear_all,
}

---@param ctx VVReplaceCtx
---@param opts {close:fun()}
function M.attach(ctx, opts)
  Mappings.attach(ctx, opts)
  Lifecycle.attach(ctx)
end

return M
