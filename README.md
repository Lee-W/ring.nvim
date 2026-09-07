# ring.nvim

[![CI](https://github.com/Lee-W/ring.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/Lee-W/ring.nvim/actions/workflows/ci.yml)

Neovim statusline integration for [RiNG](https://github.com/Lee-W/ring). It polls
`ring --format json` asynchronously, shows `🔴N` while agent sessions are waiting for you, and sends
a Neovim notification when a session newly enters the waiting state.

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
  error_icon = nil, -- shown instead of the count while the last refresh failed
  hide_when_zero = true,
  notify = true, -- use vim.notify() for newly waiting sessions
  notify_level = vim.log.levels.WARN,
  notify_title = "RiNG",
  on_change = nil, -- function(waiting, previous), called on every movement
})
```

`command` replaces the default argv entirely, so keep `--format json` if you point it elsewhere.

## Notifications

A count in the corner is easy to miss while typing, so notifications are enabled by default.
`vim.notify()` lets whichever notifier you use (noice.nvim, snacks.notifier, or the built-in)
surface a session that needs attention. Disable them at startup or toggle them at runtime:

```lua
{ "Lee-W/ring.nvim", opts = { notify = false } }

-- Later, without reconfiguring:
vim.cmd.RingNotifyToggle()
```

The first successful poll silently establishes a baseline, so opening Neovim does not announce
sessions that were already waiting. After that, each session notifies once when it enters the
waiting state. Session IDs prevent repeated alerts and detect a replacement even when the total
count stays unchanged; counts-only custom commands fall back to notifying on a rise. For other count
changes, `on_change(waiting, previous)` fires on every movement in either direction and leaves the
presentation to you:

```lua
opts = {
  on_change = function(waiting, previous)
    if waiting == 0 and previous > 0 then
      vim.notify("all clear")
    end
  end,
}
```

Notifications include the project (and your RiNG label, if set), provider, short session ID, and
what needs attention. For example:

```text
An agent session is waiting for you
• Fix waiting state (ring) · Claude Code [a1b2c3d4]
  Permission required: Bash: git push
```

The requested action uses `waiting_detail`, falling back to `last_action` for older snapshots.
When several sessions newly need attention, one notification lists up to three of them in snapshot
order, followed by the number of additional sessions. Project summaries and details are shortened
to keep the notification readable; the statusline remains a compact count.

Custom commands without a complete, unique session list retain the count-only message. RiNG.nvim
only names newly waiting sessions when it can identify them reliably; it will not guess which
session is new after a nonzero counts-only snapshot.

Polling runs through `vim.system()` and never blocks statusline rendering. Failed refreshes keep the
last successful count. By default a failure is invisible in the statusline — set `error_icon` (e.g.
`"⚠"`) if you would rather see it. Use `:RingRefresh` to refresh immediately, `:checkhealth ring`
to inspect the integration, and `:help ring.nvim` for the full reference.

## Development

```sh
make test          # headless test suite
make format-check  # stylua --check
make format        # stylua, in place
```

## License

MIT
