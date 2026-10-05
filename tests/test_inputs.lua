-- scope 切换与清空字段不能错位写入相邻输入；不逐项测试图标/文案/共享 glob
local T, child = dofile('tests/helpers.lua').new_set()

T['清空包含规则不影响相邻输入，文件范围移除项目级字段'] = function()
  child.lua_func(function()
    local H = Helpers
    local root = H.fixture({ ['a.ts'] = 'TOKEN\n' })
    local ctx = H.open_project(root)
    local Inputs = require('vv-replace.inputs')
    H.fill(ctx, { search = 'TOKEN', replace = 'DONE', include = '*.{ts,tsx}',
      exclude = '**/*.test.ts', cwd = root })
    H.search(ctx)
    Inputs.goto_field(ctx, 'include')
    assert(Inputs.clear_current(ctx), 'include 必须经生产动作清空')
    vim.bo[ctx.buf].modifiable = false
    Inputs.render(ctx)
    local values = Inputs.get_values(ctx)
    H.eq(values.include, '', '渲染后 include 为空')
    H.eq(values.search, 'TOKEN', 'search 未错位')
    H.eq(values.replace, 'DONE', 'replace 未错位')
    H.eq(values.exclude, '**/*.test.ts', 'exclude 未错位')
    H.eq(values.cwd, root, 'cwd 未错位')
    H.eq(vim.bo[ctx.buf].modifiable, false, 'render 不得解锁只读面板')

    ctx.scope = 'file'
    Inputs.render(ctx)
    H.eq(#Inputs.visible_fields(ctx), 2, 'file scope 不显示项目级输入')
    for _, name in ipairs({ 'include', 'exclude', 'cwd' }) do
      H.eq(ctx.extmark_ids[name], nil, '旧项目标签已移除：' .. name)
      H.eq(ctx.extmark_ids[name .. '_ph'], nil, '旧项目占位符已移除：' .. name)
    end
    H.eq(Inputs.get_value(ctx, 'search'), 'TOKEN', 'search 在 scope 重排后保留')
    H.eq(Inputs.get_value(ctx, 'replace'), 'DONE', 'replace 在 scope 重排后保留')
  end)
end

return T
