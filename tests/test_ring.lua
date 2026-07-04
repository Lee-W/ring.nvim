local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.runtimepath:prepend(root)

local responses = {}
vim.system = function(command, options, callback)
  assert(vim.deep_equal(command, { "ring", "--format", "json" }))
  assert(options.text)
  callback(table.remove(responses, 1))
  return {}
end

local ring = require("ring")

responses[1] = { code = 0, stdout = '{"counts":{"waiting":2}}', stderr = "" }
ring.setup({ interval = 0 })
assert(vim.wait(100, function()
  return ring.get_state().waiting == 2
end))
assert(ring.status() == "🔴2")

responses[1] = { code = 0, stdout = '{"counts":{"waiting":0}}', stderr = "" }
ring.refresh()
assert(vim.wait(100, function()
  return ring.get_state().waiting == 0
end))
assert(ring.status() == "")

responses[1] = { code = 0, stdout = '{"counts":{"waiting":0}}', stderr = "" }
ring.setup({ interval = 0, hide_when_zero = false, icon = "!" })
assert(vim.wait(100, function()
  return not ring.get_state().running
end))
assert(ring.status() == "!0")

responses[1] = { code = 1, stdout = "", stderr = "ring failed" }
ring.refresh()
assert(vim.wait(100, function()
  return ring.get_state().last_error ~= nil
end))
assert(ring.get_state().last_error == "ring failed")

package.preload["lualine.component"] = function()
  local Component = {}
  function Component:extend()
    return setmetatable({}, { __index = self })
  end
  return Component
end
assert(require("lualine.components.ring"):update_status() == "!0")
assert(require("ring.integrations.heirline").provider() == "!0")

-- vim.system 同步 throw（ENOENT：執行檔不在 PATH）不該炸掉 setup / statusline
vim.system = function()
  error("ENOENT: no such file or directory (cmd): 'ring-not-on-path'")
end
local ok_setup = pcall(ring.setup, { command = { "ring-not-on-path" }, interval = 0 })
assert(ok_setup, "setup must not propagate ENOENT")
assert(ring.get_state().running == false, "running must unlatch after spawn failure")
assert(ring.get_state().last_error:find("ENOENT") ~= nil)
assert(ring.status() == "")

ring.stop()
print("ring.nvim tests passed")
