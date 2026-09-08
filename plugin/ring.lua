if vim.g.loaded_ring_nvim then
  return
end
vim.g.loaded_ring_nvim = true

vim.api.nvim_create_user_command("RingRefresh", function()
  require("ring").refresh()
end, { desc = "Refresh ring.nvim status" })

vim.api.nvim_create_user_command("RingJump", function()
  require("ring").jump()
end, { desc = "Choose a waiting agent session to focus" })

vim.api.nvim_create_user_command("RingNotifyToggle", function()
  local enabled = require("ring").toggle_notify()
  vim.notify("RiNG notifications " .. (enabled and "enabled" or "disabled"), vim.log.levels.INFO, {
    title = "RiNG",
  })
end, { desc = "Toggle ring.nvim waiting notifications" })

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    require("ring").stop()
  end,
})
