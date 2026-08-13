<div align="center">

<h1>vv-replace.nvim</h1>

<a href="./README.md">English</a> | 中文

<img src="https://github.com/beixiyo/vv-replace.nvim/releases/download/assets-2026-07-25/vv-replace.png" alt="vv-replace 演示" width="900" />

想要我的 Neovim 配置？查看 <a href="https://github.com/beixiyo/dotfiles">dotfiles</a>

  <em>VSCode 风的搜索替换面板 — 默认纯文本、smart-case、diff 预览</em>

<br />

  <img src="https://img.shields.io/badge/Neovim-0.10+-57A143?style=flat-square&logo=neovim&logoColor=white" alt="Requires Neovim 0.10+" />
  <img src="https://img.shields.io/badge/Lua-2C2D72?style=flat-square&logo=lua&logoColor=white" alt="Lua" />
  <a href="https://github.com/BurntSushi/ripgrep"><img src="https://img.shields.io/badge/ripgrep_%E2%89%A513-required-orange?style=flat-square" alt="Requires ripgrep ≥13" /></a>
</div>

---

## 依赖

| 依赖 | 说明 |
|------|------|
| [Neovim ≥ 0.10](https://github.com/neovim/neovim) | `vim.system`、extmark `invalid`、`vim.fs.normalize` |
| [ripgrep ≥ 13](https://github.com/BurntSushi/ripgrep) | 搜索引擎，使用 `--json` 流式输出 + `--replace` 计算替换结果 |
| [vv-utils.nvim](https://github.com/beixiyo/vv-utils.nvim) | 共享工具库（fs、state、history、help_panel、ui_window） |

## 为什么要这个插件

[grug-far.nvim](https://github.com/MagicDuck/grug-far.nvim) 日常使用有几处不顺手：

| | grug-far | vv-replace |
|---|---|---|
| **默认模式** | 正则 — 输入 `foo(` 或 `a.b` 需手动转义 | 纯文本（plainText），`<S-Tab>` 切正则 |
| **大小写** | 手敲 `-s`/`-i` 到 Flags 框 | smart-case：全小写自动 `-i`，含大写自动 `-s` |
| **输入框** | 5 个（Search/Replace/Flags/Files/Paths） | 文件模式 2 个，项目模式 5 个 |
| **替换预览** | 实时 diff | 单行 inline diff（匹配标红 + 替换绿色）；光标移动时自动在源窗口预览整个文件的 diff |

## 安装

```lua
{
  'beixiyo/vv-replace.nvim',
  dependencies = { 'beixiyo/vv-utils.nvim' },
  cmd = { 'VVReplace', 'VVReplaceFile', 'VVReplaceClose', 'VVReplaceToggle', 'VVReplaceUndo' },
  keys = { '<leader>sR', '<leader>sr' },
  ---@type VVReplaceConfig
  opts = {
    position = 'right',            -- 'left' | 'right'
    width = 60,                    -- 初始面板宽度
    width_save_debounce_ms = 120,  -- resize 后持久化宽度的防抖延迟
    debounce_ms = 200,             -- 输入去抖延迟
    max_results = 10000,           -- 单次搜索匹配上限
    context_lines = 0,             -- rg --context=N（0 关闭）
    default_mode = 'plainText',    -- 'plainText' | 'regex'
    rg_extra_args = {},            -- 追加给 rg 的额外参数
    history_persist = true,         -- 跨 Neovim 重启保留输入历史
    keymaps = {
      next_input  = '<C-j>',       -- 下一个输入框；设为 false 可禁用
      toggle_mode = '<S-Tab>',     -- 切换模式 plainText ↔ regex
      history_prev = '<Up>',       -- 当前输入框的更早历史
      history_next = '<Down>',     -- 当前输入框的更新历史
      replace_all = '<localleader>r', -- 替换全部（带确认）
      undo_last = '<localleader>u', -- 撤回最近一次成功的批量替换
      goto_match  = '<CR>',        -- 跳转到源文件对应行
      next_match  = '<C-n>',       -- 跳到下一个匹配（normal + insert）
      prev_match  = '<C-p>',       -- 跳到上一个匹配（normal + insert）
      close       = 'q',
      help        = 'g?',
    },
    icons = {
      plain       = '󰊄',           -- mode 徽章: plainText
      regex       = '',          -- mode 徽章: regex
      next_input  = '󰁔',
      toggle_mode = '󰁨',
      toggle_hidden = '󰈈', toggle_gitignored = '󰊢',
      goto_match  = '',
      replace_all = '', undo_last = '󰕌',
      close       = '',
      help        = '󰌌',
      title       = '',
    },
  },
}
```

## 配置

| 选项 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `position` | `'left' \| 'right'` | `'right'` | 面板位置 |
| `width` | `integer` | `60` | 初始面板宽度；手动 resize 后跨关闭和 Neovim 重启保持 |
| `width_save_debounce_ms` | `integer` | `120` | resize 后持久化宽度的防抖延迟（ms） |
| `debounce_ms` | `integer` | `200` | 输入去抖延迟（ms） |
| `max_results` | `integer` | `10000` | 单次搜索匹配上限，防大项目卡死 |
| `context_lines` | `integer` | `0` | `rg --context=N`，0 = 关闭 |
| `default_mode` | `'plainText' \| 'regex'` | `'plainText'` | 默认搜索模式 |
| `rg_extra_args` | `string[]` | `{}` | 追加给所有 rg 调用的额外参数（如 `{ '--hidden' }`） |
| `history_persist` | `boolean` | `true` | 把各字段最近 50 条历史写入 `stdpath('state')/vv-replace/history.json`；设为 `false` 仅在当前会话保留 |
| `state` | `VVStateHandle` | `vv-utils.state.register('vv-replace', 'panel')` | 可选的状态句柄注入，供自定义存储或测试 |
| `keymaps` | `VVReplaceKeymaps` | *见上方* | 面板内键位，可逐项覆盖 |
| `icons` | `VVReplaceIcons` | *见上方* | NerdFont 图标；非 NerdFont 用户可改 ASCII |

### 入口键位

> 可视选区入口推荐用 `open_visual({ scope?, use })` 封装：`use='query'` 选区作搜索词、`use='range'` 选区作替换范围（range 仅 `file` scope 生效，全局替换无范围概念）

| 键 | 作用 |
|----|------|
| `<leader>sR` | 项目级搜索替换（5 字段：Search / Replace / Include / Exclude / Cwd） |
| `<leader>sr` | 当前文件搜索替换（2 字段：Search / Replace） |
| `<leader>sr`（visual） | `open_visual({ scope='file', use='query' })`：选区作搜索词，全文件替换 |
| `<leader>sR`（visual） | `open_visual({ use='query' })`：选区作搜索词，工作区替换 |
| `<leader>sv`（visual） | `open_visual({ scope='file', use='range' })`：仅在选中行内查找替换 |

`next_input` 默认使用 `<C-j>`，因此 `<Tab>` 始终专用于补全，`<CR>` 也不负责跳输入框；设为 `false` 可关闭字段循环

面板内 `<Up>` / `<Down>` 按字段回溯输入历史。历史默认写入 Neovim state 目录，关闭面板或重启 Neovim 后仍可继续回溯；不会写入项目或 dotfiles。`<C-n>` / `<C-p>` 跳到下一个 / 上一个匹配（normal 与 insert 均可），光标移动时自动预览源文件

Replace 标签右侧会显示实际生效的替换键：平时为 `\r Apply`，替换成功后动态变为 `\u Undo  \r Apply`，撤回后恢复。也可在面板外执行 `:VVReplaceUndo`。撤回前会校验文件没有被外部修改且相关 buffer 没有未保存内容；有冲突时不会写入任何文件。撤回记录保留在当前 Neovim 会话中，重启后清空
