# ring.nvim

Neovim statusline integration for [RiNG](https://github.com/Lee-W/ring). It polls
`ring --format json` asynchronously and shows `🔴N` while agent sessions are waiting for you.

## Requirements

- Neovim 0.10+
- `ring` available in `$PATH`
- lualine.nvim or heirline.nvim

## Installation

With lazy.nvim and lualine:

```lua
{
  "Lee-W/ring.nvim",
  dependencies = { "nvim-lualine/lualine.nvim" },
  config = function()
    require("ring").setup()
    require("lualine").setup({
      sections = {
        lualine_x = { "ring" },
      },
    })
  end,
}
```

With heirline:

```lua
require("ring").setup()

require("heirline").setup({
  statusline = {
    -- your other components...
    require("ring.integrations.heirline"),
  },
})
```

## Configuration

These are the defaults:

```lua
require("ring").setup({
  command = { "ring", "--format", "json" },
  interval = 2000, -- milliseconds; 0 disables periodic polling
  timeout = 5000,
  icon = "🔴",
  hide_when_zero = true,
})
```

Polling runs through `vim.system()` and never blocks statusline rendering. Failed refreshes keep the
last successful count. Use `:RingRefresh` to refresh immediately and `:checkhealth ring` to inspect
the integration.

## License

MIT
