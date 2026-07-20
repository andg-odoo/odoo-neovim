-- Auto-discovered by Neovim 0.11.2+ (`lsp/` on runtimepath). The plugin works
-- with NO `setup()` call: just `vim.lsp.enable('odoo_ls')`.
--
-- Override any field the standard way, e.g. pin the binary:
--     vim.lsp.config('odoo_ls', { cmd = { '/path/to/odoo_ls_server' } })
-- A `cmd` set that way replaces the resolved one below (Neovim swaps `cmd`
-- wholesale rather than element-merging it).

---@type vim.lsp.Config
return {
  cmd = require('odoo_ls.resolve').resolve_cmd(),
  filetypes = { 'python', 'xml', 'csv', 'javascript' },
  root_markers = { 'odools.toml', '.git' },
  -- Advertise utf-16 ONLY. The server otherwise picks utf-8 when offered, but
  -- lemminx (the usual XML companion) is utf-16-only, and all clients on one
  -- buffer must agree on position encoding. Deep-merged over the default
  -- capabilities at client creation, so only this leaf is overridden.
  capabilities = { general = { positionEncodings = { 'utf-16' } } },
  settings = { Odoo = { selectedProfile = 'default' } },
  handlers = require('odoo_ls.protocol').handlers,
  on_exit = function()
    -- runs in a fast event context; defer state mutation
    vim.schedule(require('odoo_ls.protocol')._on_exit)
  end,
}
