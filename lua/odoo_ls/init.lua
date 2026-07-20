--- Public API for the odoo-ls Neovim client.
---
--- The plugin works WITHOUT calling `setup()`: enable the server with
--- `vim.lsp.enable('odoo_ls')` once the plugin is on runtimepath (the
--- `lsp/odoo_ls.lua` spec is auto-discovered on Neovim 0.11.2+). These functions
--- are ergonomics you compose yourself; no keymaps are imposed.
local M = {}

local api = require('odoo_ls.api')
local scaffold = require('odoo_ls.scaffold')

-- Re-export the client controls (see lua/odoo_ls/api.lua).
M.restart = api.restart
M.set_profile = api.set_profile
M.select_profile = api.select_profile
M.status = api.status
M.show_config = api.show_config
M.open_logs = api.open_logs
M.init_config = scaffold.init_config

local defaults = {
  -- The server's built-in profile is named "default" (an empty selection maps
  -- to it; the literal "Disabled" makes the server idle).
  profile = 'default',
}

--- Optional convenience. The plugin works without it. Forwards `profile`/`cmd`
--- into `vim.lsp.config('odoo_ls', ...)` and enables the server.
---@param opts? { profile?: string, cmd?: string[] }
function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', defaults, opts or {})

  local cfg = { settings = { Odoo = { selectedProfile = M.config.profile } } }
  if M.config.cmd then
    cfg.cmd = M.config.cmd
  end
  vim.lsp.config('odoo_ls', cfg)

  vim.lsp.enable('odoo_ls')
end

return M
