-- 输入区标签、winbar 与 extmark 渲染

local Input = require('vv-utils.input')
local Transaction = require('vv-replace.transaction')

local M = {}

---@param ctx VVReplaceCtx
---@param name string
---@return string?
local function key_label(ctx, name)
  local label = ctx.keymap_labels and ctx.keymap_labels[name]
  if label then return label end

  local lhs = ctx.config and ctx.config.keymaps and ctx.config.keymaps[name]
  if type(lhs) ~= 'string' or lhs == '' then return nil end
  return Input.display_key(lhs)
end

---@param text string
---@return string
local function winbar_escape(text)
  local escaped = (text:gsub('%%', '%%%%'))
  return escaped
end

---@param ctx VVReplaceCtx
---@return string
local function panel_winbar(ctx)
  local ic = ctx.config and ctx.config.icons or {}
  local title = Input.action_hint(ic.title, 'Replace') or 'Replace'
  local hints = {}

  local next_input = Input.action_hint(ic.next_input, key_label(ctx, 'next_input'), 'Field')
  if next_input then hints[#hints + 1] = next_input end

  local help = Input.action_hint(ic.help, key_label(ctx, 'help'))
  if help then hints[#hints + 1] = help end

  local close = Input.action_hint(ic.close, key_label(ctx, 'close'))
  if close then hints[#hints + 1] = close end

  return table.concat({
    '%#VVReplaceLabel# ',
    winbar_escape(title),
    '%=',
    '%#VVReplacePlaceholder#',
    winbar_escape(table.concat(hints, '  ')),
    ' ',
  })
end

---@param ctx VVReplaceCtx
---@param label string
---@param hints string[]  按信息完整度从高到低排列，窄窗口自动降级
---@return table[]
local function aligned_label(ctx, label, hints)
  local text_width = vim.api.nvim_win_get_width(ctx.win)
  local info = vim.fn.getwininfo(ctx.win)[1]
  if info then text_width = text_width - (info.textoff or 0) end

  local left = ' ' .. label
  local hint
  local gap
  for _, candidate in ipairs(hints) do
    local candidate_gap = text_width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(candidate)
    if candidate_gap >= 2 then
      hint = candidate
      gap = candidate_gap
      break
    end
  end
  if not hint or not gap then return { { left, 'VVReplaceLabel' } } end

  return {
    { left, 'VVReplaceLabel' },
    { string.rep(' ', gap), 'VVReplaceLabel' },
    { hint, 'VVReplacePlaceholder' },
  }
end

-- 模式显示：图标 + 英文标签。图标从 ctx.config.icons 注入，避免硬依赖 vv-icons
---@param ctx VVReplaceCtx
---@return table<string, string>
function M.mode_display(ctx)
  local ic = ctx.config and ctx.config.icons or {}
  return {
    plainText = (ic.plain or 'T') .. ' Plain',
    regex = (ic.regex or '.*') .. ' Regex',
  }
end

---@param value string|string[]
---@return string?
local function first_key(value)
  if type(value) == 'table' then return value[1] end
  return value
end

---@param ctx VVReplaceCtx
---@param field VVReplaceField
---@return table[]
function M.search_label(ctx, field)
  local km = ctx.config and ctx.config.keymaps or {}
  local ic = ctx.config and ctx.config.icons or {}
  local toggle_key = km.toggle_mode or '<S-Tab>'
  local toggle_hint = Input.action_hint(ic.toggle_mode, Input.display_key(toggle_key))
  local chunks = {
    { ' ' .. field.label, 'VVReplaceLabel' },
    { '    ' .. (M.mode_display(ctx)[ctx.mode] or ctx.mode), 'VVReplaceLabelMode' },
    { '  (' .. toggle_hint .. ')', 'VVReplacePlaceholder' },
  }

  if ctx.scope ~= 'file' then
    local enabled = {}
    if ctx.show_hidden then enabled[#enabled + 1] = (ic.toggle_hidden or '') .. ' hidden' end
    if ctx.show_ignored then enabled[#enabled + 1] = (ic.toggle_gitignored or '') .. ' ignored' end

    if #enabled > 0 then
      chunks[#chunks + 1] = { '    ' .. table.concat(enabled, '  '), 'VVReplaceLabelMode' }
    else
      local hidden_key = Input.display_key(first_key(km.toggle_hidden) or '.')
      local ignored_key = Input.display_key(first_key(km.toggle_gitignored) or 'I')
      chunks[#chunks + 1] = {
        '  (' .. hidden_key .. ' hidden, ' .. ignored_key .. ' ignored)',
        'VVReplacePlaceholder',
      }
    end
  end

  if ctx.target_range then
    chunks[#chunks + 1] = {
      string.format('    Lines %d-%d', ctx.target_range[1], ctx.target_range[2]),
      'VVReplaceLabelMode',
    }
  end

  return chunks
end

---@param ctx VVReplaceCtx
---@param field VVReplaceField
---@return table[]
function M.replace_label(ctx, field)
  local ic = ctx.config and ctx.config.icons or {}
  local apply = Input.action_hint(ic.replace_all, key_label(ctx, 'replace_all'), 'Apply') or 'Apply'
  local hints = { apply }

  if Transaction.can_undo() then
    local undo = Input.action_hint(ic.undo_last, key_label(ctx, 'undo_last'), 'Undo') or 'Undo'
    hints = { undo .. '  ' .. apply, undo }
  end

  return aligned_label(ctx, field.label, hints)
end

---@param ctx VVReplaceCtx
---@param field VVReplaceField
---@return table[]
function M.completion_label(ctx, field)
  return aligned_label(ctx, field.label, { 'Tab Complete' })
end

-- 渲染所有可见字段：确保 buffer 有足够行数，每个字段行用 extmark 标起始，
-- label 通过 virt_lines_above 显示，空行显示 placeholder
---@param ctx VVReplaceCtx
---@param fields VVReplaceField[]
---@param all_fields VVReplaceField[]
function M.render(ctx, fields, all_fields)
  local buf = ctx.buf
  local ns = ctx.namespace

  if vim.api.nvim_win_is_valid(ctx.win) then
    vim.wo[ctx.win].winbar = panel_winbar(ctx)
  end

  local was_modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  local line_count = vim.api.nvim_buf_line_count(buf)
  local need = #fields + 1
  if line_count < need then
    local pad = {}
    for _ = 1, need - line_count do pad[#pad + 1] = '' end
    vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, pad)
  end

  local visible_names = {}
  for _, field in ipairs(fields) do visible_names[field.name] = true end

  for _, field in ipairs(all_fields) do
    if not visible_names[field.name] then
      for _, suffix in ipairs({ '', '_ph', '_badge' }) do
        local key = field.name .. suffix
        if ctx.extmark_ids[key] then
          pcall(vim.api.nvim_buf_del_extmark, buf, ns, ctx.extmark_ids[key])
          ctx.extmark_ids[key] = nil
        end
      end
    end
  end

  for i, field in ipairs(fields) do
    local row = i - 1
    local placeholder_key = field.name .. '_ph'
    local marks = Input.render({
      buf = buf,
      namespace = ns,
      input_row = row,
      label_chunks = field.render_label(ctx, field),
      label_position = 'above',
      placeholder = { { field.placeholder, 'VVReplacePlaceholder' } },
      label_id = ctx.extmark_ids[field.name],
      placeholder_id = ctx.extmark_ids[placeholder_key],
      right_gravity = false,
    })
    ctx.extmark_ids[field.name] = marks.label_id
    ctx.extmark_ids[placeholder_key] = marks.placeholder_id

    local badge_key = field.name .. '_badge'
    if ctx.extmark_ids[badge_key] then
      pcall(vim.api.nvim_buf_del_extmark, buf, ns, ctx.extmark_ids[badge_key])
      ctx.extmark_ids[badge_key] = nil
    end
  end

  local header_row = #fields
  local ic = ctx.config and ctx.config.icons or {}
  local previous = Input.action_hint(ic.prev_match, key_label(ctx, 'prev_match'))
  local next = Input.action_hint(ic.next_match, key_label(ctx, 'next_match'))
  local open = Input.action_hint(ic.goto_match, key_label(ctx, 'goto_match'), 'Open')
  local result_hints = {}
  if previous then result_hints[#result_hints + 1] = previous end
  if next then result_hints[#result_hints + 1] = next end
  if open then result_hints[#result_hints + 1] = open end

  local result_marks = Input.render({
    buf = buf,
    namespace = ns,
    input_row = header_row,
    label_chunks = aligned_label(ctx, 'Results', {
      table.concat(result_hints, '  '),
      table.concat(vim.list_slice(result_hints, 1, 2), '  '),
    }),
    label_position = 'above',
    label_id = ctx.extmark_ids.results_header,
    right_gravity = false,
  })
  ctx.extmark_ids.results_header = result_marks.label_id
  vim.bo[buf].modifiable = was_modifiable
end

return M
