-- 面板 buffer-local 快捷键

local Help = require('vv-replace.actions.help')
local Inputs = require('vv-replace.inputs')
local Navigation = require('vv-replace.actions.navigation')
local Render = require('vv-replace.render')
local Replace = require('vv-replace.replace')
local Results = require('vv-replace.actions.results')
local Search = require('vv-replace.search')

local M = {}

---@param buf integer
---@param modes string|string[]
---@param lhs string|false|nil
---@param rhs function|string
---@param desc? string
local function map(buf, modes, lhs, rhs, desc)
  if lhs == false or lhs == nil or lhs == '' then return end
  vim.keymap.set(modes, lhs, rhs, {
    buffer = buf,
    silent = true,
    nowait = true,
    desc = desc,
  })
end

-- 所有键在 normal 生效，Alt 键额外在 insert 生效
---@param buf integer
---@param lhs_list string|string[]|false|nil
---@param rhs fun()
---@param desc string
local function map_toggle(buf, lhs_list, rhs, desc)
  if not lhs_list or lhs_list == '' then return end

  ---@type string[]
  local keys
  if type(lhs_list) == 'table' then
    keys = lhs_list
  else
    keys = { lhs_list }
  end
  for _, key in ipairs(keys) do
    if key and key ~= '' then
      vim.keymap.set('n', key, rhs, {
        buffer = buf,
        silent = true,
        nowait = true,
        desc = desc,
      })
      if key:match('^<[MA]%-') then
        vim.keymap.set('i', key, rhs, {
          buffer = buf,
          silent = true,
          nowait = true,
          desc = desc,
        })
      end
    end
  end
end

---@param ctx VVReplaceCtx
---@return boolean
local function in_input_row(ctx)
  local row = vim.api.nvim_win_get_cursor(ctx.win)[1] - 1
  return Inputs.field_at_row(ctx, row) ~= nil
end

-- 回落到原生按键：带上用户输入的 count，noremap 避免再次命中本映射
---@param key string
local function feed_native(key)
  local count = vim.v.count > 0 and tostring(vim.v.count) or ''
  local keys = vim.api.nvim_replace_termcodes(count .. key, true, false, true)
  vim.api.nvim_feedkeys(keys, 'n', false)
end

---@return boolean
local function in_normal_mode()
  return vim.api.nvim_get_mode().mode == 'n'
end

