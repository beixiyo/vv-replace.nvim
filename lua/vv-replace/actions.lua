-- 动作 + 键位绑定
--
-- 键位设计（可在 config.keymaps 覆盖）：
--   <Tab>     (n+i) 下一个输入框（Search ↔ Replace [↔ Include ↔ Exclude ↔ Cwd]）
--   <S-Tab>   (n+i) 切换模式 plainText ↔ regex
--   <C-g>     (n+i) 静音（屏蔽 vim 默认 file-info）
--   <CR>      (n)   结果行 → 跳到源文件
--   <localleader>r  (n) 替换全部（带确认）
--   q         (n)   关闭
--   g?        (n)   帮助

local Inputs = require('vv-replace.inputs')
local Search = require('vv-replace.search')
local Replace = require('vv-replace.replace')
local Render = require('vv-replace.render')

local M = {}

---@param buf integer
---@param modes string|string[]
---@param lhs string
---@param rhs fun()
---@param desc? string
local function map(buf, modes, lhs, rhs, desc)
  if lhs == false or lhs == nil or lhs == '' then return end
  vim.keymap.set(modes, lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc })
end

---@param ctx VVReplaceCtx
local function goto_match_under_cursor(ctx)
  local mark = Render.mark_at_cursor(ctx)
  if not mark or mark.kind ~= 'match' then
    -- 文件 header 行：跳文件开头
    if mark and mark.kind == 'file' then
      vim.api.nvim_set_current_win(ctx.prev_win)
      vim.cmd('edit ' .. vim.fn.fnameescape(mark.filename))
    end
    return
  end
  if vim.api.nvim_win_is_valid(ctx.prev_win) then
    vim.api.nvim_set_current_win(ctx.prev_win)
  else
    -- prev_win 丢了（用户手动关了）：退回 split
    vim.cmd('wincmd p')
  end
  vim.cmd('edit ' .. vim.fn.fnameescape(mark.filename))
  pcall(vim.api.nvim_win_set_cursor, 0, { mark.lnum or 1, (mark.col or 1) - 1 })
  vim.cmd('normal! zz')
end

---@param ctx VVReplaceCtx
local function show_help(ctx)
  local ic = ctx.config and ctx.config.icons or {}
  require('vv-utils.help_panel').open({
    source_buf = ctx.buf,
    desc_prefix = 'vv-replace: ',
    actions = {
      ['cycle next input (Search/Replace/...)'] = { cat = 'Navigate', icon = ic.next_input },
      ['toggle search mode (plainText ↔ regex)'] = { cat = 'Navigate', icon = ic.toggle_mode },
      ['jump to match under cursor']            = { cat = 'Navigate', icon = ic.goto_match },
      ['replace all matches (with confirm)']    = { cat = 'Replace',  icon = ic.replace_all },
      ['close panel']                           = { cat = 'Panel',    icon = ic.close },
      ['show this help']                        = { cat = 'Panel',    icon = ic.help },
    },
    categories = { 'Navigate', 'Replace', 'Panel' },
    title = 'vv-replace keymaps',
    title_icon = ic.title,
    filetype = 'vv-replace-help',
  })
end

