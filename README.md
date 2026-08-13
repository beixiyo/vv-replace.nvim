<div align="center">

# vv-replace.nvim

English | <a href="./README.zh-CN.md">中文</a>

<img src="https://github.com/beixiyo/vv-replace.nvim/releases/download/assets-2026-07-25/vv-replace.png" alt="vv-replace demo" width="900" />

<img src="https://github.com/beixiyo/vv-replace.nvim/releases/download/assets-2026-07-25/vv-replace-help.png" alt="vv-replace keymap help" width="900" />

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
| [vv-utils.nvim](https://github.com/beixiyo/vv-utils.nvim) | Shared filesystem, persistent-state, input-history, help-panel, and UI-window utilities |

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
  cmd = { 'VVReplace', 'VVReplaceFile', 'VVReplaceClose', 'VVReplaceToggle', 'VVReplaceUndo' },
  keys = { '<leader>sR', '<leader>sr' },
  ---@type VVReplaceConfig
  opts = {
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
      next_input = '<C-j>', -- set false to disable; Tab remains dedicated to completion
      toggle_mode = '<S-Tab>',
      history_prev = '<Up>',
      history_next = '<Down>',
      replace_all = '<localleader>r',
      undo_last = '<localleader>u',
      goto_match = '<CR>',
      next_match = '<C-n>',
      prev_match = '<C-p>',
      close = 'q',
      help = 'g?',
    },
    icons = {
      plain = '󰊄', regex = '', next_input = '󰁔', toggle_mode = '󰁨',
      toggle_hidden = '󰈈', toggle_gitignored = '󰊢', goto_match = '',
      replace_all = '', undo_last = '󰕌', close = '', help = '󰌌', title = '',
    },
  },
}
```

## Configuration

| Option | Type | Default | Description |
|---|---|---|---|
| `position` | `'left' \| 'right'` | `'right'` | Panel side |
| `width` | `integer` | `60` | Initial panel width; manual resizing is remembered across panel and Neovim restarts |
| `width_save_debounce_ms` | `integer` | `120` | Delay before persisting a resized panel width |
| `debounce_ms` | `integer` | `200` | Input debounce in milliseconds |
| `max_results` | `integer` | `10000` | Match limit per search |
| `context_lines` | `integer` | `0` | `rg --context=N`; zero disables context |
| `default_mode` | `'plainText' \| 'regex'` | `'plainText'` | Initial search mode |
| `rg_extra_args` | `string[]` | `{}` | Extra arguments for every ripgrep invocation |
| `history_persist` | `boolean` | `true` | Store the latest 50 entries per field in `stdpath('state')/vv-replace/history.json`; set to `false` for session-only history |
| `state` | `VVStateHandle` | `vv-utils.state.register('vv-replace', 'panel')` | Optional state handle injection for custom storage or tests |
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

`next_input` defaults to `<C-j>`, leaving `<Tab>` dedicated to completion and `<CR>` free from field navigation. Set it to `false` to disable field cycling.

The Replace label shows the effective mapping on its right: normally `\r Apply`, then `\u Undo  \r Apply` after a successful replacement, and back to Apply after undo. You can also run `:VVReplaceUndo` outside the panel. Undo aborts without writing if a file changed externally or a related buffer has unsaved changes. The undo snapshot lasts for the current Neovim session

Inside the panel, `<Up>` and `<Down>` recall per-field input history. History is stored under Neovim's state directory by default, so it remains available after reopening the panel or restarting Neovim without touching the project or dotfiles. `<C-n>` and `<C-p>` move between matches in Normal and Insert mode. Moving the cursor automatically previews the source file.
