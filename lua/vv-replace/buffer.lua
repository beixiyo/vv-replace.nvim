-- Buffer / Window 生命周期 + 单例状态管理
--
-- 设计：
--   * 单例 —— 同时只允许一个 vv-replace 面板，简化状态
--   * buffer 创建后 bufhidden='wipe'，关闭即销毁（不像 vv-explorer 那样保留）
--     —— 搜索结果不持久化；各输入框历史由 vv-utils.history 按字段独立保留
--   * 打开时记录 prev_win，关闭时 focus 回去
--   * autocmd 在 augroup 里管理，close 时整组清理

local Inputs = require('vv-replace.inputs')
local Completion = require('vv-utils.completion')
local Input = require('vv-utils.input')
local UIWindow = require('vv-utils.ui_window')
local Search = require('vv-replace.search')
local Highlight = require('vv-replace.highlight')
local Actions = require('vv-replace.actions')
local PanelState = require('vv-replace.panel_state')

local M = {}

M.FILETYPE = 'vv-replace'

---@type VVReplaceCtx?
M.current = nil

---@return integer
local function create_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = M.FILETYPE
  pcall(vim.api.nvim_buf_set_name, buf, 'vv-replace://' .. tostring(buf))
  return buf
end

---@param buf integer
---@param opts VVReplaceConfig
---@return integer win, integer prev_win
local function open_split(buf, opts)
  local prev = vim.api.nvim_get_current_win()
  local cmd = opts.position == 'right' and 'botright vsplit' or 'topleft vsplit'
  vim.cmd(cmd)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(win, opts.width)
  vim.api.nvim_win_set_buf(win, buf)

  UIWindow.hide_chrome(win, {
    cursorline = true,
    winfixwidth = true,
    winfixbuf = true,
  })
  return win, prev
end

---@param config VVReplaceConfig
---@param opts VVReplaceOpenOpts
---@return VVReplaceCtx
local function build_ctx(config, opts)
  local scope = opts.scope or 'project'
  local target_file = nil
  local cwd = opts.cwd
  if scope == 'file' then
    local cur = vim.api.nvim_buf_get_name(0)
    if cur == '' then
      vim.notify('vv-replace: current buffer has no filename, falling back to project scope', vim.log.levels.WARN)
      scope = 'project'
    else
      target_file = vim.fs.normalize(cur)
    end
  end
  cwd = cwd or vim.fn.getcwd()

  -- range 仅在 file scope 下有效（选区替换本来就只针对单文件）
  local target_range = nil
  local source_buf = nil
  if scope == 'file' and opts.range and #opts.range == 2 then
    local s = math.max(1, math.min(opts.range[1], opts.range[2]))
    local e = math.max(opts.range[1], opts.range[2])
    target_range = { s, e }
    source_buf = vim.api.nvim_get_current_buf()
  end

  return {
    buf = -1,
    win = -1,
    prev_win = -1,
    namespace = vim.api.nvim_create_namespace('vv-replace'),
    augroup = vim.api.nvim_create_augroup('vv-replace-' .. tostring(vim.uv.hrtime()), { clear = true }),
    extmark_ids = {},
    mode = config.default_mode,
    show_hidden = false,
    show_ignored = false,
    scope = scope,
    cwd = cwd,
    target_file = target_file,
    target_range = target_range,
    source_buf = source_buf,
    config = config,
    keymap_labels = {
      next_input = config.keymaps.next_input and Input.display_key(config.keymaps.next_input) or nil,
      toggle_mode = Input.display_key(config.keymaps.toggle_mode),
      replace_all = Input.display_key(config.keymaps.replace_all),
      undo_last = Input.display_key(config.keymaps.undo_last),
      goto_match = Input.display_key(config.keymaps.goto_match),
      next_match = Input.display_key(config.keymaps.next_match),
      prev_match = Input.display_key(config.keymaps.prev_match),
      close = Input.display_key(config.keymaps.close),
      help = Input.display_key(config.keymaps.help),
    },
    state = {
      result_marks = {},
      result_extmark_ids = {},
      searching = false,
      replacing = false,
      closed = false,
    },
  }
end

---@param ctx VVReplaceCtx
local function attach_autocmds(ctx)
  local buf = ctx.buf
  local group = ctx.augroup

  local function on_change()
    if ctx.state.closed or ctx.state.replacing then return end
    -- 用户可能在输入区编辑 → 重渲染 label（placeholder 开/关）+ 触发搜索
    Inputs.render(ctx)
    Search.on_change(ctx)
  end

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = group,
    buffer = buf,
    callback = on_change,
  })

  vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufUnload' }, {
    group = group,
    buffer = buf,
    callback = function()
      M._on_buf_gone(ctx)
    end,
  })

  vim.api.nvim_create_autocmd('WinResized', {
    group = group,
    callback = function()
      if ctx.state.closed or not vim.api.nvim_win_is_valid(ctx.win) then return end
      ctx.panel_state:on_resize(ctx.win)
      Inputs.render(ctx)
    end,
  })

  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(ctx.win),
    once = true,
    callback = function()
      M._on_buf_gone(ctx)
    end,
  })

  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      ctx.panel_state:close(ctx.win)
    end,
  })
