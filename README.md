# vv-replace.nvim

VSCode 风的 Neovim 搜索替换面板，自实现，仅依赖 `ripgrep`

只做"项目级 / 单文件搜索替换"。复杂用例（ast-grep、多引擎切换、lua 插值 replace）请用 [grug-far.nvim](https://github.com/MagicDuck/grug-far.nvim)

## 为什么造这个轮子

试过 grug-far，体验上有几处不顺手：

- **默认正则模式**，输入 `foo(` 或 `a.b` 这种含元字符的常见词会 0 匹配，新手摸不着头脑；VSCode 默认 plaintext
- **输入框过多**：Search / Replace 外还有 Flags / Files / Paths，Tab 循环一圈要按 5 次
- **大小写控制靠 flag**：要手敲 `-s`/`-i` 到 Flags 框
- **Shift-Tab 被占作 prev-input**，无法拿来切模式

所以造了一个按 VSCode 手感重写的：默认 plaintext、smart-case、Shift-Tab 切模式、Tab 只在 Search↔Replace 间循环（项目模式扩到 5 个）

## 特性

- **两档入口**：`<leader>sR` 项目级（5 字段：Search / Replace / Include / Exclude / Cwd），`<leader>sr` 当前文件（2 字段：Search / Replace）
- **Shift-Tab 切模式**：`󰊄 Plain` ↔ ` Regex`，Search label 旁粉紫色徽章常驻显示
- **smart-case**：搜索词全小写自动 `-i`，含大写自动 `-s`（VSCode 同款）
- **去抖搜索**：输入 200ms 后自动触发 rg，空 query 立即清空结果
- **流式结果**：`rg --json` 一边跑一边解析，带截断保护（默认 10000 匹配上限）
- **diff 预览**：Replace 框有内容时，每个匹配行下方多一行绿色显示替换后效果
- **按 `Enter` / 鼠标单击跳转**：在结果行（源行或替换行）都能跳到源文件对应行号
- **glob 筛选**：Include / Exclude 框支持多 glob 逗号分隔，自动转 `-g` / `-g '!...'`
- **结果区只读**：光标进结果区自动锁 `modifiable`，`i/I/a/A/o/O/s/S/c/C/R` 静音 no-op
- **替换写回**：按 `<localleader>r` 带确认；精确按字节 offset 拼接新内容（不依赖 `--passthrough`，末尾换行稳定保留）
- **占位提示**：空输入框显示灰色 placeholder；状态栏显示 `N matches in M files`
- **toast 反馈**：切模式时状态栏闪一下 `Mode → 󰊄 Plain`，1.5s 后还原为结果统计
- **`g?` help 浮窗**：反读 buffer mappings 渲染，永远和实际绑定一致（走 `vv-utils.help_panel`）

## 依赖

- Neovim 0.10+（`vim.uv` / `vim.system` / extmark `invalid` / `virt_lines_above`）
- [`ripgrep`](https://github.com/BurntSushi/ripgrep) >= 13（用 `--json` 流式输出）
- [vv-utils.nvim](https://github.com/beixiyo/vv-utils.nvim)（`fs.read_all` / `fs.write_all` / `hl.register` / `help_panel` / `ui_window`）
- NerdFont 字体（mode 徽章 + help 浮窗默认图标是 PUA 码位；无 NerdFont 时传 `opts.icons` 覆盖为 ASCII）

## 安装

lazy.nvim：

```lua
{
  'beixiyo/vv-replace.nvim',
  dependencies = { 'beixiyo/vv-utils.nvim' },
  cmd = { 'VVReplace', 'VVReplaceFile', 'VVReplaceClose', 'VVReplaceToggle' },
  keys = { '<leader>sR', '<leader>sr' },
  opts = {},
}
```

## 用户命令

| 命令 | 作用 |
|------|------|
| `:VVReplace [query]` | 项目级搜索替换，可选预填搜索词 |
| `:VVReplaceFile` | 当前文件搜索替换 |
| `:VVReplaceClose` | 关闭面板 |
| `:VVReplaceToggle` | 打开/关闭切换 |

## 快捷键

### 入口（全局）

| 键 | 作用 |
|----|------|
| `<leader>sR` | 项目级搜索替换 |
| `<leader>sr` | 当前文件搜索替换 |
| `<leader>sR`（visual） | 用选区预填 Search |

### 面板内（buffer-local）

| 键 | 模式 | 作用 |
|----|------|------|
| `<Tab>` | n+i | 下一个输入框循环 |
| `<S-Tab>` | n+i | 切换模式 `plainText` ↔ `regex` |
| `<CR>` | i（输入行） | 跳下一个输入框（避免插换行破坏布局） |
| `<CR>` | n（结果行） | 跳源文件对应行号 |
| `<LeftMouse>` | n | 移光标；若落在结果行则跳源文件 |
| `<localleader>r` | n | 替换全部（带确认） |
| `q` | n | 关闭面板 |
| `g?` | n | help 浮窗 |
| `<C-g>` | n+i | 静音（避免 vim 默认 file-info 噪音） |

## 配置

### 默认（开箱即用，`setup({})` 即可）

```lua
{
  position = 'right',           -- 'left' | 'right'
  width = 60,
  debounce_ms = 200,
  max_results = 10000,          -- 单次搜索匹配上限，防大项目卡死
  context_lines = 0,            -- rg --context=N，0=关闭
  default_mode = 'plainText',   -- 'plainText' | 'regex'
  rg_extra_args = {},           -- 追加给所有 rg 调用的额外参数
  keymaps = {
    next_input     = '<Tab>',
    prev_input     = '<S-Tab>', -- 切模式
    replace_all    = '<localleader>r',
    goto_match     = '<CR>',
    close          = 'q',
    help           = 'g?',
  },
  icons = {
    plain       = '󰊄',  -- mode 徽章: plainText（nf-md-text-box）
    regex       = '',  -- mode 徽章: regex（nf-cod-regex）
    next_input  = '󰁔',  -- help: Navigate / 下一个输入框
    toggle_mode = '󰁨',  -- help: Navigate / 切模式
    goto_match  = '',  -- help: Navigate / 跳源文件
    replace_all = '',  -- help: Replace / 替换全部
    close       = '',  -- help: Panel / 关闭
    help        = '󰌌',  -- help: Panel / help 浮窗
    title       = '',  -- help 浮窗标题图标
  },
}
```

### 自定义示例

```lua
require('vv-replace').setup({
  position = 'left',
  width = 80,
  debounce_ms = 300,
  default_mode = 'regex',
  rg_extra_args = { '--hidden', '--no-ignore-vcs' }, -- 搜 dotfile / 忽略 .gitignore
  keymaps = {
    replace_all = '<leader>R',
  },
  icons = { -- 非 NerdFont 用户改 ASCII
    plain = 'T', regex = '.*', next_input = '->', toggle_mode = '*',
    goto_match = '?', replace_all = 'r', close = 'x', help = '?',
    title = '#',
  },
})
```

## 设计决策

- **单 buffer 单面板**：整个输入区和结果区共享一个 buffer，输入区边界用 left-gravity extmark 标记；用户 `ggVGd` 清空也能自动恢复
- **字段按 scope 动态显示**：不做展开/收起切换，避免切换时结果区错位的 bug
- **搜索时就带 `--replace=<text>`**：让 rg 在 json 里返回 `submatch.replacement.text`，diff 预览和写回都复用这份数据，不用跑第二次 rg
- **写回按 `absolute_offset` 拼接**：从 rg json 里精确拿字节 offset，读原文件后按 offset 替换，不依赖 `--passthrough` —— 文件末尾是否有换行完全由原文件决定
- **`virt_lines_above` 修复**：Neovim [#16166](https://github.com/neovim/neovim/issues/16166) 让 row 0 上方的 virt_line 在窗口顶部不可见，用 `winrestview({topfill=1})` 强制留一行解决
- **结果区动态 `modifiable`**：`CursorMoved` autocmd 按光标位置切换 buffer modifiable，配合 insert-entry 键的 no-op override 屏蔽编辑噪音
- **替换写回整文件 buffer**：用 `vv-utils.fs.write_all`，父目录 mkdir_p，写失败 error 向上抛；调用方 pcall 后汇总到失败清单

## 已知限制

- **多行匹配只渲染首行**：结果区每个匹配显示一行；`rg --multiline` 模式的跨行匹配只取第一行。MVP 范围外
- **替换串行**：大项目几百文件会逐个写，稳定但不极限快
- **Cwd 框里不支持环境变量 / `~`**：直接作为字符串传给 rg 的位置参数，rg 自己支持的才有效

## Testing

Smoke test (zero deps, runs in `-u NONE`):

```bash
nvim --headless -u NONE -l tests/test_smoke.lua
```

Expected: trailing line `X passed, 0 failed`.
