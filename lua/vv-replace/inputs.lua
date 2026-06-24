-- 输入区管理（Search / Replace / Include / Exclude / Cwd）
--
-- 设计要点：
--   * 每个字段占 1 行 buffer，label 用 virt_lines_above 显示在其上方
--     —— 这样 label 不占实际行，value 就是 extmark 那一行的文本
--   * 输入区起始用 extmark（right_gravity=false）固定左边界，
--     下一个字段 extmark 的 row 作为本字段结束
--     —— 用户删除行时 extmark.invalid=true，我们检测后重建
--   * 可见字段由 ctx.scope 决定：
--       - file 模式（<leader>sr）：Search + Replace（锁定单文件，无需 glob 筛选）
--       - project 模式（<leader>sR）：Search + Replace + Include + Exclude + Cwd 全部默认显示

local M = {}

-- 模式显示：图标 + 英文标签。图标从 ctx.config.icons 注入，避免硬依赖 vv-icons
---@param ctx VVReplaceCtx
---@return table<string, string>
function M.mode_display(ctx)
  local ic = ctx.config and ctx.config.icons or {}
  return {
    plainText = (ic.plain or 'T') .. ' Plain',
    regex     = (ic.regex or '.*') .. ' Regex',
  }
end

---@class VVReplaceField
---@field name string
---@field label string
---@field placeholder string
---@field scopes table<string, true>  哪些 scope 下可见（'file' / 'project'）
---@field notrim? boolean  取值时不做 vim.trim，保留首尾空白（replace 内容字段需要）

---@type VVReplaceField[]
M.FIELDS = {
  { name = 'search',  label = 'Search',  placeholder = 'Search pattern...',                scopes = { file = true, project = true } },
  { name = 'replace', label = 'Replace', placeholder = 'Replace (empty = delete matches)', scopes = { file = true, project = true }, notrim = true },
  { name = 'include', label = 'Include', placeholder = 'e.g. *.lua, src/**',               scopes = { project = true } },
  { name = 'exclude', label = 'Exclude', placeholder = 'e.g. *.log, test/**',              scopes = { project = true } },
  { name = 'cwd',     label = 'Cwd',     placeholder = 'default: current cwd',             scopes = { project = true } },
}

