-- rg --json 搜索
--
-- 设计：
--   * 单一 debounce timer：输入变化 → 200ms 后真正执行 rg
--   * 每次新搜索先 kill 上一次的 rg 进程
--   * stdout 流式解析：NDJSON（一行一个 JSON）
--   * smart case：搜索词含大写 → -s，否则 -i
--   * 结果分两阶段收集：
--     1. 收集全部 json 到 ctx.state.last_json（供 replace 复用，免再跑一次 rg）
--     2. 所有进程结束后一次性 parse + render（避免流式 render 对 UI 的反复刷新）
--     —— 对中等大小项目足够快；真要处理巨大项目再加批处理

local Inputs = require('vv-replace.inputs')
local Render = require('vv-replace.render')

local M = {}

---@param s string
---@return boolean
local function has_uppercase(s)
  return s:match('%u') ~= nil
end

---@param raw string
---@return string[]
local function split_globs(raw)
  if not raw or raw == '' then return {} end
  local list = {}
  for part in string.gmatch(raw, '[^,]+') do
    local trimmed = vim.trim(part)
    if trimmed ~= '' then list[#list + 1] = trimmed end
  end
  return list
end

-- 构造 rg 命令参数列表
---@param ctx VVReplaceCtx
---@param values table<string, string>
---@return string[]? args 为 nil 表示搜索词为空，跳过搜索
local function build_rg_args(ctx, values)
  local search = values.search
  if not search or search == '' then return nil end

  local args = { '--json', '--color=never', '--line-number', '--no-heading' }

  -- smart case
  if has_uppercase(search) then
    args[#args + 1] = '--case-sensitive'
  else
    args[#args + 1] = '--ignore-case'
  end

  -- 模式
  if ctx.mode == 'plainText' then
    args[#args + 1] = '--fixed-strings'
  end
  -- regex 模式用 rg 默认

  -- 搜索范围（yazi/vv-explorer 风的两个独立开关，默认与 rg 默认行为一致）：
  --   show_hidden  → --hidden    包含隐藏文件（dotfile/.env 等）
  --   show_ignored → --no-ignore 包含 .gitignore 等忽略文件（node_modules/dist 等）
  if ctx.show_hidden then
    args[#args + 1] = '--hidden'
  end
  if ctx.show_ignored then
    args[#args + 1] = '--no-ignore'
  end

  -- context
  if ctx.config.context_lines and ctx.config.context_lines > 0 then
    args[#args + 1] = '--context=' .. tostring(ctx.config.context_lines)
  end

  -- max count（保护性限制，--max-count 是单文件上限，不是总上限；总上限在解析端截断）
  -- 这里用 --max-columns 防行太长导致 rg 内存暴涨
  args[#args + 1] = '--max-columns=500'

  -- include / exclude
  for _, g in ipairs(split_globs(values.include)) do
    args[#args + 1] = '-g'
    args[#args + 1] = g
  end
  for _, g in ipairs(split_globs(values.exclude)) do
    args[#args + 1] = '-g'
    args[#args + 1] = '!' .. g
  end

  -- 额外用户参数
  for _, extra in ipairs(ctx.config.rg_extra_args or {}) do
    args[#args + 1] = extra
  end

  -- 替换（传给 rg 就有 submatch.replacement.text，供预览和 replace 写回复用）
  -- Replace 框为空时不传 --replace=，让预览走普通搜索高亮（VVReplaceMatch）而非删除红；
  -- 删除匹配仍可工作：compute_new_content 在 submatch 无 replacement 时 rep 默认 ''（即删除），
  -- 且删除受 replace_all 的「Delete all matches?」确认保护，不会误删
  if values.replace ~= nil and values.replace ~= '' then
    args[#args + 1] = '--replace=' .. values.replace
  end

  -- 搜索词（必须在位置参数之前，用 -e 避免首字符 `-` 被误认 flag）
  args[#args + 1] = '-e'
  args[#args + 1] = search

  -- 路径
  if ctx.scope == 'file' and ctx.target_file then
    args[#args + 1] = ctx.target_file
  else
    local cwd = values.cwd ~= '' and values.cwd or ctx.cwd
    args[#args + 1] = cwd
  end

  return args
end

-- 按行范围过滤 rg json：丢掉范围外的 match，以及随之变空的 begin/end 块
---@param collected any[]
---@param range integer[]?  { start, end } 1-based inclusive
---@return any[]
local function filter_by_range(collected, range)
  if not range then return collected end
  local lo, hi = range[1], range[2]
  local out = {}
  local pending_begin = nil
  local block_has_match = false
  for _, obj in ipairs(collected) do
    if obj.type == 'begin' then
      pending_begin = obj
      block_has_match = false
    elseif obj.type == 'match' then
      local ln = obj.data and obj.data.line_number or 0
      if ln >= lo and ln <= hi then
        if pending_begin then
          out[#out + 1] = pending_begin
          pending_begin = nil
        end
        out[#out + 1] = obj
        block_has_match = true
      end
    elseif obj.type == 'end' then
      if block_has_match then out[#out + 1] = obj end
      pending_begin = nil
      block_has_match = false
    else
      out[#out + 1] = obj
    end
  end
  return out
end

-- 解析一批 NDJSON 行
---@param text string 若干行 JSON，最后一行可能不完整
---@param buffer string 上次遗留的不完整行
---@return any[] parsed, string new_buffer
local function parse_ndjson_chunk(text, buffer)
  local parsed = {}
  local combined = buffer .. text
  local start = 1
  while true do
    local nl = combined:find('\n', start, true)
    if not nl then break end
    local line = combined:sub(start, nl - 1)
    start = nl + 1
    if #line > 0 then
      local ok, obj = pcall(vim.json.decode, line)
      if ok then parsed[#parsed + 1] = obj end
    end
  end
  return parsed, combined:sub(start)
end

-- 取消上一次搜索（kill 进程 + 关 timer）
---@param ctx VVReplaceCtx
local function abort_current(ctx)
  if ctx.state.rg_abort then
    pcall(ctx.state.rg_abort)
    ctx.state.rg_abort = nil
  end
end

-- 真正跑一次搜索
---@param ctx VVReplaceCtx
---@param on_done fun()?  本次搜索完成（写完 last_json）后回调，供 replace 等到新鲜结果再继续
local function run_search(ctx, on_done)
  if ctx.state.closed then return end
  abort_current(ctx)

  local values = Inputs.get_values(ctx)
  local args = build_rg_args(ctx, values)

  -- 空搜索词：清空结果区
  if not args then
    ctx.state.last_json = nil
    -- 记录本次搜索所用输入：replace 用它判断 last_json 是否对应当前输入（而非已被提前更新的 last_inputs）
    ctx.state.last_searched_inputs = vim.deepcopy(values)
    ctx.state.searching = false
    Render.clear_results(ctx)
    Render.render_status(ctx, '')
    return
  end

  ctx.state.searching = true
  Render.render_status(ctx, 'Searching...')

  local collected = {}
  local stdout_buf = ''
  local stderr_buf = ''
  local finished = false
  local max = ctx.config.max_results
  local truncated = false

  local job
  job = vim.system({ 'rg', unpack(args) }, {
    text = true,
    cwd = (ctx.scope == 'file') and nil or (values.cwd ~= '' and values.cwd or ctx.cwd),
    stdout = function(err, data)
      if finished or err or not data then return end
      local parsed, new_buf = parse_ndjson_chunk(data, stdout_buf)
      stdout_buf = new_buf
      for _, obj in ipairs(parsed) do
        if obj.type == 'match' then
          if #collected < max * 3 then  -- begin/match/end 各一条，留 3 倍 headroom
            collected[#collected + 1] = obj
          else
            truncated = true
          end
        else
          collected[#collected + 1] = obj
        end
      end
      if truncated and job then
        pcall(function() job:kill('sigterm') end)
      end
    end,
    stderr = function(err, data)
      if err or not data then return end
      stderr_buf = stderr_buf .. data
    end,
  }, function(result)
    if finished then return end
    finished = true
    vim.schedule(function()
      if ctx.state.closed then return end
      -- flush 最后一段
      if #stdout_buf > 0 then
        local ok, obj = pcall(vim.json.decode, stdout_buf)
        if ok then collected[#collected + 1] = obj end
      end

      ctx.state.searching = false
      local filtered = filter_by_range(collected, ctx.target_range)
      ctx.state.last_json = filtered
      -- 与 last_json 同步记录其来源输入：被 abort/kill 的旧搜索因上方 finished 守卫不会走到这里，
      -- 故 last_searched_inputs 始终对应当前 last_json，replace 据此判新鲜
      ctx.state.last_searched_inputs = vim.deepcopy(values)

      local parsed = Render.parse_results(filtered, values.replace ~= nil and values.replace ~= '')
      Render.render_results(ctx, parsed)

      if result.code ~= 0 and result.code ~= 1 and parsed.stats.files == 0 then
        -- code 1 = no matches（正常），其他非零 + 无结果 = 真错误
        Render.render_status(ctx, 'Error: ' .. (stderr_buf ~= '' and vim.trim(stderr_buf) or 'rg exit code ' .. result.code), true)
      else
        local status = string.format('%d matches in %d files%s',
          parsed.stats.matches, parsed.stats.files,
          truncated and '  (truncated)' or '')
        Render.render_status(ctx, status)
      end

      -- 结果已落盘且渲染完毕，通知等待方（如 replace 重搜后继续）
      if on_done then on_done() end
    end)
  end)

  ctx.state.rg_abort = function()
    if finished then return end
    finished = true
    pcall(function() job:kill('sigterm') end)
  end
end

-- 输入变化入口：比对 last_inputs，变了就 debounce 调度
---@param ctx VVReplaceCtx
function M.on_change(ctx)
  if ctx.state.closed then return end
  local values = Inputs.get_values(ctx)
  if ctx.state.last_inputs and vim.deep_equal(values, ctx.state.last_inputs) then
    return
  end
  ctx.state.last_inputs = vim.deepcopy(values)

  if not ctx.state.search_timer then
    ctx.state.search_timer = vim.uv.new_timer()
  end
  local timer = ctx.state.search_timer
  if not timer then return end
  timer:stop()
  -- 空搜索立即清空，不用等 debounce
  if not values.search or values.search == '' then
    run_search(ctx)
    return
  end
  timer:start(ctx.config.debounce_ms, 0, vim.schedule_wrap(function()
    if ctx.state.closed then return end
    run_search(ctx)
  end))
end

-- 手动立即搜索（供 actions 调用，例如 <CR> / :VVReplaceRefresh）
---@param ctx VVReplaceCtx
---@param on_done fun()?  搜索完成回调，供 replace 等到新鲜结果再继续替换
function M.search_now(ctx, on_done)
  if ctx.state.search_timer then ctx.state.search_timer:stop() end
  run_search(ctx, on_done)
end

return M
