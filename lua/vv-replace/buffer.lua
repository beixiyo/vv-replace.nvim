-- Buffer / Window 生命周期 + 单例状态管理
--
-- 设计：
--   * 单例 —— 同时只允许一个 vv-replace 面板，简化状态
--   * buffer 创建后 bufhidden='wipe'，关闭即销毁（不像 vv-explorer 那样保留）
--     —— 因为搜索状态不需要持久化，每次打开都是全新会话
--   * 打开时记录 prev_win，关闭时 focus 回去
--   * autocmd 在 augroup 里管理，close 时整组清理

local Inputs = require('vv-replace.inputs')
local Search = require('vv-replace.search')
local Highlight = require('vv-replace.highlight')
local Actions = require('vv-replace.actions')

local M = {}

M.FILETYPE = 'vv-replace'

---@class VVReplaceCtx
---@field buf integer
---@field win integer
---@field prev_win integer
---@field namespace integer
---@field augroup integer
---@field extmark_ids table<string, integer>
---@field mode 'plainText'|'regex'
---@field scope 'project'|'file'
---@field cwd string
---@field target_file string?  scope='file' 时的目标文件绝对路径
---@field target_range integer[]?  scope='file' 时的 1-based 行范围 { start, end }，限制 match/replace 的生效行
---@field source_buf integer?  range 生效时，源 buffer（用于高亮 + 关闭时清除）
---@field config VVReplaceConfig
---@field state VVReplaceState

---@class VVReplaceState
---@field last_inputs table<string, string>?
---@field search_timer uv.uv_timer_t?
---@field flash_timer uv.uv_timer_t?  模式切换 toast 的计时器
---@field rg_abort fun()?  当前搜索可中止
---@field result_marks table<integer, VVReplaceResultMark>  key=buffer row
---@field result_extmark_ids integer[]  结果区的高亮 extmark id，清结果时统一删
---@field last_status { text: string, is_error?: boolean }?  最近一次正式 status，供 flash 还原
---@field last_json any[]?  上次完整的 rg json 数组，供 replace 复用
---@field searching boolean
---@field replacing boolean
---@field closed boolean

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

  local ok_utils, ui_window = pcall(require, 'vv-utils.ui_window')
  if ok_utils then
    ui_window.hide_chrome(win, { cursorline = true, winfixwidth = true, winfixbuf = true })
  else
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = 'no'
    vim.wo[win].cursorline = true
    vim.wo[win].wrap = false
  end
  return win, prev
end

---@class VVReplaceOpenOpts
---@field scope? 'project'|'file'
---@field cwd? string
---@field query? string
---@field range? integer[]  1-based 行范围 { start, end }，仅在 scope='file' 时生效（V 模式只改选区）

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
    scope = scope,
    cwd = cwd,
    target_file = target_file,
    target_range = target_range,
    source_buf = source_buf,
    config = config,
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

  -- 防用户在输入区 Enter 破坏布局：map <CR> 到 noop（由 actions 处理）
  -- 这部分已在 Actions 里通过 buffer-local keymap 绑定
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
  M.current = ctx

  Inputs.render(ctx)

  -- 预填 query（visual selection / 参数）
  local prefills = {}
  if opts.query and opts.query ~= '' then
    prefills.search = opts.query
  end
  Inputs.fill(ctx, prefills)

  Actions.attach(ctx)
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

function M.close()
  local ctx = M.current
  if not ctx then return end
  ctx.state.closed = true
  if ctx.state.rg_abort then pcall(ctx.state.rg_abort) end
  if ctx.state.search_timer then
    pcall(function() ctx.state.search_timer:stop() ctx.state.search_timer:close() end)
    ctx.state.search_timer = nil
  end
  if ctx.state.flash_timer then
    pcall(function() ctx.state.flash_timer:stop() ctx.state.flash_timer:close() end)
    ctx.state.flash_timer = nil
  end
  -- 清除源 buffer 上的范围高亮
  if ctx.source_buf and vim.api.nvim_buf_is_valid(ctx.source_buf) then
    pcall(vim.api.nvim_buf_clear_namespace, ctx.source_buf, ctx.namespace, 0, -1)
  end
  pcall(vim.api.nvim_del_augroup_by_id, ctx.augroup)
  if vim.api.nvim_buf_is_valid(ctx.buf) then
    pcall(vim.api.nvim_buf_delete, ctx.buf, { force = true })
  end
  if vim.api.nvim_win_is_valid(ctx.prev_win) then
    pcall(vim.api.nvim_set_current_win, ctx.prev_win)
  end
  M.current = nil
end

---@param ctx VVReplaceCtx
function M._on_buf_gone(ctx)
  if M.current == ctx then
    ctx.state.closed = true
    -- kill 运行中的 rg 进程
    if ctx.state.rg_abort then pcall(ctx.state.rg_abort) end
    -- 停止 search_timer
    if ctx.state.search_timer then
      pcall(function() ctx.state.search_timer:stop() ctx.state.search_timer:close() end)
      ctx.state.search_timer = nil
    end
    -- 停止 flash_timer
    if ctx.state.flash_timer then
      pcall(function() ctx.state.flash_timer:stop() ctx.state.flash_timer:close() end)
      ctx.state.flash_timer = nil
    end
    -- 面板被外部 :q/:bd 关掉时，同样清源 buffer 的范围高亮
    if ctx.source_buf and vim.api.nvim_buf_is_valid(ctx.source_buf) then
      pcall(vim.api.nvim_buf_clear_namespace, ctx.source_buf, ctx.namespace, 0, -1)
    end
    -- 清理 augroup
    pcall(vim.api.nvim_del_augroup_by_id, ctx.augroup)
    M.current = nil
  end
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
