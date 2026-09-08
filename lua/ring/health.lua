local M = {}

function M.check()
  vim.health.start("ring.nvim")
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim 0.10+")
  else
    vim.health.error("Neovim 0.10+ is required")
  end

  local ring = require("ring")
  local config = ring.get_config()
  for _, name in ipairs({ "command", "focus_command" }) do
    local executable = config[name][1]
    if vim.fn.executable(executable) == 1 then
      vim.health.ok(("%s: %s executable found"):format(name, executable))
    else
      vim.health.error(("%s: %s executable not found in PATH"):format(name, executable))
    end
  end

  local state = ring.get_state()
  if state.last_error then
    vim.health.warn(state.last_error)
  end
end

return M