end

---@param config VVReplaceConfig
---@param opts VVReplaceOpenOpts
function M.open(config, opts)
  Highlight.setup()

  if M.current and vim.api.nvim_buf_is_valid(M.current.buf) then
    -- 已有面板：只聚焦，不重建
    if vim.api.nvim_win_is_valid(M.current.win) then
      vim.api.nvim_set_current_win(M.current.win)
    else
      local win, prev_win = open_split(M.current.buf, M.current.config)
      M.current.win = win
      M.current.prev_win = prev_win
    end
    return
  end

  local ctx = build_ctx(config, opts)
  ctx.buf = create_buf()
  local win, prev_win = open_split(ctx.buf, config)
  ctx.win = win
  ctx.prev_win = prev_win
  ctx.panel_state = PanelState.new(config.state, config)
  ctx.panel_state:track(win)
  M.current = ctx

  Inputs.render(ctx)
  ctx.completion_detach = Completion.attach(ctx.buf, {
    trigger_characters = { '/', '.', ',', '!', '\\' },
    enabled = function()
      if ctx.state.closed or vim.api.nvim_get_current_buf() ~= ctx.buf then return false end
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local field = Inputs.field_at_row(ctx, row)
      return field == 'include' or field == 'exclude' or field == 'cwd'
    end,
    complete = function(context, defaults, callback)
      if ctx.state.closed then return nil end
      local row = context.cursor[1] - 1
      return Inputs.path_completion(ctx, row, context.line, context.cursor[2], defaults, callback)
    end,
  })

  -- 预填 query（visual selection / 参数）
  local prefills = {}
  if opts.query and opts.query ~= '' then
    prefills.search = opts.query
  end
  Inputs.fill(ctx, prefills)

  Actions.attach(ctx, { close = M.close })
  attach_autocmds(ctx)

  -- 范围模式：在源 buffer 上给选区行打持久高亮，面板关闭时清除
  if ctx.target_range and ctx.source_buf and vim.api.nvim_buf_is_valid(ctx.source_buf) then
    local line_count = vim.api.nvim_buf_line_count(ctx.source_buf)
    local lo = math.max(1, ctx.target_range[1])
    local hi = math.min(line_count, ctx.target_range[2])
    for lnum = lo, hi do
      pcall(vim.api.nvim_buf_set_extmark, ctx.source_buf, ctx.namespace, lnum - 1, 0, {
        line_hl_group = 'Visual',
      })
    end
  end

  -- 初始聚焦 Search 行 + insert 模式
  Inputs.goto_field(ctx, 'search')
  vim.cmd('startinsert!')

  -- 若有预填 query，立即触发一次搜索
  if prefills.search then
    Search.on_change(ctx)
  end
end

---@param timer? uv.uv_timer_t
local function stop_timer(timer)
  if not timer then return end
  pcall(function()
    timer:stop()
    timer:close()
  end)
end

---@param ctx VVReplaceCtx
---@return boolean finalized
local function finalize(ctx)
  if M.current ~= ctx or ctx.state.closed then return false end
  ctx.state.closed = true

  ctx.panel_state:close(ctx.win)
  if ctx.completion_detach then
    ctx.completion_detach()
    ctx.completion_detach = nil
  end
  pcall(Inputs.record_all, ctx)

  if ctx.state.rg_abort then pcall(ctx.state.rg_abort) end
  ctx.state.rg_abort = nil
  stop_timer(ctx.state.search_timer)
  stop_timer(ctx.state.flash_timer)
  ctx.state.search_timer = nil
  ctx.state.flash_timer = nil

  if ctx.source_buf and vim.api.nvim_buf_is_valid(ctx.source_buf) then
    pcall(vim.api.nvim_buf_clear_namespace, ctx.source_buf, ctx.namespace, 0, -1)
  end
  Actions._clear_all_preview_diff(ctx)
  pcall(vim.api.nvim_del_augroup_by_id, ctx.augroup)
  M.current = nil

  return true
end

function M.close()
  local ctx = M.current
  if not ctx then return end
  finalize(ctx)

  if vim.api.nvim_buf_is_valid(ctx.buf) then
    pcall(vim.api.nvim_buf_delete, ctx.buf, { force = true })
  end
  if vim.api.nvim_win_is_valid(ctx.prev_win) then
    pcall(vim.api.nvim_set_current_win, ctx.prev_win)
  end
end

---@param ctx VVReplaceCtx
function M._on_buf_gone(ctx)
  finalize(ctx)
end

---@param config VVReplaceConfig
---@param opts table
function M.toggle(config, opts)
  if M.current then
    M.close()
  else
    M.open(config, opts)
  end
end

return M
