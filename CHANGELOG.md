# Changelog

## 0.5.0 - 2026-10-04

- 全部替换与撤回改为分片异步读写
- 搜索从输入防抖开始隐藏陈旧计数，延迟 150ms 显示 loading
- 替换 / 撤回结果与重搜计数合并显示，不再被搜索提示覆盖
- 写入前关闭面板取消操作；写入后关闭面板仍完成事务或回滚，并通过通知告知结果
- 结果区按文件折叠：`h` / `←` 折叠，`l` / `→` 展开，`j/k` / `↑/↓` 
- 文件路径随窗口宽度压缩，新增 `VVReplaceFileDir` / `VVReplaceFoldIcon` 高亮与 `icons.fold_open` / `icons.fold_closed`
- 结果区移除文件组间空行与行号后的冒号

## 0.4.1 - 2026-08-10

- 快捷键统一使用标准键位格式显示

## 0.4.0 - 2026-07-29

### Breaking

- 删除 `vv-replace.blink`；Include / Exclude / Cwd 改用 `vv-utils.completion` 与 `vv-utils.blink`，Search / Replace 改用 Blink 内置 buffer source

## 0.3.2 - 2026-07-26

- 手动调整的面板宽度跨关闭与 Neovim 重启持久化
- 输入 UI 在 winbar 集中显示 Field、Help、Close 操作

## 0.3.1 - 2026-07-19

- 批量替换事务迁移至 `vv-utils.fs.new_transaction()`，不再依赖已删除的 `vv-utils.fs_transaction`

## 0.3.0 - 2026-07-19

- 新增 `vv-replace.blink` 路径 source，支持按输入字段补全 buffer 词与路径
- `next_input` 默认改为 `<C-j>`，不再占用 `<Tab>` / `<CR>`；可设为 `false` 禁用

## 0.2.0 - 2026-07-19

- Replace 标签动态显示实际 `Apply` / `Undo` 快捷键，新增 `<localleader>u` / `:VVReplaceUndo` 撤回最近一次批量替换
- 批量替换改为事务式写入，统一预检、失败回滚并读回校验
- Include / Exclude 支持 VS Code 风格 glob 简写、Cwd 锚定与目录后代匹配，不再拆坏 brace glob
- 输入框 `dd` 改为清空字段，不再误删表单行
- 结果路径相对 Cwd 显示并压缩中间层级，跳转保留完整路径

## 0.1.0 - 2026-07-13

### Added

- `<C-n>` / `<C-p>` 在 normal 与 insert 模式循环跳转匹配并预览，支持 `keymaps.next_match` / `keymaps.prev_match` 配置
- 新增 `open_visual({ scope?, use })`：`use='query'` 将单行选区预填为搜索词，`use='range'` 将选中行限定为 file scope 替换范围
- 项目搜索新增隐藏文件与 gitignored 开关，默认均关闭；`.` / `I` 与 insert 可用的 `<M-h>` / `<M-i>` 切换后即时重搜，键位可配
- 光标移动时在源窗口实时预览文件与行，不切换焦点，并显示该文件全部匹配的删除 / 替换 diff
- normal 模式新增 `<Esc>` 关闭面板

### Changed

- 结果预览改为每个匹配一行的 inline diff，简化 `j/k` 导航

### Fixed

- 拒绝使用磁盘已改动文件的陈旧匹配位置写入，避免损坏文件；重搜后可继续替换
- 含非法 UTF-8 的匹配行保留原始字节并正确替换，不再漏替或重复内容
- Replace 字段保留有意输入的首尾空白，其他字段仍 trim
- 替换中关闭面板安全中止，不再报无效 buffer 或卡住替换状态
- 输入尚未同步时替换会先重搜，不再用旧替换文本写盘
- Replace 为空时预览显示普通搜索高亮，实际删除仍需 `Delete all matches?` 确认
- 源窗口关闭或面板被拆到其他窗口后，跳转 / 预览不再报无效窗口
- 状态提示不再泄漏 timer，新提示不再被过期提示覆盖
