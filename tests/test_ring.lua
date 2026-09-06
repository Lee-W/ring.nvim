local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.runtimepath:prepend(root)

local ring = require("ring")

local real_system = vim.system
local real_health = vim.health
local real_notify = vim.notify

local cases = {}
local calls
local notifications

local function case(name, fn)
  cases[#cases + 1] = { name = name, fn = fn }
end

local function snapshot(waiting, sessions)
  return {
    code = 0,
    stdout = vim.json.encode({ counts = { waiting = waiting }, sessions = sessions }),
    stderr = "",
  }
end

local function counts(waiting)
  return snapshot(waiting)
end

-- Replaces vim.system with a stub that hands back queued results synchronously
-- and records every spawn, so tests never touch a real `ring` binary.
local function stub_system(responses)
  responses = responses or {}
  calls = {}
  vim.system = function(command, options, callback)
    calls[#calls + 1] = { command = vim.deepcopy(command), options = options }
    callback(table.remove(responses, 1) or counts(0))
    return {}
  end
end

local function wait_for(predicate, message)
  assert(vim.wait(1000, predicate, 5), message)
end

local function wait_idle()
  wait_for(function()
    return not ring.get_state().running
  end, "refresh never settled")
end

-- Waits for an exact message so a stale error can never satisfy the predicate.
local function wait_error(expected)
  local ok = vim.wait(1000, function()
    return ring.get_state().last_error == expected
  end, 5)
  assert(
    ok,
    ("last_error never became %q (was %s)"):format(expected, tostring(ring.get_state().last_error))
  )
end

local function assert_error(fn, expected)
  local ok, err = pcall(fn)
  assert(not ok, ("expected an error mentioning %q"):format(expected))
  assert(
    tostring(err):find(expected, 1, true),
    ("error %q did not mention %q"):format(tostring(err), expected)
  )
end

case("reports the waiting count", function()
  stub_system({ counts(2) })
  ring.setup({ interval = 0 })
  wait_for(function()
    return ring.get_state().waiting == 2
  end, "waiting count never reached 2")
  assert(ring.status() == "🔴2", ring.status())
  assert(#notifications == 0, "the initial snapshot must not notify")
end)

case("hides a zero count by default", function()
  stub_system({ counts(0) })
  ring.setup({ interval = 0 })
  wait_idle()
  assert(ring.status() == "", ring.status())
end)

case("honours hide_when_zero=false and a custom icon", function()
  stub_system({ counts(0) })
  ring.setup({ interval = 0, hide_when_zero = false, icon = "!" })
  wait_idle()
  assert(ring.status() == "!0", ring.status())
end)

case("spawns the default command with text output", function()
  stub_system({ counts(0) })
  ring.setup({ interval = 0 })
  wait_idle()
  assert(
    vim.deep_equal(calls[1].command, { "ring", "--format", "json" }),
    vim.inspect(calls[1].command)
  )
  assert(calls[1].options.text, "vim.system must be called with text = true")
  assert(calls[1].options.timeout == 5000, tostring(calls[1].options.timeout))
end)

case("a custom command replaces the default argv entirely", function()
  stub_system({ counts(0) })
  ring.setup({ interval = 0, command = { "mycmd" } })
  wait_idle()
  -- Guards the tbl_deep_extend list-merge trap: no leftover "--format", "json".
  assert(vim.deep_equal(calls[1].command, { "mycmd" }), vim.inspect(calls[1].command))
end)

case("surfaces stderr from a non-zero exit", function()
  stub_system({ { code = 1, stdout = "", stderr = "ring failed" } })
  ring.setup({ interval = 0 })
  wait_error("ring failed")
end)

case("falls back to the exit code when stderr is empty", function()
  stub_system({ { code = 2, stdout = "", stderr = "" } })
  ring.setup({ interval = 0 })
  wait_error("ring exited with code 2")
end)

case("reports a timeout distinctly from a plain failure", function()
  stub_system({ { code = 124, stdout = "", stderr = "" } })
  ring.setup({ interval = 0, timeout = 250 })
  wait_error("ring timed out after 250ms")
end)

case("rejects output that is not valid ring JSON", function()
  stub_system({ { code = 0, stdout = "not json", stderr = "" } })
  ring.setup({ interval = 0 })
  wait_error("ring returned invalid JSON")
end)

case("keeps the last successful count when a refresh fails", function()
  stub_system({ counts(3), { code = 1, stdout = "", stderr = "boom" } })
  ring.setup({ interval = 0, hide_when_zero = false })
  wait_for(function()
    return ring.get_state().waiting == 3
  end, "waiting count never reached 3")
  ring.refresh()
  wait_error("boom")
  assert(ring.get_state().waiting == 3, tostring(ring.get_state().waiting))
  assert(ring.status() == "🔴3", ring.status())
end)

case("error_icon surfaces failures in the statusline", function()
  stub_system({ { code = 1, stdout = "", stderr = "boom" } })
  ring.setup({ interval = 0, error_icon = "⚠" })
  wait_error("boom")
  assert(ring.status() == "⚠", ring.status())
end)

case("clears the error state once a refresh succeeds again", function()
  stub_system({ { code = 1, stdout = "", stderr = "boom" }, counts(1) })
  ring.setup({ interval = 0, error_icon = "⚠" })
  wait_error("boom")
  ring.refresh()
  wait_for(function()
    return ring.get_state().last_error == nil
  end, "error state never cleared")
  assert(ring.status() == "🔴1", ring.status())
end)

case("notifies only when a session newly enters waiting", function()
  local session_a = { session_id = "a", status = "waiting" }
  local session_b = { session_id = "b", status = "waiting" }
  stub_system({
    snapshot(1, { session_a }),
    snapshot(1, { session_a }),
    snapshot(1, { session_b }),
    snapshot(0, {}),
    snapshot(1, { session_b }),
  })
  ring.setup({ interval = 0 })
  wait_idle()
  assert(#notifications == 0, "the initial snapshot must only prime the baseline")

  ring.refresh()
  wait_idle()
  assert(#notifications == 0, "an unchanged waiting session notified")

  ring.refresh()
  wait_idle()
  assert(#notifications == 1, "a replacement session was not detected")
  assert(notifications[1].message == "An agent session is waiting for you")
  assert(notifications[1].level == vim.log.levels.WARN)
  assert(notifications[1].opts.title == "RiNG")

  ring.refresh()
  wait_idle()
  ring.refresh()
  wait_idle()
  assert(#notifications == 2, "a session re-entering waiting was not detected")
end)

case("notifications can be configured and toggled at runtime", function()
  local session_a = { session_id = "a", status = "waiting" }
  local session_b = { session_id = "b", status = "waiting" }
  local session_c = { session_id = "c", status = "waiting" }
  stub_system({
    snapshot(1, { session_a }),
    snapshot(2, { session_a, session_b }),
    snapshot(2, { session_a, session_b }),
    snapshot(3, { session_a, session_b, session_c }),
  })
  ring.setup({ interval = 0, notify = false })
  wait_idle()
  assert(ring.get_state().notify_enabled == false)

  ring.refresh()
  wait_idle()
  assert(#notifications == 0, "disabled notifications must stay silent")

  assert(ring.toggle_notify() == true)
  assert(ring.get_state().notify_enabled == true)
  ring.refresh()
  wait_idle()
  assert(#notifications == 0, "enabling notifications replayed existing waits")

  ring.refresh()
  wait_idle()
  assert(#notifications == 1, "new waits should notify after enabling")
  assert(notifications[1].message == "An agent session is waiting for you")
  assert(ring.set_notify(false) == false)
  assert(ring.get_state().notify_enabled == false)
end)

case("polls repeatedly on a positive interval", function()
  stub_system({})
  ring.setup({ interval = 10 })
  wait_for(function()
    return #calls >= 3
  end, ("timer only spawned %d times"):format(#calls))
end)

case("interval = 0 disables periodic polling", function()
  stub_system({})
  ring.setup({ interval = 0 })
  wait_idle()
  assert(#calls == 1, ("expected a single spawn, got %d"):format(#calls))
  vim.wait(60)
  assert(#calls == 1, ("timer kept polling: %d spawns"):format(#calls))
end)

case("stop() keeps statusline redraws from restarting the timer", function()
  stub_system({})
  ring.setup({ interval = 10 })
  wait_idle()
  ring.stop()
  local spawns = #calls
  assert(ring.status() == "", ring.status())
  vim.wait(60)
  assert(#calls == spawns, ("stop() did not stick: %d -> %d spawns"):format(spawns, #calls))
  assert(ring.get_state().running == false, "running must be false after stop()")
end)

case("setup() after stop() resumes polling", function()
  stub_system({})
  ring.setup({ interval = 0 })
  ring.stop()
  ring.setup({ interval = 0 })
  wait_idle()
  assert(#calls == 2, ("expected 2 spawns, got %d"):format(#calls))
end)

case("setup() validates option types", function()
  stub_system({})
  assert_error(function()
    ring.setup({ command = "ring" })
  end, "command must be a table")
  assert_error(function()
    ring.setup({ interval = "fast" })
  end, "interval must be a number")
  assert_error(function()
    ring.setup({ icon = 42 })
  end, "icon must be a string")
  assert_error(function()
    ring.setup({ error_icon = true })
  end, "error_icon must be a string")
  assert_error(function()
    ring.setup({ hide_when_zero = "yes" })
  end, "hide_when_zero must be a boolean")
  assert_error(function()
    ring.setup({ notify = "yes" })
  end, "notify must be a boolean")
  assert_error(function()
    ring.setup({ notify_level = "loud" })
  end, "notify_level must be a number")
  assert_error(function()
    ring.setup({ notify_title = 1 })
  end, "notify_title must be a string")
  assert_error(function()
    ring.setup({ on_change = "nope" })
  end, "on_change must be a function")
  assert_error(function()
    ring.set_notify("yes")
  end, "enabled must be a boolean")
end)

case("setup() rejects malformed commands and ranges", function()
  stub_system({})
  assert_error(function()
    ring.setup({ command = {} })
  end, "non-empty list of strings")
  assert_error(function()
    ring.setup({ command = { "ring", 7 } })
  end, "non-empty list of strings")
  assert_error(function()
    ring.setup({ interval = -1 })
  end, "interval must be greater than or equal to zero")
  assert_error(function()
    ring.setup({ timeout = 0 })
  end, "timeout must be greater than zero")
end)

case("on_change reports every movement with the previous count", function()
  local seen = {}
  stub_system({ counts(2), counts(2), counts(0) })
  ring.setup({
    interval = 0,
    on_change = function(waiting, previous)
      seen[#seen + 1] = { waiting = waiting, previous = previous }
    end,
  })
  wait_idle()
  ring.refresh() -- unchanged count: must not fire again
  wait_idle()
  ring.refresh()
  wait_for(function()
    return #seen == 2
  end, "on_change never saw the drop back to zero")
  assert(seen[1].waiting == 2 and seen[1].previous == 0, vim.inspect(seen[1]))
  assert(seen[2].waiting == 0 and seen[2].previous == 2, vim.inspect(seen[2]))
end)

case("a failing on_change never breaks the poll loop", function()
  stub_system({ counts(3) })
  ring.setup({
    interval = 0,
    on_change = function()
      error("boom")
    end,
  })
  wait_for(function()
    return ring.get_state().waiting == 3
  end, "waiting count never reached 3")
  assert(ring.get_state().last_error == nil, tostring(ring.get_state().last_error))
end)

case("notifications honour a custom level and title", function()
  stub_system({ counts(0), counts(1) })
  ring.setup({
    interval = 0,
    notify_level = vim.log.levels.INFO,
    notify_title = "Agent desk",
  })
  wait_idle()
  ring.refresh()
  wait_idle()
  assert(#notifications == 1, vim.inspect(notifications))
  assert(notifications[1].level == vim.log.levels.INFO)
  assert(notifications[1].opts.title == "Agent desk")
end)

case("notifications can start disabled", function()
  stub_system({ counts(4) })
  ring.setup({ interval = 0, notify = false })
  wait_idle()
  assert(#notifications == 0, ("expected silence, got %d notifications"):format(#notifications))
end)

case("statusline integrations delegate to status()", function()
  stub_system({ counts(0) })
  ring.setup({ interval = 0, hide_when_zero = false, icon = "!" })
  wait_idle()
  package.preload["lualine.component"] = function()
    local Component = {}
    function Component:extend()
      return setmetatable({}, { __index = self })
    end
    return Component
  end
  assert(require("lualine.components.ring"):update_status() == "!0")
  assert(require("ring.integrations.heirline").provider() == "!0")
end)

case("a synchronous spawn failure never escapes setup()", function()
  vim.system = function()
    error("ENOENT: no such file or directory (cmd): 'ring-not-on-path'")
  end
  local ok = pcall(ring.setup, { command = { "ring-not-on-path" }, interval = 0 })
  assert(ok, "setup must not propagate ENOENT")
  assert(ring.get_state().running == false, "running must unlatch after a spawn failure")
  assert(ring.get_state().last_error:find("ENOENT", 1, true) ~= nil, ring.get_state().last_error)
  assert(ring.status() == "", ring.status())
end)

case("checkhealth inspects the configured executable, not a hardcoded one", function()
  stub_system({})
  ring.setup({ interval = 0, command = { "ring-definitely-not-installed", "--format", "json" } })
  wait_idle()

  local reported = {}
  vim.health = {
    start = function(name)
      reported[#reported + 1] = { level = "start", message = name }
    end,
    ok = function(message)
      reported[#reported + 1] = { level = "ok", message = message }
    end,
    warn = function(message)
      reported[#reported + 1] = { level = "warn", message = message }
    end,
    error = function(message)
      reported[#reported + 1] = { level = "error", message = message }
    end,
  }
  require("ring.health").check()

  local found = false
  for _, entry in ipairs(reported) do
    if entry.level == "error" and entry.message:find("ring-definitely-not-installed", 1, true) then
      found = true
    end
  end
  assert(found, "checkhealth did not report the configured executable: " .. vim.inspect(reported))
end)

case(":RingNotifyToggle changes state and confirms the result", function()
  stub_system({ counts(0) })
  ring.setup({ interval = 0 })
  wait_idle()
  dofile(root .. "/plugin/ring.lua")

  vim.cmd("RingNotifyToggle")
  assert(ring.get_state().notify_enabled == false)
  assert(notifications[#notifications].message == "RiNG notifications disabled")

  vim.cmd("RingNotifyToggle")
  assert(ring.get_state().notify_enabled == true)
  assert(notifications[#notifications].message == "RiNG notifications enabled")
end)

local failures = {}
for _, item in ipairs(cases) do
  notifications = {}
  vim.notify = function(message, level, opts)
    notifications[#notifications + 1] = { message = message, level = level, opts = opts }
  end
  local ok, err = pcall(item.fn)
  pcall(ring.stop)
  vim.system = real_system
  vim.health = real_health
  vim.notify = real_notify
  if ok then
    print("ok   - " .. item.name)
  else
    print("FAIL - " .. item.name)
    failures[#failures + 1] = ("%s\n      %s"):format(item.name, tostring(err))
  end
end

if #failures > 0 then
  print(("\n%d of %d ring.nvim tests failed:"):format(#failures, #cases))
  for _, failure in ipairs(failures) do
    print("  - " .. failure)
  end
  os.exit(1)
end

print(("\nring.nvim: %d tests passed"):format(#cases))
