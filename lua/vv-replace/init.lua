-- vv-replace.nvim — VSCode 风搜索替换面板（自实现，仅依赖 ripgrep）
--
-- 设计目标：
--   * 简洁可预测：两个主输入框 Search / Replace，Tab 循环切换
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
--   require('vv-replace').close()
--   require('vv-replace').toggle({ scope?, cwd?, query?, range? })
--
-- 用户命令（setup 注册）：
--   :VVReplace             — 工作区搜索替换（默认）
--   :VVReplaceFile         — 当前文件搜索替换
--   :'<,'>VVReplaceFile    — 当前文件 + 仅替换选区行（等价 V 模式按 <leader>sr）
--   :VVReplaceClose
--   :VVReplaceToggle

local M = {}

---@class VVReplaceConfig
---@field position 'left'|'right'  侧边面板位置 @default 'right'
---@field width integer  面板宽度（列） @default 60
---@field debounce_ms integer  输入去抖毫秒 @default 200
---@field max_results integer  单次搜索结果条数上限，防大项目卡死 @default 10000
---@field context_lines integer  每个匹配上下文行数（0 = 关闭） @default 0
---@field default_mode 'plainText'|'regex' @default 'plainText'
---@field rg_extra_args string[]  追加给所有 rg 调用的额外参数 @default {}
---@field keymaps VVReplaceKeymaps
---@field icons VVReplaceIcons
local defaults = {
  position = 'right',
  width = 60,
  debounce_ms = 200,
  max_results = 10000,
  context_lines = 0,
  default_mode = 'plainText',
  rg_extra_args = {},
  keymaps = {
    next_input = '<Tab>',
    toggle_mode = '<S-Tab>',       -- 按用户要求：S-Tab 用来切模式（见 actions.lua）
    toggle_hidden     = { '.', '<M-h>' },  -- yazi 风：显隐隐藏文件（dotfile/.env 等）。Alt 键 insert 模式也生效
    toggle_gitignored = { 'I', '<M-i>' },  -- yazi 风：显隐 .gitignore 忽略文件。Alt 键 insert 模式也生效
    replace_all = '<localleader>r',
    goto_match = '<CR>',
    close = 'q',
    help = 'g?',
  },
  icons = {
    plain       = '󰊄',   -- mode 徽章: plainText
    regex       = '',   -- mode 徽章: regex
    next_input  = '󰁔',   -- help: Navigate / next input
    toggle_mode = '󰁨',     -- help: Navigate / toggle mode
    toggle_hidden     = '',  -- 搜索范围徽章 / help: 显隐隐藏文件
    toggle_gitignored = '',  -- 搜索范围徽章 / help: 显隐 .gitignore 忽略文件
    goto_match  = '',  -- help: Navigate / goto match
    replace_all = '',  -- help: Replace / replace all
    close       = '',    -- help: Panel / close
    help        = '󰌌',     -- help: Panel / help
    title       = '',  -- help panel 标题图标
  },
}

---@class VVReplaceKeymaps
---@field next_input string  Tab：下一个输入框 @default '<Tab>'
---@field toggle_mode string  Shift-Tab：切换模式 plainText ↔ regex @default '<S-Tab>'
---@field toggle_hidden string|string[]  切换显隐隐藏文件（dotfile/.env），yazi 风 @default { '.', '<M-h>' }
---@field toggle_gitignored string|string[]  切换显隐 .gitignore 忽略文件，yazi 风 @default { 'I', '<M-i>' }
---@field replace_all string @default '<localleader>r'
---@field goto_match string @default '<CR>'
---@field close string @default 'q'
---@field help string @default 'g?'

---@class VVReplaceIcons
---@field plain string        mode 徽章：plainText（默认 NerdFont text-box） @default '󰊄'
---@field regex string        mode 徽章：regex（默认 NerdFont regex） @default ''
---@field next_input string   help 浮窗图标 @default '󰁔'
---@field toggle_mode string  help 浮窗图标 @default '󰁨'
---@field toggle_hidden string  搜索范围徽章 / help 浮窗图标（显隐隐藏文件） @default ''
---@field toggle_gitignored string  搜索范围徽章 / help 浮窗图标（显隐忽略文件） @default ''
---@field goto_match string   help 浮窗图标 @default ''
---@field replace_all string  help 浮窗图标 @default ''
---@field close string        help 浮窗图标 @default ''
---@field help string         help 浮窗图标 @default '󰌌'
---@field title string        help 浮窗标题图标 @default ''

local config = defaults

---@param opts? table
function M.setup(opts)
  config = vim.tbl_deep_extend('force', defaults, opts or {})
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
end

---@param opts? { scope?: 'project'|'file', cwd?: string, query?: string, range?: integer[] }
function M.open(opts)
  require('vv-replace.buffer').open(config, opts or {})
end

function M.close()
  require('vv-replace.buffer').close()
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
