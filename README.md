<div align="center">

# vv-replace.nvim

English | <a href="./README.zh-CN.md">中文</a>

<img src="./docs/assets/vv-replace.png" alt="vv-replace demo" width="900" />

Want my Neovim config? See <a href="https://github.com/beixiyo/dotfiles">dotfiles</a>.

<em>A VS Code-style search-and-replace panel with plain-text defaults, smart case, and diff previews</em>

<br />

<img src="https://img.shields.io/badge/Neovim-0.10+-57A143?style=flat-square&logo=neovim&logoColor=white" alt="Requires Neovim 0.10+" />
<img src="https://img.shields.io/badge/Lua-2C2D72?style=flat-square&logo=lua&logoColor=white" alt="Lua" />
<a href="https://github.com/BurntSushi/ripgrep"><img src="https://img.shields.io/badge/ripgrep_%E2%89%A513-required-orange?style=flat-square" alt="Requires ripgrep 13+" /></a>

</div>

---

## Requirements

| Dependency | Purpose |
|---|---|
| [Neovim 0.10+](https://github.com/neovim/neovim) | `vim.system`, invalidating extmarks, and `vim.fs.normalize` |
| [ripgrep 13+](https://github.com/BurntSushi/ripgrep) | Search engine using streamed `--json` output and `--replace` to calculate replacements |
| [vv-utils.nvim](https://github.com/beixiyo/vv-utils.nvim) | Shared filesystem, help-panel, and UI-window utilities |

## Why this plugin

[grug-far.nvim](https://github.com/MagicDuck/grug-far.nvim) has several rough edges in daily use:

| | grug-far | vv-replace |
|---|---|---|
| **Default mode** | Regex, so `foo(` and `a.b` must be escaped | Plain text; use `<S-Tab>` to switch to regex |
| **Case handling** | Enter `-s` or `-i` in Flags | Smart case: lowercase searches ignore case, uppercase searches match case |
| **Inputs** | Five fields | Two fields for a file, five for a project |
| **Preview** | Live diff | Inline per-line diff plus a full-file source-window preview under the cursor |

## Installation

```lua
{
  'beixiyo/vv-replace.nvim',
  dependencies = { 'beixiyo/vv-utils.nvim' },
  cmd = { 'VVReplace', 'VVReplaceFile', 'VVReplaceClose', 'VVReplaceToggle' },
  keys = { '<leader>sR', '<leader>sr' },
  ---@type VVReplaceConfig
  opts = {
    position = 'right',
    width = 60,
    debounce_ms = 200,
    max_results = 10000,
    context_lines = 0,
    default_mode = 'plainText',
    rg_extra_args = {},
    keymaps = {
      next_input = '<Tab>',
      toggle_mode = '<S-Tab>',
      replace_all = '<localleader>r',
      goto_match = '<CR>',
      next_match = '<C-n>',
      prev_match = '<C-p>',
      close = 'q',
      help = 'g?',
    },
    icons = {
      plain = '󰊄', regex = '', next_input = '󰁔', toggle_mode = '󰁨',
      goto_match = '', replace_all = '', close = '', help = '󰌌', title = '',
    },
  },
}
```

## Configuration

| Option | Type | Default | Description |
|---|---|---|---|
| `position` | `'left' \| 'right'` | `'right'` | Panel side |
| `width` | `integer` | `60` | Panel width |
| `debounce_ms` | `integer` | `200` | Input debounce in milliseconds |
| `max_results` | `integer` | `10000` | Match limit per search |
| `context_lines` | `integer` | `0` | `rg --context=N`; zero disables context |
| `default_mode` | `'plainText' \| 'regex'` | `'plainText'` | Initial search mode |
| `rg_extra_args` | `string[]` | `{}` | Extra arguments for every ripgrep invocation |
| `keymaps` | `VVReplaceKeymaps` | See above | Overridable panel mappings |
| `icons` | `VVReplaceIcons` | See above | Nerd Font icons; ASCII is also supported |

### Entry mappings

For Visual mode, wrap `open_visual({ scope?, use })`: `use='query'` uses the selection as the query, while `use='range'` limits replacement to selected lines and only applies to file scope.

| Mapping | Action |
|---|---|
| `<leader>sR` | Project search and replace with Search, Replace, Include, Exclude, and Cwd fields |
| `<leader>sr` | Current-file search and replace with Search and Replace fields |
| `<leader>sr` in Visual mode | `open_visual({ scope='file', use='query' })` |
| `<leader>sR` in Visual mode | `open_visual({ use='query' })` |
| `<leader>sv` in Visual mode | `open_visual({ scope='file', use='range' })` |

Inside the panel, `<C-n>` and `<C-p>` move between matches in Normal and Insert mode. Moving the cursor automatically previews the source file.
