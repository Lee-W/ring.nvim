local Component = require("lualine.component"):extend()

function Component:update_status()
  return require("ring").status()
end

return Component
