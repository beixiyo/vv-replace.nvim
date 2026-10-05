-- 每个 case 独立 Neovim；post_case 即使断言失败也停止子进程、恢复权限并清理 fixture
local M = {}

function M.eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected), (message or '值不一致') .. ': 期望 '
    .. vim.inspect(expected) .. ', 实际 ' .. vim.inspect(actual))
end

function M.wait(predicate, message)
  assert(vim.wait(30000, predicate, 5), message or '操作超时')
end

-- 独立于生产 fs 的二进制读回，连未匹配行、CRLF、末尾换行也一起比较
function M.read(path)
  local file = assert(io.open(path, 'rb'))
  local bytes = file:read('*a')
  assert(file:close())
  return bytes
end

function M.fixture(files)
  local root = assert(vim.uv.fs_realpath(vim.env.VV_TEST_TMP))
  local snapshot = {}
  for name, bytes in pairs(files) do
    local path = vim.fs.joinpath(root, name)
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    local file = assert(io.open(path, 'wb'))
    assert(file:write(bytes))
    assert(file:close())
    snapshot[path] = bytes
  end
  return root, snapshot
end

function M.assert_files(snapshot, transform)
  for path, bytes in pairs(snapshot) do
    M.eq(M.read(path), transform and transform(bytes) or bytes, '文件完整字节：' .. path)
  end
end

function M.open_project(root, opts)
  local Replace = require('vv-replace')
  vim.cmd.cd(vim.fn.fnameescape(root))
  Replace.setup(vim.tbl_extend('force', {
    debounce_ms = 60000, history_persist = false,
    state = require('vv-utils.state').register('vv-replace', 'panel', {
      path = vim.fs.joinpath(vim.env.VV_TEST_TMP, 'panel-state.json'),
    }),
  }, opts or {}))
  Replace.open({ scope = 'project', cwd = root })
  vim.cmd('stopinsert')
  return assert(require('vv-replace.buffer').current)
end

-- Inputs.fill 会跳过空串；真正清空输入必须覆盖整行
function M.fill(ctx, values)
  local Model = require('vv-replace.inputs.model')
  for name, value in pairs(values) do
    local row = Model.field_row(ctx, name)
    local line = vim.api.nvim_buf_get_lines(ctx.buf, row, row + 1, false)[1] or ''
    vim.api.nvim_buf_set_text(ctx.buf, row, 0, row, #line, { value })
  end
end

function M.search(ctx)
  local done = false
  require('vv-replace.search').search_now(ctx, function() done = true end)
  M.wait(function() return done end, '真实 rg 搜索超时')
end

function M.settle(ctx)
  M.wait(function()
    return not ctx.state.replacing and not ctx.state.searching and not require('vv-replace.render').is_loading(ctx)
  end, '操作与刷新尚未结束，加载指示未释放')
end

function M.loading_text(ctx)
  local row = require('vv-replace.render').header_row(ctx)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ctx.buf, -1, { row, 0 }, { row, -1 }, { details = true })) do
    local chunks = mark[4].virt_text or {}
    if chunks[1] and chunks[1][2] == 'VVLoading' then
      local text = ''
      for _, chunk in ipairs(chunks) do
        text = text .. chunk[1]
      end
      return text
    end
  end
end

function M.status_text(ctx)
  local id = ctx.extmark_ids.status
  if not id then
    return nil
  end
  local mark = vim.api.nvim_buf_get_extmark_by_id(ctx.buf, ctx.namespace, id, { details = true })
  return mark[3] and mark[3].virt_text and mark[3].virt_text[1][1]
end

function M.press(key, mode)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), mode or 'mx', false)
end

---@return table set
---@return table child
---@return function restart 保留 fixture，仅重启本集合子进程
function M.new_set()
  local MiniTest = require('mini.test')
  local child = MiniTest.new_child_neovim()
  local root
  local function start()
    child.start({ '-u', 'NONE', '-i', 'NONE' }, { nvim_executable = vim.v.progpath })
    child.lua([[
      vim.opt.packpath = ''
      dofile(vim.env.VV_UTILS .. '/dev/test/runtime.lua').apply()
      vim.opt.runtimepath:prepend(vim.env.VV_TEST_REPO)
      vim.opt.runtimepath:prepend(vim.env.VV_UTILS)
      Helpers = dofile(vim.env.VV_TEST_REPO .. '/tests/helpers.lua')
      notifications, allowed_errors = {}, {}
      vim.notify = function(msg, level)
        notifications[#notifications + 1] = { msg = tostring(msg), level = level }
      end
    ]])
    child.env.VV_TEST_TMP = root
    child.v.errmsg = ''
  end
  local function check_errors()
    MiniTest.expect.equality(child.v.errmsg, '')
    local errors = child.lua_get([[ (function()
      local errors = {}
      for _, item in ipairs(notifications) do
        if item.level == vim.log.levels.ERROR then
          local allowed = false
          for _, pattern in ipairs(allowed_errors) do
            if item.msg:find(pattern) then allowed = true end
          end
          if not allowed then errors[#errors + 1] = item.msg end
        end
      end
      return errors
    end)() ]])
    MiniTest.expect.equality(errors, {})
  end
  local T = MiniTest.new_set({
    hooks = {
      pre_case = function()
        root = vim.fn.tempname()
        vim.fn.mkdir(root, 'p')
        start()
      end,
      post_case = function()
        -- 先取证，随后无论取证/断言成功与否都必须停止进程
        local ok, err = pcall(function()
          child.lua("local R = package.loaded['vv-replace']; if R then R.close() end")
          check_errors()
        end)
        local stopped, stop_err = pcall(child.stop)
        if root then
          local blocked = vim.fs.joinpath(root, 'zz')
          if vim.fn.isdirectory(blocked) == 1 then
            vim.uv.fs_chmod(blocked, 493)
          end
          vim.fn.delete(root, 'rf')
        end
        assert(stopped, stop_err)
        assert(ok, err)
      end,
    },
  })
  return T, child, function()
    check_errors()
    child.stop()
    start()
  end
end

return M
