--- Public entry point: setup, restart, profile switching and server install.
local M = {}

local api = require('odoo_ls.api')
local server = require('odoo_ls.server')

M.restart = api.restart
M.set_profile = api.set_profile

--- Install the server release matching the plugin version, then enable the client.
function M.install()
  server.install(server.VERSION, function(err)
    if not err then
      vim.lsp.enable('odoo_ls')
    end
  end)
end

--- Forward `profile`/`cmd`, install the matching server when it is missing or outdated, enable.
---@param opts? { profile?: string, cmd?: string[] }
function M.setup(opts)
  opts = opts or {}
  local cfg = { cmd = opts.cmd }
  if opts.profile then
    cfg.settings = { Odoo = { selectedProfile = opts.profile } }
  end
  vim.lsp.config('odoo_ls', cfg)

  local r = server.effective()
  if r.source == 'none' or (r.source == 'managed' and r.tag ~= server.VERSION) then
    -- An outdated managed install keeps serving when the download fails.
    server.install(server.VERSION, function(err)
      if not err or r.source == 'managed' then
        vim.lsp.enable('odoo_ls')
      end
    end)
    return
  end
  vim.lsp.enable('odoo_ls')
end

return M
