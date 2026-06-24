<h1 align="center">vv-replace.nvim</h1>

<p align="center">
  <em>VSCode 风的搜索替换面板 — 默认纯文本、smart-case、diff 预览</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Neovim-0.10+-57A143?style=flat-square&logo=neovim&logoColor=white" alt="Requires Neovim 0.10+" />
  <img src="https://img.shields.io/badge/Lua-2C2D72?style=flat-square&logo=lua&logoColor=white" alt="Lua" />
  <a href="https://github.com/BurntSushi/ripgrep"><img src="https://img.shields.io/badge/ripgrep_%E2%89%A513-required-orange?style=flat-square" alt="Requires ripgrep ≥13" /></a>
</p>

---

## 依赖

| 依赖 | 说明 |
|------|------|
| [Neovim ≥ 0.10](https://github.com/neovim/neovim) | `vim.system`、extmark `invalid`、`vim.fs.normalize` |
| [ripgrep ≥ 13](https://github.com/BurntSushi/ripgrep) | 搜索引擎，使用 `--json` 流式输出 + `--replace` 计算替换结果 |
| [vv-utils.nvim](https://github.com/beixiyo/vv-utils.nvim) | 共享工具库（fs、help_panel、ui_window） |

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
  cmd = { 'VVReplace', 'VVReplaceFile', 'VVReplaceClose', 'VVReplaceToggle' },
  keys = { '<leader>sR', '<leader>sr' },
  ---@type VVReplaceConfig
  opts = {
    position = 'right',            -- 'left' | 'right'
    width = 60,                    -- 面板宽度
    debounce_ms = 200,             -- 输入去抖延迟
    max_results = 10000,           -- 单次搜索匹配上限
    context_lines = 0,             -- rg --context=N（0 关闭）
    default_mode = 'plainText',    -- 'plainText' | 'regex'
    rg_extra_args = {},            -- 追加给 rg 的额外参数
    keymaps = {
      next_input  = '<Tab>',       -- 下一个输入框
      toggle_mode = '<S-Tab>',     -- 切换模式 plainText ↔ regex
      replace_all = '<localleader>r', -- 替换全部（带确认）
      goto_match  = '<CR>',        -- 跳转到源文件对应行
      next_match  = '<C-n>',       -- 跳到下一个匹配（normal + insert）
      prev_match  = '<C-p>',       -- 跳到上一个匹配（normal + insert）
      close       = 'q',
      help        = 'g?',
    },
    icons = {
      plain       = '󰊄',           -- mode 徽章: plainText
      regex       = '',           -- mode 徽章: regex
      next_input  = '󰁔',
      toggle_mode = '󰁨',
      goto_match  = '',
      replace_all = '',
      close       = '',
      help        = '󰌌',
      title       = '',
    },
  },
}
```

## 配置

| 选项 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `position` | `'left' \| 'right'` | `'right'` | 面板位置 |
| `width` | `integer` | `60` | 面板宽度 |
| `debounce_ms` | `integer` | `200` | 输入去抖延迟（ms） |
| `max_results` | `integer` | `10000` | 单次搜索匹配上限，防大项目卡死 |
| `context_lines` | `integer` | `0` | `rg --context=N`，0 = 关闭 |
| `default_mode` | `'plainText' \| 'regex'` | `'plainText'` | 默认搜索模式 |
| `rg_extra_args` | `string[]` | `{}` | 追加给所有 rg 调用的额外参数（如 `{ '--hidden' }`） |
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

面板内 `<C-n>` / `<C-p>` 跳到下一个 / 上一个匹配（normal 与 insert 均可），光标移动时自动预览源文件