---@param ctx VVReplaceCtx
function M.attach(ctx)
  local buf = ctx.buf
  local km = ctx.config.keymaps

  -- Tab / S-Tab 在 n+i 都生效。i 模式下先退到 n 不行（会破坏 cursor 位置），
  -- 直接执行并保持 insert。
  map(buf, { 'n', 'i' }, km.next_input, function()
    Inputs.goto_sibling(ctx, 1)
    -- 确保 cursor 到行末（光标保持在输入位置），若当前是 normal 切 insert
    if vim.api.nvim_get_mode().mode:match('^i') then
      -- 保持 insert
    else
      vim.cmd('startinsert!')
    end
  end, 'vv-replace: cycle next input (Search/Replace/...)')

  map(buf, { 'n', 'i' }, km.prev_input, function()
    -- Shift-Tab 按用户需求：始终切模式（不做 prev input）
    Inputs.toggle_mode(ctx)
    Render.flash_status(ctx, 'Mode → ' .. (Inputs.mode_display(ctx)[ctx.mode] or ctx.mode))
    -- mode 变了但 inputs 字段没变 → on_change 会误判"没变"跳过搜索；直接 search_now
    Search.search_now(ctx)
  end, 'vv-replace: toggle search mode (plainText ↔ regex)')

  map(buf, 'n', km.goto_match, function()
    goto_match_under_cursor(ctx)
  end, 'vv-replace: jump to match under cursor')

  map(buf, 'n', km.replace_all, function()
    Replace.replace_all(ctx)
  end, 'vv-replace: replace all matches (with confirm)')

  map(buf, 'n', km.close, function()
    require('vv-replace.buffer').close()
  end, 'vv-replace: close panel')

  map(buf, 'n', '<Esc>', function()
    require('vv-replace.buffer').close()
  end, 'vv-replace: close panel')

  map(buf, 'n', km.help, function()
    show_help(ctx)
  end, 'vv-replace: show this help')

  -- 输入行的 <CR>（insert）：避免插入换行破坏布局 —— 跳下一个输入框
  -- （结果区是 normal 模式，已由 km.goto_match 绑在 n）
  vim.keymap.set('i', '<CR>', function()
    local row = vim.api.nvim_win_get_cursor(ctx.win)[1] - 1
    if Inputs.field_at_row(ctx, row) then
      Inputs.goto_sibling(ctx, 1)
    end
    -- 在输入区外（极少见）也不插换行：避免布局失控
  end, { buffer = buf, silent = true })

  -- 静音 vim 自带的 <C-g> file-info —— UI buffer 显示 "vv-replace://N 3 lines" 是噪音
  vim.keymap.set({ 'n', 'i' }, '<C-g>', '<Nop>', { buffer = buf, silent = true })

  -- 鼠标左键单击：在 vv-replace 窗口内移光标 + 若落在结果行则跳源文件
  vim.keymap.set('n', '<LeftMouse>', function()
    local pos = vim.fn.getmousepos()
    if pos.winid ~= ctx.win then
      -- 点击在其它窗口：用默认行为切 focus
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<LeftMouse>', true, false, true), 'n', false)
      return
    end
    pcall(vim.api.nvim_win_set_cursor, ctx.win, { math.max(1, pos.line), math.max(0, pos.column - 1) })
    goto_match_under_cursor(ctx)
  end, { buffer = buf, silent = true })

  -- Neovim 的 virt_lines_above 在 row 0 上方默认不显示（窗口顶部无"上方"空间）。
  -- 用 winrestview({topfill=1}) 强制留一行，让 Search label + mode badge 可见。
  -- 参考：grug-far utils.fixShowTopVirtLines / neovim issue #16166
  local function fix_top_virt_line()
    if ctx.state.closed or not vim.api.nvim_win_is_valid(ctx.win) then return end
    local top = vim.fn.screenpos(ctx.win, 1, 0)
    if top.row ~= 0 then
      vim.api.nvim_win_call(ctx.win, function()
        vim.fn.winrestview({ topfill = 1 })
      end)
    end
  end
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufEnter', 'WinScrolled' }, {
    group = ctx.augroup,
    buffer = buf,
    callback = fix_top_virt_line,
  })
  vim.schedule(fix_top_virt_line)

  -- 结果区禁用 Insert：CursorMoved 根据光标位置动态 modifiable。
  -- 输入区 → modifiable=true（正常编辑）；结果区 → modifiable=false（任何编辑入口会弹"not modifiable"，防止误改结果）。
  -- 额外把 insert-entry 键在结果区 no-op 掉，避免 E21 报错噪音。
  local function in_input_row()
    local row = vim.api.nvim_win_get_cursor(ctx.win)[1] - 1
    return Inputs.field_at_row(ctx, row) ~= nil
  end
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = ctx.augroup,
    buffer = buf,
    callback = function()
      if ctx.state.replacing or ctx.state.closed then return end
      local in_input = in_input_row()
      if vim.bo[buf].modifiable ~= in_input then
        vim.bo[buf].modifiable = in_input
      end
    end,
  })

  -- 结果区光标移动时预览对应文件行（不切换焦点）
  local preview_ns = vim.api.nvim_create_namespace('vv-replace-preview')
  ctx.state.preview_ns = preview_ns
  local last_preview = { filename = nil, lnum = nil }

  vim.api.nvim_create_autocmd('CursorMoved', {
    group = ctx.augroup,
    buffer = buf,
    callback = function()
      if ctx.state.closed or ctx.state.replacing then return end
      if not vim.api.nvim_win_is_valid(ctx.prev_win) then return end

      local mark = Render.mark_at_cursor(ctx)

      if not mark then
        M._clear_preview_diff(ctx.prev_win, preview_ns)
        last_preview.filename = nil
        last_preview.lnum = nil
        return
      end

      local filename = mark.filename
      local lnum = mark.lnum or 1
      if mark.kind == 'file' then lnum = 1 end

      -- 同文件同行 → 跳过
      if filename == last_preview.filename and lnum == last_preview.lnum then return end

      -- 文件切换 → 重新打开 + 重新渲染整个文件的 diff
      local file_changed = (filename ~= last_preview.filename)
      last_preview.filename = filename
      last_preview.lnum = lnum

      vim.api.nvim_win_call(ctx.prev_win, function()
        if file_changed then
          local cur_name = vim.api.nvim_buf_get_name(0)
          if vim.fs.normalize(cur_name) ~= vim.fs.normalize(filename) then
            vim.cmd('edit ' .. vim.fn.fnameescape(filename))
          end
        end

        pcall(vim.api.nvim_win_set_cursor, 0, { lnum, (mark.col or 1) - 1 })
        vim.cmd('normal! zz')
      end)

      if file_changed then
        M._apply_file_diff(ctx, filename, preview_ns)
      end
    end,
  })

  for _, key in ipairs({ 'i', 'I', 'a', 'A', 'o', 'O', 's', 'S', 'c', 'C', 'R' }) do
    vim.keymap.set('n', key, function()
      if in_input_row() then
        return key  -- 输入行：放行原键
      end
      return '<Nop>'  -- 结果区：静音
    end, { buffer = buf, expr = true, silent = true })
  end
