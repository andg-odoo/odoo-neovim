-- :OdooLs umbrella command. Loaded once when the plugin is on runtimepath.
if vim.g.loaded_odoo_ls then
  return
end
vim.g.loaded_odoo_ls = true

-- 0.11.2+: vim.lsp.enable() gained "stop clients on disable" and "attach
-- already-open buffers on enable", which this plugin relies on.
if vim.fn.has('nvim-0.11.2') == 0 then
  vim.notify('odoo-ls requires Neovim 0.11.2+', vim.log.levels.ERROR, { title = 'odoo_ls' })
  return
end

local subcommands = {
  install = function(channel)
    require('odoo_ls').installOdooLs(channel)
  end,
  restart = function()
    require('odoo_ls').restart()
  end,
  profile = function()
    require('odoo_ls').select_profile()
  end,
  config = function()
    require('odoo_ls').show_config()
  end,
  logs = function()
    require('odoo_ls').open_logs()
  end,
  init = function()
    require('odoo_ls').init_config()
  end,
  health = function()
    vim.cmd.checkhealth('odoo_ls')
  end,
}

-- Optional second-argument completion, keyed by subcommand.
local subcompletions = {
  install = { 'stable', 'latest' },
}

vim.api.nvim_create_user_command('OdooLs', function(cmd)
  local sub = cmd.fargs[1] or 'config'
  local fn = subcommands[sub]
  if fn then
    fn(unpack(cmd.fargs, 2))
  else
    vim.notify('odoo_ls: unknown subcommand ' .. sub, vim.log.levels.ERROR, { title = 'odoo_ls' })
  end
end, {
  nargs = '*',
  desc = 'odoo-ls language server controls',
  complete = function(arglead, cmdline)
    local parts = vim.split(vim.trim(cmdline), '%s+')
    -- Completing the subcommand itself (nothing typed yet after it).
    if #parts <= 1 or (#parts == 2 and arglead ~= '') then
      return vim.tbl_filter(function(name)
        return name:find(arglead, 1, true) == 1
      end, vim.tbl_keys(subcommands))
    end
    -- Completing an argument for a subcommand.
    local opts = subcompletions[parts[2]]
    if opts then
      return vim.tbl_filter(function(o)
        return o:find(arglead, 1, true) == 1
      end, opts)
    end
    return {}
  end,
})
