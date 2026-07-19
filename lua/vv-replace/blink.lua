-- blink.cmp 集成
--
-- 路径字段使用 vv-utils 的搜索 glob / 目录候选，Search 与 Replace 则由
-- dotfiles 中单独配置的 buffer provider 读取已加载的普通文件 buffer

local M = {}

---@return VVReplaceCtx?
local function current_ctx()
  local ctx = require('vv-replace.buffer').current
  if not ctx or ctx.state.closed or not vim.api.nvim_buf_is_valid(ctx.buf) then return nil end
  if vim.api.nvim_get_current_buf() ~= ctx.buf then return nil end
  return ctx
end

---@return VVReplaceCtx?, string?
local function current_field()
  local ctx = current_ctx()
  if not ctx then return nil, nil end

  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  return ctx, require('vv-replace.inputs').field_at_row(ctx, row)
end

---@return boolean
function M.is_path_input()
  local _, field = current_field()
  return field == 'include' or field == 'exclude' or field == 'cwd'
end

---@return boolean
function M.is_text_input()
  local _, field = current_field()
  return field == 'search' or field == 'replace'
end

---返回曾打开且仍加载的普通文件 buffer，不把 vv-replace 面板自身混入词库
---@return integer[]
function M.get_bufnrs()
  local bufs = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf)
      and vim.bo[buf].buflisted
      and vim.bo[buf].buftype == ''
      and vim.api.nvim_buf_get_name(buf) ~= ''
    then
      bufs[#bufs + 1] = buf
    end
  end
  return bufs
end

---@return vv-replace.BlinkSource
function M.new()
  return setmetatable({}, { __index = M })
end

---@return boolean
function M:enabled()
  return M.is_path_input()
end

---@return string[]
function M:get_trigger_characters()
  return { '/', '.', ',', '!', '\\' }
end

---@param context blink.cmp.Context
---@param callback fun(response: blink.cmp.CompletionResponse)
function M:get_completions(context, callback)
  local ctx = current_ctx()
  local row = context.cursor[1] - 1
  if not ctx then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return
  end

  local result = require('vv-replace.inputs').path_completion(ctx, row, context.line, context.cursor[2])
  if not result then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return
  end

  local kinds = require('blink.cmp.types').CompletionItemKind
  local plain_text = vim.lsp.protocol.InsertTextFormat.PlainText
  local items = {}

  for _, candidate in ipairs(result.items) do
    local directory = candidate.kind == 'Folder'

    items[#items + 1] = {
      label = candidate.abbr or candidate.word,
      filterText = candidate.word,
      kind = directory and kinds.Folder or kinds.File,
      sortText = (directory and '0' or '1') .. candidate.word,
      insertTextFormat = plain_text,
      textEdit = {
        newText = candidate.word,
        range = {
          start = { line = row, character = result.start_col },
          ['end'] = { line = row, character = context.cursor[2] },
        },
      },
    }
  end

  callback({
    items = items,
    is_incomplete_forward = true,
    is_incomplete_backward = true,
  })
end

---@class vv-replace.BlinkSource : blink.cmp.Source

return M