end

---@param win integer
---@param ns integer
function M._clear_preview_diff(win, ns)
  if not vim.api.nvim_win_is_valid(win) then return end

  local prev_buf = vim.api.nvim_win_get_buf(win)
  if vim.api.nvim_buf_is_valid(prev_buf) then
    pcall(vim.api.nvim_buf_clear_namespace, prev_buf, ns, 0, -1)
  end
end

---@param ctx VVReplaceCtx
---@param filename string
---@param ns integer
function M._apply_file_diff(ctx, filename, ns)
  if not vim.api.nvim_win_is_valid(ctx.prev_win) then return end

  local prev_buf = vim.api.nvim_win_get_buf(ctx.prev_win)
  if not vim.api.nvim_buf_is_valid(prev_buf) then return end

  pcall(vim.api.nvim_buf_clear_namespace, prev_buf, ns, 0, -1)

  -- 收集同文件所有 match marks
  local file_marks = {}
  for _, mark in pairs(ctx.state.result_marks) do
    if mark.kind == 'match' and mark.filename == filename and mark.submatches then
      file_marks[#file_marks + 1] = mark
    end
  end

  if #file_marks == 0 then return end

  local has_replacement = file_marks[1].submatches[1]
    and file_marks[1].submatches[1].replacement

  for _, mark in ipairs(file_marks) do
    local lnum = (mark.lnum or 1) - 1

    for _, sub in ipairs(mark.submatches) do
      local s = sub.start or 0
      local e = sub['end'] or s

      local hl = has_replacement and 'VVReplaceMatchRemoved' or 'VVReplaceMatch'
      pcall(vim.api.nvim_buf_set_extmark, prev_buf, ns, lnum, s, {
        end_col = e,
        hl_group = hl,
      })

      if sub.replacement then
        local rep_text = (sub.replacement.text or ''):match('([^\n]*)') or ''

        if rep_text ~= '' then
          pcall(vim.api.nvim_buf_set_extmark, prev_buf, ns, lnum, e, {
            virt_text = { { rep_text, 'VVReplaceMatchAdded' } },
            virt_text_pos = 'inline',
          })
        end
      end
    end
  end
end

return M