---@param ctx VVReplaceCtx
---@return VVReplaceField[]
function M.visible_fields(ctx)
  local list = {}
  for _, field in ipairs(M.FIELDS) do
    if field.scopes[ctx.scope] then list[#list + 1] = field end
  end
  return list
end

---@param ctx VVReplaceCtx
---@return integer
function M.results_header_row(ctx)
  return #M.visible_fields(ctx)
end

-- 渲染所有可见字段：确保 buffer 有足够行数，每个字段行用 extmark 标起始，
-- label 通过 virt_lines_above 显示，空行显示 placeholder
---@param ctx VVReplaceCtx
function M.render(ctx)
  local buf = ctx.buf
  local ns = ctx.namespace
  local fields = M.visible_fields(ctx)

  vim.bo[buf].modifiable = true
  local line_count = vim.api.nvim_buf_line_count(buf)
  local need = #fields + 1  -- 多一行给 results header 分隔
  if line_count < need then
    local pad = {}
    for _ = 1, need - line_count do pad[#pad + 1] = '' end
    vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, pad)
  end

  -- 记录当前所有可见字段 name，便于清理不可见字段的旧 extmark
  local visible_names = {}
  for _, f in ipairs(fields) do visible_names[f.name] = true end

  -- 先清理不属于当前 scope 的字段 extmark（scope=file 时 include/exclude/cwd）
  for _, f in ipairs(M.FIELDS) do
    if not visible_names[f.name] then
      for _, suffix in ipairs({ '', '_ph', '_badge' }) do
        local key = f.name .. suffix
        if ctx.extmark_ids[key] then
          pcall(vim.api.nvim_buf_del_extmark, buf, ns, ctx.extmark_ids[key])
          ctx.extmark_ids[key] = nil
        end
      end
    end
  end

  -- 为每个可见字段设 extmark（起始行 = index - 1）
  for i, field in ipairs(fields) do
    local row = i - 1
    local virt_lines
    if field.name == 'search' then
      -- Search 的 label 行额外带 mode 徽章（+ S-Tab 切换提示） + （可选）range 徽章 + help 提示
      -- 避开和 placeholder 的 eol 冲突
      local km = ctx.config and ctx.config.keymaps or {}
      local ic = ctx.config and ctx.config.icons or {}
      local help_key = km.help or 'g?'
      local toggle_key = km.toggle_mode or '<S-Tab>'
      local segs = {
        { ' ' .. field.label,                                    'VVReplaceLabel' },
        { '    ' .. (M.mode_display(ctx)[ctx.mode] or ctx.mode), 'VVReplaceLabelMode' },
        { '  (' .. toggle_key .. ')',                            'VVReplacePlaceholder' },
      }
      -- 搜索范围徽章（仅 project scope）：分别显示 hidden / ignored 两个开关
      -- 默认两关 → 显示提示键；已开启的项高亮列出
      if ctx.scope ~= 'file' then
        local function first_key(v) return (type(v) == 'table' and v[1]) or v end
        local on = {}
        if ctx.show_hidden then on[#on + 1] = (ic.toggle_hidden or '') .. ' hidden' end
        if ctx.show_ignored then on[#on + 1] = (ic.toggle_gitignored or '') .. ' ignored' end
        if #on > 0 then
          segs[#segs + 1] = { '    ' .. table.concat(on, '  '), 'VVReplaceLabelMode' }
        else
          local hk = first_key(km.toggle_hidden) or '.'
          local ik = first_key(km.toggle_gitignored) or 'I'
          segs[#segs + 1] = { '  (' .. hk .. ' hidden, ' .. ik .. ' ignored)', 'VVReplacePlaceholder' }
        end
      end
      if ctx.target_range then
        segs[#segs + 1] = { string.format('    Lines %d-%d', ctx.target_range[1], ctx.target_range[2]), 'VVReplaceLabelMode' }
      end
      segs[#segs + 1] = { '    ' .. help_key .. ' for help', 'VVReplacePlaceholder' }
      virt_lines = { segs }
    else
      virt_lines = { { { ' ' .. field.label, 'VVReplaceLabel' } } }
    end

    ctx.extmark_ids[field.name] = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      id = ctx.extmark_ids[field.name],
      virt_lines = virt_lines,
      virt_lines_above = true,
      right_gravity = false,
    })

    -- 清理旧版本的 eol badge extmark（留着会和新 label 重复显示）
    local badge_key = field.name .. '_badge'
    if ctx.extmark_ids[badge_key] then
      pcall(vim.api.nvim_buf_del_extmark, buf, ns, ctx.extmark_ids[badge_key])
      ctx.extmark_ids[badge_key] = nil
    end

    -- placeholder：行为空时用 overlay 显示灰色提示
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
    local ph_key = field.name .. '_ph'
    if #line == 0 then
      ctx.extmark_ids[ph_key] = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
        id = ctx.extmark_ids[ph_key],
        virt_text = { { field.placeholder, 'VVReplacePlaceholder' } },
        virt_text_pos = 'overlay',
        right_gravity = false,
      })
    elseif ctx.extmark_ids[ph_key] then
      pcall(vim.api.nvim_buf_del_extmark, buf, ns, ctx.extmark_ids[ph_key])
      ctx.extmark_ids[ph_key] = nil
    end
  end

  -- results_header extmark：可见字段最后一行之后的位置
  local header_row = #fields
  ctx.extmark_ids.results_header = vim.api.nvim_buf_set_extmark(buf, ns, header_row, 0, {
    id = ctx.extmark_ids.results_header,
    right_gravity = false,
  })
end

-- 返回 field extmark 的当前行（动态获取，应对用户插入/删除行）
-- 若 extmark 失效（用户清空 buffer）返回 nil
---@param ctx VVReplaceCtx
---@param name string
---@return integer?
local function field_row(ctx, name)
  local id = ctx.extmark_ids[name]
  if not id then return nil end
  local mark = vim.api.nvim_buf_get_extmark_by_id(ctx.buf, ctx.namespace, id, { details = true })
  if not mark or #mark == 0 then return nil end
  local row, _, details = mark[1], mark[2], mark[3]
  if details and details.invalid then return nil end
  return row
end

-- 根据 0-based row 判断所在字段 name；非任何字段行返回 nil
---@param ctx VVReplaceCtx
---@param row integer
---@return string?
function M.field_at_row(ctx, row)
  local fields = M.visible_fields(ctx)
  for _, field in ipairs(fields) do
    local r = field_row(ctx, field.name)
    if r == row then return field.name end
  end
  return nil
end

---@param ctx VVReplaceCtx
---@param name string
---@return string
function M.get_value(ctx, name)
  local row = field_row(ctx, name)
  if not row then return '' end
  local line = vim.api.nvim_buf_get_lines(ctx.buf, row, row + 1, false)[1] or ''
  -- 内容字段（replace）保留首尾空白：用户可能有意输入缩进或尾随空格，trim 会写错字节
  for _, field in ipairs(M.FIELDS) do
    if field.name == name then
      if field.notrim then return line end
      break
    end
  end
  return vim.trim(line)
end

---@param ctx VVReplaceCtx
---@return table<string, string>
function M.get_values(ctx)
  local values = {}
  for _, field in ipairs(M.FIELDS) do
    values[field.name] = M.get_value(ctx, field.name)
  end
  return values
end

-- 填充初始值。render 必须已调用过
-- 用 set_text 而非 set_lines：set_lines 会把同文件相邻字段的 left-gravity extmark
-- 连带 virt_lines_above 一起向上挤（Neovim 内部把 virt_line 视作 extmark 的前缀）
---@param ctx VVReplaceCtx
---@param values table<string, string>
function M.fill(ctx, values)
  vim.bo[ctx.buf].modifiable = true
  local fields = M.visible_fields(ctx)
  for _, field in ipairs(fields) do
    local value = values[field.name]
    if value and value ~= '' then
      -- 输入框是单行 extmark，换行会让 nvim_buf_set_text 抛 'replacement string contains newlines'
      -- 选区跨行的 prefill 统一压成首行（rg 默认也不跨行匹配，多行 prefill 无意义）
      local first_line = value:match('([^\r\n]*)') or ''
      if first_line ~= '' then
        local row = field_row(ctx, field.name)
        if row then
          local cur = vim.api.nvim_buf_get_lines(ctx.buf, row, row + 1, false)[1] or ''
          vim.api.nvim_buf_set_text(ctx.buf, row, 0, row, #cur, { first_line })
        end
      end
    end
  end
end

-- Tab 循环切换：当前在字段 i → 跳到 i+1（末尾回 1）。光标不在任何字段时跳 search
---@param ctx VVReplaceCtx
---@param direction 1|-1
function M.goto_sibling(ctx, direction)
  local fields = M.visible_fields(ctx)
  local cursor_row = vim.api.nvim_win_get_cursor(ctx.win)[1] - 1
  local current_name = M.field_at_row(ctx, cursor_row)
  local idx = 1
  if current_name then
    for i, f in ipairs(fields) do
      if f.name == current_name then idx = i break end
    end
    idx = ((idx - 1 + direction) % #fields) + 1
  end
  M.goto_field(ctx, fields[idx].name)
end

---@param ctx VVReplaceCtx
---@param name string
function M.goto_field(ctx, name)
  local row = field_row(ctx, name)
  if not row then return end
  local line = vim.api.nvim_buf_get_lines(ctx.buf, row, row + 1, false)[1] or ''
  pcall(vim.api.nvim_win_set_cursor, ctx.win, { row + 1, #line })
end

-- Shift-Tab（normal）切换模式；insert 模式下走 toggle_mode（由 actions 分派）
---@param ctx VVReplaceCtx
function M.toggle_mode(ctx)
  ctx.mode = ctx.mode == 'plainText' and 'regex' or 'plainText'
  M.render(ctx)
end

-- 切换是否搜索隐藏文件（重渲染 Search 徽章）
---@param ctx VVReplaceCtx
function M.toggle_hidden(ctx)
  ctx.show_hidden = not ctx.show_hidden
  M.render(ctx)
end

-- 切换是否搜索 .gitignore 忽略文件（重渲染 Search 徽章）
---@param ctx VVReplaceCtx
function M.toggle_gitignored(ctx)
  ctx.show_ignored = not ctx.show_ignored
  M.render(ctx)
end

return M
