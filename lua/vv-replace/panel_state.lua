-- vv-replace 面板宽度的持久状态适配层
--
-- 只管理跨会话的窗口宽度。搜索输入、结果、预览和撤回仍由各自模块维护

local Timer = require('vv-utils.timer')

local M = {}

---@class VVReplacePanelState
---@field handle VVStateHandle
---@field config VVReplaceConfig
---@field width integer
---@field save_debounced fun()
---@field cancel_save fun()
---@field closed boolean
local PanelState = {}
PanelState.__index = PanelState

---@param value any
---@return boolean
local function is_valid_width(value)
  return type(value) == 'number' and value > 0 and value % 1 == 0
end

---@param handle VVStateHandle
---@param fallback integer
---@return integer
function M.load_width(handle, fallback)
  local width = handle:get('width')
  return is_valid_width(width) and width or fallback
end

---@param handle VVStateHandle
---@param config VVReplaceConfig
---@return VVReplacePanelState
function M.new(handle, config)
  local self = setmetatable({
    handle = handle,
    config = config,
    width = config.width,
    closed = false,
  }, PanelState)

  self.save_debounced, self.cancel_save = Timer.debounce(function()
    self:save()
  end, config.width_save_debounce_ms)

  return self
end

---@param win integer
function PanelState:track(win)
  if self.closed or not vim.api.nvim_win_is_valid(win) then return end

  self.width = vim.api.nvim_win_get_width(win)
  self.config.width = self.width
end

---@param win integer
function PanelState:on_resize(win)
  self:track(win)
  self.save_debounced()
end

---@return boolean
function PanelState:save()
  if not is_valid_width(self.width) then return false end
  return self.handle:set('width', self.width)
end

---@param win integer
function PanelState:close(win)
  if self.closed then return end

  self:track(win)
  self.cancel_save()
  self:save()
  self.closed = true
end

return M
