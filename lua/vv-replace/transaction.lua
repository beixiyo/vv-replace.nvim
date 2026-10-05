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

-- 分片异步写入：期间主线程可重绘 loading，开始后不可取消（必须写完或回滚）
---@param entries vv-utils.fs.TransactionEntry[]
---@param opts vv-utils.fs.TransactionAsyncOptions
function M.apply_async(entries, opts)
  transaction:apply_async(entries, opts)
end

---@param opts vv-utils.fs.TransactionUndoAsyncOptions
function M.undo_async(opts)
  transaction:undo_async(opts)
end

---@return boolean
function M.can_undo()
  return transaction:can_undo()
end

-- 替换 / 撤回正在写入（可能来自已关闭的面板）
---@return boolean
function M.is_busy()
  return transaction:is_busy()
end

return M
