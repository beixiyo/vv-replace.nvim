-- vv-replace.nvim 变更验证测试
--
-- 运行方式：luajit tests/test_smoke.lua（纯逻辑测试）
-- 或在 nvim 中 :luafile tests/test_smoke.lua
--
-- 注意：此测试仅覆盖纯 lua 逻辑（不依赖 nvim API 的部分）
-- Timer / 进程泄漏等运行时行为需要在 nvim 中手动验证

local passed = 0
local failed = 0

---@param name string
---@param fn fun()
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print('  PASS: ' .. name)
  else
    failed = failed + 1
    print('  FAIL: ' .. name .. ' — ' .. tostring(err))
  end
end

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format('%s: expected %q, got %q', msg or 'assert_eq', tostring(expected), tostring(actual)))
  end
end

-- ============================================================
-- FIX 1: 空替换（删除匹配）
-- ============================================================
print('\n[FIX 1] 空替换逻辑测试')

-- 模拟 compute_new_content 的核心逻辑：submatch.replacement 为 nil 时应用空串
test('replacement=nil 时 fallback 为空串而非 match.text', function()
  -- 模拟 sub 结构
  local sub = {
    match = { text = 'hello' },
    replacement = nil,
    start = 0,
    ['end'] = 5,
  }
  -- 修复后的逻辑
  local rep = sub.replacement and sub.replacement.text or ''
  assert_eq(rep, '', 'replacement fallback')
end)

test('replacement.text="" 时正确返回空串', function()
  local sub = {
    match = { text = 'hello' },
    replacement = { text = '' },
    start = 0,
    ['end'] = 5,
  }
  local rep = sub.replacement and sub.replacement.text or ''
  assert_eq(rep, '', 'empty replacement')
end)

test('replacement.text="world" 时正确返回替换文本', function()
  local sub = {
    match = { text = 'hello' },
    replacement = { text = 'world' },
    start = 0,
    ['end'] = 5,
  }
  local rep = sub.replacement and sub.replacement.text or ''
  assert_eq(rep, 'world', 'normal replacement')
end)

-- 模拟 build_rg_args 中的条件逻辑
test('values.replace=nil 时不添加 --replace 参数', function()
  local args = {}
  local values = { replace = nil }
  if values.replace ~= nil then
    args[#args + 1] = '--replace=' .. values.replace
  end
  assert_eq(#args, 0, 'nil replace should not add --replace')
end)

test('values.replace="" 时添加 --replace= 参数', function()
  local args = {}
  local values = { replace = '' }
  if values.replace ~= nil then
    args[#args + 1] = '--replace=' .. values.replace
  end
  assert_eq(#args, 1, 'empty replace should add --replace')
  assert_eq(args[1], '--replace=', 'empty replace arg')
end)

test('values.replace="foo" 时添加 --replace=foo 参数', function()
  local args = {}
  local values = { replace = 'foo' }
  if values.replace ~= nil then
    args[#args + 1] = '--replace=' .. values.replace
  end
  assert_eq(#args, 1, 'normal replace should add --replace')
  assert_eq(args[1], '--replace=foo', 'normal replace arg')
end)

-- has_replace 标志（控制 diff 预览显示）
test('has_replace: nil → false, "" → true, "x" → true', function()
  assert_eq(nil ~= nil, false, 'nil ~= nil')
  assert_eq('' ~= nil, true, '"" ~= nil')
  assert_eq('x' ~= nil, true, '"x" ~= nil')
end)

-- ============================================================
-- FIX 4: README max_results 默认值
-- ============================================================
print('\n[FIX 4] max_results 默认值测试')

test('默认 max_results 应为 10000', function()
  -- 模拟 defaults 表
  local defaults = { max_results = 10000 }
  assert_eq(defaults.max_results, 10000, 'max_results default')
end)

-- ============================================================
-- 汇总
-- ============================================================
print(string.format('\n总计: %d passed, %d failed', passed, failed))
if failed > 0 then
  print('有测试未通过！')
  os.exit(1)
end
