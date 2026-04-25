-- 高亮组定义（走 vv-utils.hl：自动 default=true + ColorScheme 自动重挂）

local hl = require('vv-utils.hl')

local M = {}

function M.setup()
  hl.register('vv-replace.highlight', {
    VVReplaceLabel         = { link = 'Title' },
    -- mode 徽章：粉紫色 + bold，与 vv-dashboard 的品牌词同色，显眼又统一
    VVReplaceLabelMode     = { fg = '#ff6ac1', bold = true },
    VVReplaceLabelModeOn   = { link = 'IncSearch' },   -- 模式切换瞬时闪一下
    VVReplacePlaceholder   = { link = 'Comment' },
    VVReplaceInputSearch   = { link = 'Normal' },
    VVReplaceInputReplace  = { link = 'Normal' },
    VVReplaceSeparator     = { link = 'WinSeparator' },

    VVReplaceResultsHeader = { link = 'Comment' },
    VVReplaceFilePath      = { link = 'Directory' },
    VVReplaceFileCount     = { link = 'Comment' },
    VVReplaceLineNumber    = { link = 'LineNr' },
    VVReplaceMatch         = { link = 'Search' },
    VVReplaceMatchRemoved  = { link = 'DiffDelete' },
    VVReplaceMatchAdded    = { link = 'DiffAdd' },
    VVReplaceDiffRemoved   = { link = 'DiffDelete' },
    VVReplaceDiffAdded     = { link = 'DiffAdd' },

    VVReplaceStatus        = { link = 'Comment' },
    VVReplaceStatusError   = { link = 'ErrorMsg' },
    VVReplaceStatusOk      = { link = 'DiagnosticOk' },
    VVReplaceToast         = { link = 'IncSearch' },   -- 切换模式的 toast 高亮
  })
end

return M
