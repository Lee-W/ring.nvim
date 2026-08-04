local M = {}

local defaults = {
  command = { "ring", "--format", "json" },
  interval = 2000,
  timeout = 5000,
  icon = "🔴",
  error_icon = nil,
  hide_when_zero = true,
}

-- `vim.system()` reports a timeout as exit code 124, mirroring timeout(1).
local TIMEOUT_CODE = 124

local config = vim.deepcopy(defaults)
local timer
local started = false
local shutdown = false
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

-- Hand-rolled instead of vim.validate(): the table form is deprecated and the
-- replacement signature only exists on 0.11+, while this plugin supports 0.10.
local function check_type(name, value, expected)
  if value ~= nil and type(value) ~= expected then
    error(("ring.nvim: %s must be a %s, got %s"):format(name, expected, type(value)), 0)
  end
end

local function finish(current_generation, waiting, err)
  if current_generation ~= generation then
    return
  end
  state.running = false

  local changed = state.last_error ~= err or (waiting ~= nil and state.waiting ~= waiting)
  state.last_error = err
  if waiting ~= nil then
    state.waiting = waiting
    state.updated_at = os.time()
  end
  if changed then
    redraw()
  end
end

local function apply_result(result, current_generation)
  if result.code == TIMEOUT_CODE then
    return finish(current_generation, nil, ("ring timed out after %dms"):format(config.timeout))
  end

  if result.code ~= 0 then
    local stderr = vim.trim(result.stderr or "")
    if stderr == "" then
      stderr = ("ring exited with code %s"):format(tostring(result.code))
    end
    return finish(current_generation, nil, stderr)
  end

  local ok, data = pcall(vim.json.decode, result.stdout or "")
  local waiting = ok
    and type(data) == "table"
    and type(data.counts) == "table"
    and tonumber(data.counts.waiting)
  if not waiting then
    return finish(current_generation, nil, "ring returned invalid JSON")
  end

  finish(current_generation, waiting, nil)
end

local function teardown()
  generation = generation + 1
  started = false
  state.running = false
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

function M.refresh()
  if shutdown or state.running then
    return
  end
  state.running = true
  local current_generation = generation
  local opts = { text = true, timeout = config.timeout }
  -- pcall: vim.system() throws synchronously when the executable is missing.
  local ok, err = pcall(vim.system, config.command, opts, function(result)
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
  if started or shutdown then
    return
  end
  started = true
  M.refresh()
  if config.interval > 0 then
    timer = assert(vim.uv.new_timer())
    timer:start(config.interval, config.interval, vim.schedule_wrap(M.refresh))
  end
end

-- Stops polling for good: statusline redraws will no longer restart the timer.
-- Call setup() again to resume.
function M.stop()
  teardown()
  shutdown = true
end

function M.setup(opts)
  opts = opts or {}
  check_type("command", opts.command, "table")
  check_type("interval", opts.interval, "number")
  check_type("timeout", opts.timeout, "number")
  check_type("icon", opts.icon, "string")
  check_type("error_icon", opts.error_icon, "string")
  check_type("hide_when_zero", opts.hide_when_zero, "boolean")

  if opts.command then
    local all_strings = vim.iter(opts.command):all(function(value)
      return type(value) == "string"
    end)
    if #opts.command == 0 or not all_strings then
      error("ring.nvim: command must be a non-empty list of strings", 0)
    end
  end
  if opts.interval and opts.interval < 0 then
    error("ring.nvim: interval must be greater than or equal to zero", 0)
  end
  if opts.timeout and opts.timeout <= 0 then
    error("ring.nvim: timeout must be greater than zero", 0)
  end

  teardown()
  shutdown = false
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  -- A reconfigure starts clean: counts and errors from the previous command
  -- say nothing about the new one.
  state.waiting = 0
  state.last_error = nil
  state.updated_at = nil
  M.start()
end

function M.status()
  M.start()
  if state.last_error and config.error_icon then
    return config.error_icon
  end
  if config.hide_when_zero and state.waiting == 0 then
    return ""
  end
  return config.icon .. tostring(state.waiting)
end

function M.get_state()
  return vim.deepcopy(state)
end

function M.get_config()
  return vim.deepcopy(config)
end

return M
