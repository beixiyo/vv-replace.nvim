-- 替换事务状态

local transaction = require('vv-utils.fs').new_transaction()

local M = {}

---@param entries vv-utils.fs.TransactionEntry[]
---@return boolean ok
---@return string? error
---@return boolean? touched
function M.apply(entries)
  return transaction:apply(entries)
end

---@return boolean ok
---@return string? error
---@return integer? count
---@return boolean? touched
function M.undo()
  return transaction:undo()
end

---@return boolean
function M.can_undo()
  return transaction:can_undo()
end

return M
