-- 源窗口预览与 diff extmark 的唯一生命周期 owner

local Bufdelete = require('vv-utils.bufdelete')
local Render = require('vv-replace.render')

local M = {}

-- 清掉所有预览过的 buffer 上残留的 diff extmark，并重置记录
---@param ctx VVReplaceCtx
function M.clear_all(ctx)
  local namespace = ctx.state.preview_ns
  if not namespace then return end

  for buf in pairs(ctx.state.preview_bufs or {}) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_clear_namespace, buf, namespace, 0, -1)
    end
  end
  ctx.state.preview_bufs = {}
end

---@param ctx VVReplaceCtx
---@param filename string
---@param namespace integer
function M.apply_file_diff(ctx, filename, namespace)
  if not vim.api.nvim_win_is_valid(ctx.prev_win) then return end

  local preview_buf = vim.api.nvim_win_get_buf(ctx.prev_win)
  if not vim.api.nvim_buf_is_valid(preview_buf) then return end

  pcall(vim.api.nvim_buf_clear_namespace, preview_buf, namespace, 0, -1)
  ctx.state.preview_bufs = ctx.state.preview_bufs or {}
  ctx.state.preview_bufs[preview_buf] = true

  -- 读全部匹配而非按行映射的 result_marks：折叠文件的匹配不渲染，但源文件预览仍要标出
  local file_marks = {}
  for _, mark in ipairs(ctx.state.result_matches or {}) do
    if mark.filename == filename and mark.submatches then
      file_marks[#file_marks + 1] = mark
    end
  end
  if #file_marks == 0 then return end

  local has_replacement = file_marks[1].submatches[1]
    and file_marks[1].submatches[1].replacement

  for _, mark in ipairs(file_marks) do
    local line = (mark.lnum or 1) - 1

    for _, submatch in ipairs(mark.submatches) do
      local start_col = submatch.start or 0
      local end_col = submatch['end'] or start_col
      local highlight = has_replacement and 'VVReplaceMatchRemoved' or 'VVReplaceMatch'

      pcall(vim.api.nvim_buf_set_extmark, preview_buf, namespace, line, start_col, {
        end_col = end_col,
        hl_group = highlight,
      })

      if submatch.replacement then
        local replacement = (submatch.replacement.text or ''):match('([^\n]*)') or ''
        if replacement ~= '' then
          pcall(vim.api.nvim_buf_set_extmark, preview_buf, namespace, line, end_col, {
            virt_text = { { replacement, 'VVReplaceMatchAdded' } },
            virt_text_pos = 'inline',
          })
        end
      end
    end
  end
end

---@param ctx VVReplaceCtx
function M.attach(ctx)
  local namespace = vim.api.nvim_create_namespace('vv-replace-preview')
  ctx.state.preview_ns = namespace

  local last_preview = {
    filename = nil,
    lnum = nil,
  }

  vim.api.nvim_create_autocmd('CursorMoved', {
    group = ctx.augroup,
    buffer = ctx.buf,
    callback = function()
      if ctx.state.closed or ctx.state.replacing then return end
      if not vim.api.nvim_win_is_valid(ctx.prev_win) then return end

      local mark = Render.mark_at_cursor(ctx)
      if not mark then
        M.clear_all(ctx)
        last_preview.filename = nil
        last_preview.lnum = nil
        return
      end

      local filename = mark.filename
      local line = mark.kind == 'file' and 1 or (mark.lnum or 1)
      if filename == last_preview.filename and line == last_preview.lnum then return end

      local file_changed = filename ~= last_preview.filename
      last_preview.filename = filename
      last_preview.lnum = line

      if file_changed then M.clear_all(ctx) end

      local displaced_buf
      vim.api.nvim_win_call(ctx.prev_win, function()
        if file_changed then
          local current_name = vim.api.nvim_buf_get_name(0)
          if vim.fs.normalize(current_name) ~= vim.fs.normalize(filename) then
            displaced_buf = vim.api.nvim_get_current_buf()
            vim.cmd('edit ' .. vim.fn.fnameescape(filename))
          end
        end

        pcall(vim.api.nvim_win_set_cursor, 0, { line, (mark.col or 1) - 1 })
        vim.cmd('normal! zz')
      end)

      if displaced_buf then
        Bufdelete.wipe_if_throwaway(displaced_buf)
      end

      if file_changed then
        M.apply_file_diff(ctx, filename, namespace)
      end
    end,
  })
end

return M
