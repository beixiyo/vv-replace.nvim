-- vv-replace.nvim — VSCode 风搜索替换面板（自实现，仅依赖 ripgrep）
--
-- 设计目标：
--   * 简洁可预测：不占用补全键；输入框切换由用户按需配置
--   * 输入历史：Up / Down 按字段回溯，默认持久化并跨 Neovim 重启保留
--   * 模式显式：Shift-Tab 在 plainText / regex 之间切换，默认 plainText
--   * smart case：搜索词含大写自动 -s，否则 -i（VSCode 同款）
--   * 字段按 scope 动态显示：项目级 5 字段，文件级 2 字段
--   * 项目级 vs 文件级：入口参数决定（open({ scope = 'file' }) 搜当前文件）
--
-- 依赖：
--   * ripgrep >= 13（用 --json 流式输出）
--   * Neovim >= 0.10（vim.system、extmark invalid、vim.fs.normalize）
--
-- 公开 API：
--   require('vv-replace').setup(opts)
--   require('vv-replace').open({ scope?, cwd?, query?, range? })
--   require('vv-replace').open_visual({ scope?, use = 'query'|'range' })  -- 从可视选区打开（v 模式键位用）
--   require('vv-replace').close()
--   require('vv-replace').toggle({ scope?, cwd?, query?, range? })
--
-- 用户命令（setup 注册）：
--   :VVReplace             — 工作区搜索替换（默认）
--   :VVReplaceFile         — 当前文件搜索替换
--   :'<,'>VVReplaceFile    — 当前文件 + 仅替换选区行（等价 V 模式按 <leader>sv）
--   :VVReplaceClose
--   :VVReplaceToggle
--   :VVReplaceUndo

local M = {}
require('vv-replace.types')
local PanelState = require('vv-replace.panel_state')

---@type VVReplaceConfig
local defaults = {
  position = 'right',
  width = 60,
  width_save_debounce_ms = 120,
  debounce_ms = 200,
  max_results = 10000,
  context_lines = 0,
  default_mode = 'plainText',
  rg_extra_args = {},
  history_persist = true,
  keymaps = {
    next_input = '<C-j>',          -- 默认不占用 Tab；设为 false 可禁用字段切换
    toggle_mode = '<S-Tab>',       -- 按用户要求：S-Tab 用来切模式（见 actions.lua）
    history_prev = '<Up>',         -- 当前输入框的更早历史（normal + insert）
    history_next = '<Down>',       -- 当前输入框的更新历史（normal + insert）
    toggle_hidden     = { '.', '<M-h>' },  -- yazi 风：显隐隐藏文件（dotfile/.env 等）。Alt 键 insert 模式也生效
    toggle_gitignored = { 'I', '<M-i>' },  -- yazi 风：显隐 .gitignore 忽略文件。Alt 键 insert 模式也生效
    replace_all = '<localleader>r',
    undo_last = '<localleader>u',
    goto_match = '<CR>',
    next_match = '<C-n>',          -- 跳下一个匹配（normal + insert）
    prev_match = '<C-p>',          -- 跳上一个匹配（normal + insert）
    close = 'q',
    help = 'g?',
  },
  icons = {
    plain       = '󰊄',   -- mode 徽章: plainText
    regex       = '',   -- mode 徽章: regex
    next_input  = '󰁔',   -- help: Navigate / next input
    toggle_mode = '󰁨',     -- help: Navigate / toggle mode
    toggle_hidden     = '󰈈',  -- 搜索范围徽章 / help: 显隐隐藏文件
    toggle_gitignored = '󰊢',  -- 搜索范围徽章 / help: 显隐 .gitignore 忽略文件
    goto_match  = '',  -- help: Navigate / goto match
    next_match  = '↓',   -- help: Navigate / next match
    prev_match  = '↑',   -- help: Navigate / prev match
    replace_all = '',  -- help: Replace / replace all
    undo_last   = '󰕌',  -- help: Replace / undo
    close       = '',    -- help: Panel / close
    help        = '󰌌',     -- help: Panel / help
    title       = '',  -- help panel 标题图标
  },
}


---@type VVReplaceConfig
local config = defaults

---@param opts? VVReplaceConfigOpts
function M.setup(opts)
  local configured_state = opts and opts.state
  config = vim.tbl_deep_extend('force', defaults, opts or {})
  config.state = configured_state or require('vv-utils.state').register('vv-replace', 'panel')
  config.width = PanelState.load_width(config.state, config.width)

  require('vv-replace.inputs').setup_history({ persist = config.history_persist })
  require('vv-replace.highlight').setup()

  vim.api.nvim_create_user_command('VVReplace', function(args)
    M.open({ query = args.args ~= '' and args.args or nil })
  end, { nargs = '?', desc = 'vv-replace 搜索替换（工作区）' })

  vim.api.nvim_create_user_command('VVReplaceFile', function(args)
    local open_opts = { scope = 'file' }
    -- 用 :'<,'>VVReplaceFile 调用时带 range，仅替换选区所在行
    if args.range == 2 then
      open_opts.range = { args.line1, args.line2 }
    end
    M.open(open_opts)
  end, { range = true, desc = 'vv-replace 搜索替换（当前文件，可带行范围）' })

  vim.api.nvim_create_user_command('VVReplaceClose', function() M.close() end, {})
  vim.api.nvim_create_user_command('VVReplaceToggle', function() M.toggle() end, {})
  vim.api.nvim_create_user_command('VVReplaceUndo', function() M.undo_last() end, {
    desc = '撤回最近一次 vv-replace 批量替换',
  })
end

---@param opts? { scope?: 'project'|'file', cwd?: string, query?: string, range?: integer[] }
function M.open(opts)
  require('vv-replace.buffer').open(config, opts or {})
end


---从当前可视选区打开面板。封装 getpos/getregion，供 spec 的 v 模式键位一行调用：
---  use='query' → 选中文本（单行）预填为搜索词，不限范围（跨行对 rg 无意义，不预填）
---  use='range' → 选中行作为替换范围，scope 视为 file（全局替换无范围概念）
---@param opts VVReplaceVisualOpts
function M.open_visual(opts)
  opts = opts or {}
  local s, e = vim.fn.getpos('v'), vim.fn.getpos('.')

  if opts.use == 'range' then
    M.open({
      scope = 'file',
      cwd = opts.cwd,
      range = { math.min(s[2], e[2]), math.max(s[2], e[2]) },
    })
    return
  end

  -- 默认 'query'：单行选区预填为搜索词
  local sel = vim.fn.getregion(s, e, { type = vim.fn.mode() })
  M.open({
    scope = opts.scope,
    cwd = opts.cwd,
    query = (#sel == 1) and sel[1] or nil,
  })
end

function M.close()
  require('vv-replace.buffer').close()
end

function M.undo_last()
  local buffer = require('vv-replace.buffer')
  require('vv-replace.replace').undo_last(buffer.current)
end

---@param opts? { scope?: 'project'|'file', cwd?: string, query?: string, range?: integer[] }
function M.toggle(opts)
  require('vv-replace.buffer').toggle(config, opts or {})
end

---获取当前配置（只读副本）
---@return VVReplaceConfig
function M.get_config()
  return vim.deepcopy(config)
end

return M