---@param ctx VVReplaceCtx
---@param opts {close:fun()}
function M.attach(ctx, opts)
  local buf = ctx.buf
  local keymaps = ctx.config.keymaps

  map(buf, { 'n', 'i' }, keymaps.next_input, function()
    Inputs.goto_sibling(ctx, 1)
    if not vim.api.nvim_get_mode().mode:match('^i') then
      vim.cmd('startinsert!')
    end
  end, 'vv-replace: cycle next input (Search/Replace/...)')

  map(buf, { 'n', 'i' }, keymaps.toggle_mode, function()
    Inputs.toggle_mode(ctx)
    Render.flash_status(ctx, 'Mode → ' .. (Inputs.mode_display(ctx)[ctx.mode] or ctx.mode))
    Search.search_now(ctx)
  end, 'vv-replace: toggle search mode (plainText ↔ regex)')

  -- 输入框内回溯历史；normal 模式在结果区时改为跳过文件行的结果移动；其余回落原生方向键
  local function navigate_history(direction, fallback)
    return function()
      if Inputs.navigate_history(ctx, direction) then return end
      if in_normal_mode() and Results.move(ctx, direction, vim.v.count1) then return end

      local keys = vim.api.nvim_replace_termcodes(fallback, true, false, true)
      vim.api.nvim_feedkeys(keys, 'n', false)
    end
  end

  map(
    buf,
    { 'n', 'i' },
    keymaps.history_prev,
    navigate_history(-1, '<Up>'),
    'vv-replace: recall previous input'
  )
  map(
    buf,
    { 'n', 'i' },
    keymaps.history_next,
    navigate_history(1, '<Down>'),
    'vv-replace: recall next input'
  )

  -- 结果区导航与折叠只在 normal 模式映射；不在结果区时回落原生按键，输入区与 insert 模式不受影响
  local result_keys = {
    { lhs = 'j', run = function() return Results.move(ctx, 1, vim.v.count1) end, desc = 'next result' },
    { lhs = 'k', run = function() return Results.move(ctx, -1, vim.v.count1) end, desc = 'previous result' },
    { lhs = '<Down>', run = function() return Results.move(ctx, 1, vim.v.count1) end, desc = 'next result' },
    { lhs = '<Up>', run = function() return Results.move(ctx, -1, vim.v.count1) end, desc = 'previous result' },
    { lhs = 'h', run = function() return Results.fold(ctx) end, desc = 'fold file' },
    { lhs = '<Left>', run = function() return Results.fold(ctx) end, desc = 'fold file' },
    { lhs = 'l', run = function() return Results.unfold(ctx) end, desc = 'unfold file' },
    { lhs = '<Right>', run = function() return Results.unfold(ctx) end, desc = 'unfold file' },
  }
  for _, item in ipairs(result_keys) do
    -- 与历史键相同的方向键已在 navigate_history 里处理结果区移动，避免覆盖其 insert/normal 映射
    if item.lhs ~= keymaps.history_prev and item.lhs ~= keymaps.history_next then
      map(buf, 'n', item.lhs, function()
        if not item.run() then feed_native(item.lhs) end
      end, 'vv-replace: ' .. item.desc)
    end
  end

  if ctx.scope ~= 'file' then
    map_toggle(buf, keymaps.toggle_hidden, function()
      Inputs.toggle_hidden(ctx)
      Render.flash_status(ctx, 'Hidden files: ' .. (ctx.show_hidden and 'shown' or 'hidden'))
      Search.search_now(ctx)
    end, 'vv-replace: toggle hidden files')

    map_toggle(buf, keymaps.toggle_gitignored, function()
      Inputs.toggle_gitignored(ctx)
      Render.flash_status(ctx, 'Git-ignored files: ' .. (ctx.show_ignored and 'shown' or 'hidden'))
      Search.search_now(ctx)
    end, 'vv-replace: toggle git-ignored files')
  end

  map(buf, 'n', keymaps.goto_match, function()
    Navigation.goto_under_cursor(ctx)
  end, 'vv-replace: jump to match under cursor')

  local function navigate_match(direction)
    return function()
      if not Navigation.has_match(ctx) then return end

      if vim.api.nvim_get_mode().mode:match('^i') then
        vim.cmd('stopinsert')
        vim.schedule(function()
          Navigation.goto_relative(ctx, direction)
        end)
      else
        Navigation.goto_relative(ctx, direction)
      end
    end
  end

  map(buf, { 'n', 'i' }, keymaps.next_match, navigate_match(1), 'vv-replace: jump to next match')
  map(buf, { 'n', 'i' }, keymaps.prev_match, navigate_match(-1), 'vv-replace: jump to previous match')

  map(buf, 'n', keymaps.replace_all, function()
    Replace.replace_all(ctx)
  end, 'vv-replace: replace all matches (with confirm)')

  map(buf, 'n', keymaps.undo_last, function()
    Replace.undo_last(ctx)
  end, 'vv-replace: undo last replacement')

  map(buf, 'n', keymaps.close, opts.close, 'vv-replace: close panel')
  map(buf, 'n', '<Esc>', opts.close, 'vv-replace: close panel')

  map(buf, 'n', keymaps.help, function()
    Help.open(ctx)
  end, 'vv-replace: show this help')

  if keymaps.next_input ~= '<CR>' then
    vim.keymap.set('i', '<CR>', '<Nop>', {
      buffer = buf,
      silent = true,
      desc = 'vv-replace: keep inputs single-line',
    })
  end

  vim.keymap.set('n', 'dd', function()
    Inputs.clear_current(ctx)
  end, {
    buffer = buf,
    silent = true,
    desc = 'vv-replace: clear current input',
  })

  vim.keymap.set({ 'n', 'i' }, '<C-g>', '<Nop>', {
    buffer = buf,
    silent = true,
  })

  vim.keymap.set('n', '<LeftMouse>', function()
    local position = vim.fn.getmousepos()
    if position.winid ~= ctx.win then
      local mouse = vim.api.nvim_replace_termcodes('<LeftMouse>', true, false, true)
      vim.api.nvim_feedkeys(mouse, 'n', false)
      return
    end

    pcall(vim.api.nvim_win_set_cursor, ctx.win, {
      math.max(1, position.line),
      math.max(0, position.column - 1),
    })
    Navigation.goto_under_cursor(ctx)
  end, { buffer = buf, silent = true })

  local expression_keys = { 'i', 'a', 'A', 'o', 'O', 's', 'S', 'c', 'C', 'R' }
  if ctx.scope == 'file' then
    expression_keys[#expression_keys + 1] = 'I'
  end
  for _, key in ipairs(expression_keys) do
    vim.keymap.set('n', key, function()
      return in_input_row(ctx) and key or '<Nop>'
    end, {
      buffer = buf,
      expr = true,
      silent = true,
    })
  end
end

return M
