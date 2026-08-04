local M = {}

function M.check()
  vim.health.start("ring.nvim")
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim 0.10+")
  else
    vim.health.error("Neovim 0.10+ is required")
  end

  local ring = require("ring")
  local executable = ring.get_config().command[1]
  if vim.fn.executable(executable) == 1 then
    vim.health.ok(("%s executable found"):format(executable))
  else
    vim.health.error(("%s executable not found in PATH"):format(executable))
  end

  local state = ring.get_state()
  if state.last_error then
    vim.health.warn(state.last_error)
  end
end

return M
