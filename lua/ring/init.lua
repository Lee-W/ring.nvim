local M = {}

local defaults = {
  command = { "ring", "--format", "json" },
  interval = 2000,
  timeout = 5000,
  icon = "🔴",
  hide_when_zero = true,
}

local config = vim.deepcopy(defaults)
local timer
local started = false
local generation = 0
local state = {
  waiting = 0,
  running = false,
  last_error = nil,
  updated_at = nil,
}

local function redraw()
  if vim.api.nvim_get_vvar("exiting") == vim.NIL then
    vim.cmd("redrawstatus")
  end
end

local function apply_result(result, current_generation)
  if current_generation ~= generation then
    return
  end
  state.running = false
  if result.code ~= 0 then
    state.last_error = vim.trim(result.stderr or "ring exited with an error")
    return
  end

  local ok, data = pcall(vim.json.decode, result.stdout or "")
  local waiting = ok
      and type(data) == "table"
      and type(data.counts) == "table"
      and tonumber(data.counts.waiting)
  if not waiting then
    state.last_error = "ring returned invalid JSON"
    return
  end

  state.waiting = waiting
  state.last_error = nil
  state.updated_at = os.time()
  redraw()
end

function M.refresh()
  if state.running then
    return
  end
  state.running = true
  local current_generation = generation
  local ok, err = pcall(vim.system, config.command, { text = true, timeout = config.timeout }, function(result)
    vim.schedule(function()
      apply_result(result, current_generation)
    end)
  end)
  if not ok then
    state.running = false
    state.last_error = vim.trim(tostring(err))
  end
end

function M.start()
  if started then
    return
  end
  started = true
  M.refresh()
  if config.interval > 0 then
    timer = assert(vim.uv.new_timer())
    timer:start(config.interval, config.interval, vim.schedule_wrap(M.refresh))
  end
end

function M.stop()
  generation = generation + 1
  started = false
  state.running = false
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

function M.setup(opts)
  opts = opts or {}
  vim.validate({
    command = { opts.command, "table", true },
    interval = { opts.interval, "number", true },
    timeout = { opts.timeout, "number", true },
    icon = { opts.icon, "string", true },
    hide_when_zero = { opts.hide_when_zero, "boolean", true },
  })
  if opts.command and (#opts.command == 0 or not vim.iter(opts.command):all(function(value)
    return type(value) == "string"
  end)) then
    error("command must be a non-empty list of strings")
  end
  if opts.interval and opts.interval < 0 then
    error("interval must be greater than or equal to zero")
  end
  if opts.timeout and opts.timeout <= 0 then
    error("timeout must be greater than zero")
  end
  M.stop()
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  M.start()
end

function M.status()
  M.start()
  if config.hide_when_zero and state.waiting == 0 then
    return ""
  end
  return config.icon .. tostring(state.waiting)
end

function M.get_state()
  return vim.deepcopy(state)
end

return M
