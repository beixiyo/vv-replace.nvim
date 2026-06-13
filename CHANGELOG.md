# Changelog

## [Unreleased]

### Added
- **搜索范围切换**（project scope，yazi / vv-explorer 风）：两个独立开关——`.`（或 `<M-h>`）显隐**隐藏文件**（`--hidden`）、`I`（或 `<M-i>`）显隐 **`.gitignore` 忽略文件**（`--no-ignore`）。默认两者皆关（与 ripgrep 默认一致）；Search 标签旁有状态徽章（默认显示 `(. hidden, I ignored)` 提示，开启的项高亮列出），切换即重搜。解决「搜不到 `node_modules`/`dist`/`.env` 等被忽略或隐藏文件」的困惑——这类文件 rg 默认不搜，需显式开启。`Alt` 键在 insert 模式也生效（输入时可直接切换）；键位 `keymaps.toggle_hidden` / `keymaps.toggle_gitignored` 可配置（支持单键或键列表）
- **Live preview**: moving cursor over result items automatically opens the corresponding file and line in the source window (without switching focus).
- **File-level diff preview**: when entering a file's results, all matches in that file are highlighted in the source window — matched text shown as removed (red), replacement as inline virtual text (green).
- Added `<Esc>` mapping to close the panel in normal mode.

### Changed
- **Single-line inline diff**: replace preview in the results panel now uses one line per match (matched text highlighted + replacement as inline virtual text), instead of two separate lines. Faster `j`/`k` navigation.

### Fixed
- 搜索后文件在磁盘上被改动（如另一窗口编辑保存）再替换，不再用陈旧的字节偏移拼接而悄悄损坏文件；现在拼接前会校验缓存行仍处在原位置，不符则该文件不写入并列入失败清单，可重新搜索后再替换
- 匹配行含非法 UTF-8 字节（rg 只给 `lines.bytes` 而无 `lines.text`）时替换不再注入多余字符、漏替该行或重复内容；现在回退用 base64 解码原始字节，非法字节原样保留、所有匹配正确替换
- Replace 框首尾空白不再被 `vim.trim` 悄悄抹掉；现在 replace 内容字段保留有意输入的缩进或尾随空格写盘（search/include/exclude/cwd 仍保持 trim）
- 替换进行中关闭面板（`q` / `<Esc>` 或 `:q` / `:bd`）不再抛 `Invalid buffer id` 错误、也不再让替换状态卡死；现在关闭后会安全中止，剩余匹配可重新搜索替换补齐
- 改完 Replace 框后立即按替换不再可能用改动前的旧替换文本写盘；替换前若搜索结果尚未跟上当前输入，会自动先重新搜索，确保写盘内容与界面一致
- Replace 框为空时结果预览不再把所有匹配标成删除红；现在按普通搜索高亮，删除态只在确认删除时才呈现（空替换=删除匹配的语义不变，仍受 `Delete all matches?` 确认保护）
- 在文件名 header 行按 `<CR>` 或鼠标点击跳转时，若源窗口已被手动关闭不再报 `Invalid window id`；现在安全回退到上一个窗口
- flash 状态提示（toast）的一次性定时器触发后不再泄漏 libuv handle，且新 toast 显示期间不再被上一个已过期的状态提示意外覆盖
- 面板 buffer 被 `:split` 到其它窗口、原窗口已关闭时，光标跳转 / 预览不再因读取已失效窗口而报 `Invalid window id`
