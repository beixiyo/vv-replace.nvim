-- vv-replace 撤回与输入提示集成测试
-- 运行：nvim --headless -u NONE -l tests/test_transaction.lua

package.path = table.concat({
  './lua/?.lua',
  './lua/?/init.lua',
  '../vv-utils.nvim/lua/?.lua',
  '../vv-utils.nvim/lua/?/init.lua',
  package.path,
}, ';')

local Inputs = require('vv-replace.inputs')
local Replace = require('vv-replace.replace')
local Render = require('vv-replace.render')
local Glob = require('vv-utils.glob')

local function assert_eq(actual, expected)
  assert(actual == expected, string.format('expected %q, got %q', tostring(expected), tostring(actual)))
end

vim.g.maplocalleader = '\\'

local buf = vim.api.nvim_create_buf(false, true)
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, buf)
vim.api.nvim_win_set_width(win, 50)
vim.bo[buf].modifiable = false

local ctx = {
  buf = buf,
  win = win,
  namespace = vim.api.nvim_create_namespace('vv-replace-test'),
  extmark_ids = {},
  mode = 'plainText',
  scope = 'file',
  config = {
    keymaps = { help = 'g?', toggle_mode = '<S-Tab>' },
    icons = {},
  },
  state = {},
  keymap_labels = {
    replace_all = Inputs.display_key('<localleader>r'),
    undo_last = Inputs.display_key('<localleader>u'),
  },
}

local function render_hint()
  Inputs.render(ctx)
  assert_eq(vim.bo[buf].modifiable, false)
  local mark = vim.api.nvim_buf_get_extmark_by_id(buf, ctx.namespace, ctx.extmark_ids.replace, { details = true })
  local chunks = mark[3].virt_lines[1]
  local text = ''
  for _, chunk in ipairs(chunks) do text = text .. chunk[1] end
  return text, chunks
end

local text, chunks = render_hint()
assert(text:find('\\r Apply$', 1) ~= nil, text)
assert(not text:find('Undo', 1, true), text)
assert(not Replace._can_undo())
assert_eq(chunks[#chunks][2], 'VVReplacePlaceholder')
local info = vim.fn.getwininfo(win)[1]
assert_eq(vim.fn.strdisplaywidth(text), vim.api.nvim_win_get_width(win) - (info.textoff or 0))

local globs = assert(Glob.split('*.{ts,tsx}, **/*.test.ts, **/[a,b].txt, file\\,name.txt'))
assert_eq(#globs, 4)
assert_eq(globs[1], '*.{ts,tsx}')
assert_eq(globs[2], '**/*.test.ts')
assert_eq(globs[3], '**/[a,b].txt')
assert_eq(globs[4], 'file\\,name.txt')

local full_path = '/private/tmp/project/packages/web/src/routes/admin/index.tsx'
local parsed = Render.parse_results({
  { type = 'begin', data = { path = { text = full_path } } },
  { type = 'end', data = {} },
}, false, { root = '/private/tmp/project' })
assert_eq(parsed.lines[1], 'packages/…/routes/admin/index.tsx')
assert_eq(parsed.marks[1].filename, full_path)

local relative_parsed = Render.parse_results({
  { type = 'begin', data = { path = { text = './packages/core/src/index.ts' } } },
  { type = 'end', data = {} },
}, false, { root = '/private/tmp/project' })
assert_eq(relative_parsed.lines[1], 'packages/core/src/index.ts')
assert_eq(relative_parsed.marks[1].filename, '/private/tmp/project/packages/core/src/index.ts')

local error_text = "Error: rg: error parsing glob '*.{ts': unclosed alternate group"
Render.render_status(ctx, error_text, true)
local status_row = Inputs.results_header_row(ctx)
local status = vim.api.nvim_buf_get_lines(buf, status_row, status_row + 1, false)[1]
assert_eq(status, '')
local status_mark = vim.api.nvim_buf_get_extmark_by_id(buf, ctx.namespace, ctx.extmark_ids.status, { details = true })
assert_eq(status_mark[3].virt_text[1][1], '── ' .. error_text .. ' ──')

ctx.scope = 'project'
ctx.cwd = '/private/tmp/project'
Inputs.render(ctx)
Inputs.fill(ctx, {
  search = 'VV_REPLACE_TOKEN',
  replace = 'VV_REPLACE',
  include = '*.{ts,tsx}',
  exclude = '**/*.test.ts',
  cwd = ctx.cwd,
})
Render.render_status(ctx, '7 matches in 6 files')

local include_row = 2
vim.api.nvim_win_set_cursor(win, { include_row + 1, 0 })
assert(Inputs.clear_current(ctx))
Inputs.render(ctx)

local values = Inputs.get_values(ctx)
assert_eq(values.include, '')
assert_eq(values.exclude, '**/*.test.ts')
assert_eq(values.cwd, ctx.cwd)
assert_eq(vim.api.nvim_buf_get_lines(buf, Inputs.results_header_row(ctx), Inputs.results_header_row(ctx) + 1, false)[1], '')
print('PASS: vv-replace undo hint integration')
