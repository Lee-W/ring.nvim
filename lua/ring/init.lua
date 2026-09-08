local M = {}

local defaults = {
  command = { "ring", "--format", "json" },
  focus_command = { "ring", "focus" },
  interval = 2000,
  timeout = 5000,
  focus_timeout = 15000,
  icon = "🔴",
  error_icon = nil,
  hide_when_zero = true,
  notify = true,
  notify_level = vim.log.levels.WARN,
  notify_title = "RiNG",
  on_change = nil,
}

-- `vim.system()` reports a timeout as exit code 124, mirroring timeout(1).
local TIMEOUT_CODE = 124

local config = vim.deepcopy(defaults)
local timer
local started = false
local shutdown = false
local generation = 0
local waiting_sessions
local jump_pending = false
local jump_active = false
local state = {
  waiting = 0,
  running = false,
  last_error = nil,
  updated_at = nil,
  notify_enabled = defaults.notify,
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

local function run_on_change(waiting, previous)
  if config.on_change then
    -- pcall: a broken callback must not take the poll loop down with it.
    local ok, err = pcall(config.on_change, waiting, previous)
    if not ok then
      pcall(vim.notify, "ring.nvim: on_change failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

local function get_waiting_sessions(data, waiting)
  if type(data.sessions) ~= "table" then
    return nil
  end

  local ids = {}
  local sessions = {}
  for _, session in ipairs(data.sessions) do
    if type(session) == "table" and session.status == "waiting" then
      if
        type(session.session_id) ~= "string"
        or session.session_id == ""
        or ids[session.session_id]
      then
        return nil
      end
      ids[session.session_id] = true
      sessions[#sessions + 1] = session
    end
  end

  -- A partial or non-standard session list is not reliable enough for diffing.
  if #sessions ~= waiting then
    return nil
  end
  return sessions
end

local function request_ids(session)
  local requests = session.waiting_requests
  if type(requests) ~= "table" or not vim.islist(requests) or #requests == 0 then
    return nil
  end
  local ids = {}
  for _, request in ipairs(requests) do
    if
      type(request) ~= "table"
      or type(request.id) ~= "string"
      or request.id == ""
      or ids[request.id]
    then
      return nil
    end
    ids[request.id] = true
  end
  return ids
end

local function count_new_waiting(waiting, sessions)
  local current
  if sessions then
    current = {}
    for _, session in ipairs(sessions) do
      current[session.session_id] = request_ids(session) or true
    end
  end
  -- The first successful poll describes the state Neovim opened into. Prime
  -- the baseline silently so existing waits are not mistaken for transitions.
  if state.updated_at == nil then
    waiting_sessions = current
    return 0
  end

  local new_waiting = math.max(waiting - state.waiting, 0)
  local new_sessions
  if current and waiting_sessions then
    new_sessions = {}
    for _, session in ipairs(sessions) do
      local previous = waiting_sessions[session.session_id]
      local requests = current[session.session_id]
      if not previous then
        new_sessions[#new_sessions + 1] = session
      elseif type(previous) == "table" and type(requests) == "table" then
        -- Compare additions, not a hash of the whole set: removing a resolved
        -- subagent wait must not re-announce the remaining waits.
        for _, request in ipairs(session.waiting_requests) do
          if not previous[request.id] then
            local new_session = vim.deepcopy(session)
            new_session.waiting_kind = request.kind
            new_session.waiting_detail = request.detail
            new_session.last_action = nil
            new_session.waiting_owner = request.owner
            new_sessions[#new_sessions + 1] = new_session
            break -- Counts and notification headlines still count sessions.
          end
        end
      end
    end
    new_waiting = #new_sessions
  elseif sessions and state.waiting == 0 then
    -- A zero baseline proves every current wait is new, even without old IDs.
    new_sessions = sessions
  end
  waiting_sessions = current
  return new_waiting, new_sessions
end

local function notify_waiting(count, sessions)
  if not state.notify_enabled or count == 0 then
    return
  end

  local message = require("ring.notification").format(count, sessions)
  -- A notification provider should never be able to break polling.
  pcall(vim.notify, message, config.notify_level, { title = config.notify_title })
end

local function report_jump(message, level)
  pcall(vim.notify, "ring.nvim: " .. message, level or vim.log.levels.ERROR, {
    title = config.notify_title,
  })
end

local function focus_session(session, current_generation)
  local command = vim.deepcopy(config.focus_command)
  -- Pass the full ID as one argv element, never a shell command or display prefix.
  command[#command + 1] = session.session_id
  local timeout = config.focus_timeout
  local ok, err = pcall(vim.system, command, { text = true, timeout = timeout }, function(result)
    vim.schedule(function()
      if current_generation ~= generation then
        return
      end
      jump_active = false
      if result.code == TIMEOUT_CODE then
        report_jump(("focus timed out after %dms"):format(timeout))
      elseif result.code ~= 0 then
        local message = vim.trim(result.stderr or "")
        if message == "" then
          message = ("focus exited with code %s"):format(tostring(result.code))
        end
        report_jump(message)
      end
    end)
  end)
  if not ok and current_generation == generation then
    jump_active = false
    report_jump(tostring(err))
  end
end

local function select_waiting(waiting, err, sessions, current_generation)
  if err or waiting == 0 or not sessions then
    jump_active = false
    if err then
      report_jump(err)
    elseif waiting == 0 then
      report_jump("No agent sessions are waiting", vim.log.levels.INFO)
    else
      report_jump(":RingJump needs complete session details with unique IDs", vim.log.levels.WARN)
    end
    return
  end

  local answered = false
  local ok, select_err = pcall(vim.ui.select, vim.deepcopy(sessions), {
    prompt = "Jump to waiting agent:",
    kind = "ring",
    format_item = require("ring.notification").format_session,
  }, function(session)
    if answered or current_generation ~= generation then
      return
    end
    answered = true
    if not session then
      jump_active = false
      return
    end
    focus_session(session, current_generation)
  end)
  if not ok and current_generation == generation then
    if not answered then
      answered = true
      jump_active = false
    end
    report_jump(tostring(select_err))
  end
end

local function finish(current_generation, waiting, err, sessions)
  if current_generation ~= generation then
    return
  end
  state.running = false
  local requested_jump = jump_pending
  jump_pending = false

  local previous = state.waiting
  local changed = state.last_error ~= err or (waiting ~= nil and state.waiting ~= waiting)
  state.last_error = err
  if waiting ~= nil then
    local new_waiting, new_sessions = count_new_waiting(waiting, sessions)
    state.waiting = waiting
    state.updated_at = os.time()
    notify_waiting(new_waiting, new_sessions)
  end
  if changed then
    redraw()
  end
  if waiting ~= nil and waiting ~= previous then
    run_on_change(waiting, previous)
  end
  if requested_jump and current_generation == generation then
    select_waiting(waiting, err, sessions, current_generation)
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

  finish(current_generation, waiting, nil, get_waiting_sessions(data, waiting))
end

local function teardown()
  generation = generation + 1
  started = false
  state.running = false
  jump_pending = false
  jump_active = false
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
    finish(current_generation, nil, vim.trim(tostring(err)))
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
  check_type("focus_command", opts.focus_command, "table")
  check_type("interval", opts.interval, "number")
  check_type("timeout", opts.timeout, "number")
  check_type("focus_timeout", opts.focus_timeout, "number")
  check_type("icon", opts.icon, "string")
  check_type("error_icon", opts.error_icon, "string")
  check_type("hide_when_zero", opts.hide_when_zero, "boolean")
  check_type("notify", opts.notify, "boolean")
  check_type("notify_level", opts.notify_level, "number")
  check_type("notify_title", opts.notify_title, "string")
  check_type("on_change", opts.on_change, "function")

  for _, name in ipairs({ "command", "focus_command" }) do
    if opts[name] then
      local all_strings = vim.iter(opts[name]):all(function(value)
        return type(value) == "string"
      end)
      if #opts[name] == 0 or not all_strings then
        error("ring.nvim: " .. name .. " must be a non-empty list of strings", 0)
      end
    end
  end
  if opts.interval and opts.interval < 0 then
    error("ring.nvim: interval must be greater than or equal to zero", 0)
  end
  if opts.timeout and opts.timeout <= 0 then
    error("ring.nvim: timeout must be greater than zero", 0)
  end
  if opts.focus_timeout and opts.focus_timeout <= 0 then
    error("ring.nvim: focus_timeout must be greater than zero", 0)
  end

  teardown()
  shutdown = false
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  -- A reconfigure starts clean: counts and errors from the previous command
  -- say nothing about the new one.
  state.waiting = 0
  state.last_error = nil
  state.updated_at = nil
  state.notify_enabled = config.notify
  waiting_sessions = nil
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

function M.jump()
  if shutdown then
    report_jump("polling is stopped; call setup() before jumping", vim.log.levels.WARN)
    return
  end
  if jump_active then
    return
  end
  jump_active = true
  jump_pending = true
  if started then
    -- An in-flight refresh will serve the pending picker; otherwise start a fresh poll.
    M.refresh()
  else
    M.start()
  end
end

function M.get_state()
  return vim.deepcopy(state)
end

function M.get_config()
  return vim.deepcopy(config)
end

function M.set_notify(enabled)
  if type(enabled) ~= "boolean" then
    error(("ring.nvim: enabled must be a boolean, got %s"):format(type(enabled)), 0)
  end
  state.notify_enabled = enabled
  return enabled
end

function M.toggle_notify()
  return M.set_notify(not state.notify_enabled)
end

return M
