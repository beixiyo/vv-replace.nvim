---@class VVReplaceResultMark
---@field row integer  buffer 内 0-based 行
---@field kind 'file'|'match'  file=文件 header，match=匹配源
---@field filename string
---@field lnum? integer  match 时的文件内 1-based 行号
---@field col? integer  match 时的列号（1-based）
---@field text? string  匹配行原文本
---@field submatches? table[]  rg submatches（含 start/end/replacement）

---@class VVReplaceParsed
---@field lines string[]  要写入 buffer 的所有行（不含 header 分隔行）
---@field marks VVReplaceResultMark[]  每行的元数据
---@field highlights VVReplaceHighlight[]  高亮范围
---@field inlines VVReplaceInline[]  行内 virtual text（替换预览）
---@field stats { files: integer, matches: integer }

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
