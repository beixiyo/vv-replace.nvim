-- 从当前配置生成快捷键帮助

local HelpPanel = require('vv-utils.help_panel')

local M = {}

---@param ctx VVReplaceCtx
function M.open(ctx)
  local ic = ctx.config and ctx.config.icons or {}
  local actions = {
    ['toggle search mode (plainText ↔ regex)'] = { cat = 'Navigate', icon = ic.toggle_mode },
    ['recall previous input'] = { cat = 'Navigate', icon = ic.prev_match },
    ['recall next input'] = { cat = 'Navigate', icon = ic.next_match },
    ['clear current input'] = { cat = 'Navigate' },
    ['jump to match under cursor'] = { cat = 'Navigate', icon = ic.goto_match },
    ['jump to next match'] = { cat = 'Navigate', icon = ic.next_match },
    ['jump to previous match'] = { cat = 'Navigate', icon = ic.prev_match },
    ['replace all matches (with confirm)'] = { cat = 'Replace', icon = ic.replace_all },
    ['undo last replacement'] = { cat = 'Replace', icon = ic.undo_last },
    ['close panel'] = { cat = 'Panel', icon = ic.close },
    ['show this help'] = { cat = 'Panel', icon = ic.help },
  }

  if ctx.config.keymaps.next_input then
    actions['cycle next input (Search/Replace/...)'] = { cat = 'Navigate', icon = ic.next_input }
  end
  if ctx.scope ~= 'file' then
    actions['toggle hidden files'] = { cat = 'Navigate', icon = ic.toggle_hidden }
    actions['toggle git-ignored files'] = { cat = 'Navigate', icon = ic.toggle_gitignored }
  end

  HelpPanel.open({
    source_buf = ctx.buf,
    desc_prefix = 'vv-replace: ',
    actions = actions,
    categories = { 'Navigate', 'Replace', 'Panel' },
    title = 'vv-replace keymaps',
    title_icon = ic.title,
    filetype = 'vv-replace-help',
  })
end

return M
