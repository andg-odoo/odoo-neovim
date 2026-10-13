-- Auto-discovered by vim.lsp.enable('odoo_ls'), override any field with vim.lsp.config('odoo_ls')

---@type vim.lsp.Config
return {
  cmd = require('odoo_ls.server').start,
  filetypes = { 'python', 'xml', 'csv', 'javascript', 'typescript' },
  -- Attach only under an odools.toml so every buffer sits inside the workspace folder
  root_dir = function(bufnr, on_dir)
    local root = vim.fs.root(bufnr, 'odools.toml')
    if root then
      on_dir(root)
    end
  end,
  -- utf-16 only because lemminx shares the xml buffers and all clients on a buffer must agree
  capabilities = { general = { positionEncodings = { 'utf-16' } } },
  settings = { Odoo = { selectedProfile = 'default' } },
  handlers = require('odoo_ls.protocol').handlers,
  on_exit = function()
    -- on_exit runs in a fast event context, so defer the state reset
    vim.schedule(require('odoo_ls.protocol')._on_exit)
  end,
}
