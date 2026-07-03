if vim.g.loaded_ring_nvim then
  return
end
vim.g.loaded_ring_nvim = true

vim.api.nvim_create_user_command("RingRefresh", function()
  require("ring").refresh()
end, { desc = "Refresh ring.nvim status" })

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    require("ring").stop()
  end,
})
