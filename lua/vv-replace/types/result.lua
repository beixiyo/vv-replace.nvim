---@class VVReplaceResultMark
---@field row integer  buffer 内 0-based 行
---@field kind 'file'|'match'  file=文件 header，match=匹配源
---@field filename string
---@field lnum? integer  match 时的文件内 1-based 行号
---@field col? integer  match 时的列号（1-based）
---@field text? string  匹配行原文本
---@field submatches? table[]  rg submatches（含 start/end/replacement）
---@field folded? boolean  file 时该文件是否折叠（折叠后匹配行不渲染，文件行可停留）
---@field count? integer  file 时该文件的匹配行数（含折叠未渲染的）

---@class VVReplaceFileGroup
---@field filename string  规范化后的绝对路径，也是折叠状态的 key
---@field display_path string  相对搜索根的未压缩路径；压缩在 layout 时按宽度进行
---@field matches VVReplaceMatchItem[]

---@class VVReplaceMatchItem
---@field kind 'match'
---@field filename string
---@field lnum integer  文件内 1-based 行号
---@field col integer  首个匹配的 1-based 列号
---@field text string  匹配行原文本（只取首行）
---@field submatches table[]  rg submatches（含 start/end/replacement）
---@field highlights { col_start: integer, col_end: integer, hl_group: string }[]  相对 text 的高亮
---@field inlines { col: integer, text: string, hl_group: string }[]  相对 text 的替换预览

---@class VVReplaceLayoutOpts
---@field width? integer  结果窗口文本区宽度；nil 时路径只做第一级折叠
---@field folded? table<string, true>  折叠的文件（key=filename）
---@field icons? VVReplaceIcons  取 fold_open / fold_closed；缺省用内置 chevron

---@class VVReplaceParseOpts: VVReplaceLayoutOpts
---@field root? string  显示路径的相对根

---@class VVReplaceParsed
---@field files VVReplaceFileGroup[]  布局无关的文件分组
---@field lines string[]  要写入 buffer 的所有行（不含 header 分隔行）
---@field marks VVReplaceResultMark[]  每行的元数据（row 为结果区内偏移）
---@field highlights VVReplaceHighlight[]  高亮范围
---@field inlines VVReplaceInline[]  行内 virtual text（替换预览）
---@field stats? { files: integer, matches: integer }  parse_results 填写；layout 不含

---@class VVReplaceHighlight
---@field row integer
---@field col_start integer
---@field col_end integer
---@field hl_group string

---@class VVReplaceInline
---@field row integer
---@field col integer
---@field text string
---@field hl_group string
