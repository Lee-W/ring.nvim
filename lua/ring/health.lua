local M = {}

function M.check()
  vim.health.start("ring.nvim")
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim 0.10+")
  else
    vim.health.error("Neovim 0.10+ is required")
  end

  if vim.fn.executable("ring") == 1 then
    vim.health.ok("ring executable found")
  else
    vim.health.error("ring executable not found in PATH")
  end

  local state = require("ring").get_state()
  if state.last_error then
    vim.health.warn(state.last_error)
  end
end

return M
