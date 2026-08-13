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
local Input = require('vv-utils.input')
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
    keymaps = {
      next_input = '<C-j>',
      toggle_mode = '<S-Tab>',
      help = 'g?',
      close = 'q',
      goto_match = '<CR>',
      next_match = '<C-n>',
      prev_match = '<C-p>',
    },
    icons = {
      title = '[title]',
      next_input = '[field]',
      toggle_mode = '[mode]',
      help = '[help]',
      close = '[close]',
      goto_match = '[open]',
      next_match = '[next]',
      prev_match = '[prev]',
      replace_all = '[apply]',
      undo_last = '[undo]',
    },
  },
  state = {},
  keymap_labels = {
    next_input = Input.display_key('<C-j>'),
    toggle_mode = Input.display_key('<S-Tab>'),
    replace_all = Input.display_key('<localleader>r'),
    undo_last = Input.display_key('<localleader>u'),
    goto_match = Input.display_key('<CR>'),
    next_match = Input.display_key('<C-n>'),
    prev_match = Input.display_key('<C-p>'),
    close = Input.display_key('q'),
    help = Input.display_key('g?'),
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
assert_eq(#Inputs.visible_fields(ctx), 2)
assert(ctx.extmark_ids.search and ctx.extmark_ids.search_ph)
assert(ctx.extmark_ids.replace and ctx.extmark_ids.replace_ph)
assert_eq(ctx.extmark_ids.include, nil)
assert_eq(text:sub(-#'[apply] \\r Apply'), '[apply] \\r Apply')
assert(not text:find('Undo', 1, true), text)
assert(not Replace._can_undo())
assert_eq(chunks[#chunks][2], 'VVReplacePlaceholder')
local info = vim.fn.getwininfo(win)[1]
assert_eq(vim.fn.strdisplaywidth(text), vim.api.nvim_win_get_width(win) - (info.textoff or 0))

local search_label_id = ctx.extmark_ids.search
local search_placeholder_id = ctx.extmark_ids.search_ph
vim.api.nvim_win_set_width(win, 80)
Inputs.render(ctx)
assert_eq(ctx.extmark_ids.search, search_label_id)
assert_eq(ctx.extmark_ids.search_ph, search_placeholder_id)

local winbar = vim.wo[win].winbar
assert(winbar:find('[title] Replace', 1, true), winbar)
assert(winbar:find('[field] ^j Field', 1, true), winbar)
assert(winbar:find('[help] g?', 1, true), winbar)
assert(winbar:find('[close] q', 1, true), winbar)

local search_mark = vim.api.nvim_buf_get_extmark_by_id(buf, ctx.namespace, ctx.extmark_ids.search, { details = true })
local search_label = vim.iter(search_mark[3].virt_lines[1]):fold('', function(acc, chunk)
  return acc .. chunk[1]
end)
assert(search_label:find('[mode]', 1, true), search_label)

local results_mark = vim.api.nvim_buf_get_extmark_by_id(buf, ctx.namespace, ctx.extmark_ids.results_header, { details = true })
local results_label = vim.iter(results_mark[3].virt_lines[1]):fold('', function(acc, chunk)
  return acc .. chunk[1]
end)
assert(results_label:find('[prev] ' .. Input.display_key('<C-p>'), 1, true), results_label)
assert(results_label:find('[next] ' .. Input.display_key('<C-n>'), 1, true), results_label)
assert(results_label:find('[open] ' .. Input.display_key('<CR>') .. ' Open', 1, true), results_label)

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
assert_eq(#Inputs.visible_fields(ctx), 5)
for _, field in ipairs(Inputs.visible_fields(ctx)) do
  local label_mark = vim.api.nvim_buf_get_extmark_by_id(
    buf,
    ctx.namespace,
    ctx.extmark_ids[field.name],
    { details = true }
  )
  local placeholder_mark = vim.api.nvim_buf_get_extmark_by_id(
    buf,
    ctx.namespace,
    ctx.extmark_ids[field.name .. '_ph'],
    { details = true }
  )
  local label = vim.iter(label_mark[3].virt_lines[1]):fold('', function(acc, chunk)
    return acc .. chunk[1]
  end)

  assert(label:find(field.label, 1, true), label)
  assert_eq(placeholder_mark[3].virt_text[1][1], field.placeholder)
  assert_eq(placeholder_mark[3].virt_text[1][2], 'VVReplacePlaceholder')
end
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

ctx.scope = 'file'
Inputs.render(ctx)
assert_eq(#Inputs.visible_fields(ctx), 2)
for _, name in ipairs({ 'include', 'exclude', 'cwd' }) do
  assert_eq(ctx.extmark_ids[name], nil)
  assert_eq(ctx.extmark_ids[name .. '_ph'], nil)
end
print('PASS: vv-replace undo hint integration')
