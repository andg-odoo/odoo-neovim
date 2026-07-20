--- Public API for the odoo-ls Neovim client.
---
--- The plugin works WITHOUT calling `setup()`: enable the server with
--- `vim.lsp.enable('odoo_ls')` once the plugin is on runtimepath (the
--- `lsp/odoo_ls.lua` spec is auto-discovered on Neovim 0.11.2+). These functions
--- are ergonomics you compose yourself; no keymaps are imposed.
---
--- `setup()` is optional sugar that additionally manages the server binary:
--- downloading a GitHub release if none is found and checking for updates on
--- startup. Without it, no download and no version check happen - the plugin
--- runs as a pure client against whatever binary it can resolve.
local M = {}

local api = require('odoo_ls.api')
local scaffold = require('odoo_ls.scaffold')
local resolve = require('odoo_ls.resolve')

-- Re-export the client controls (see lua/odoo_ls/api.lua).
M.restart = api.restart
M.set_profile = api.set_profile
M.select_profile = api.select_profile
M.status = api.status
M.show_config = api.show_config
M.open_logs = api.open_logs
M.init_config = scaffold.init_config

local odoo_share = vim.fn.stdpath('data') .. '/odoo'
local last_check_file = odoo_share .. '/.last_version_check'
local uv = vim.uv or vim.loop

local defaults = {
  -- The server's built-in profile is named "default" (an empty selection maps
  -- to it; the literal "Disabled" makes the server idle).
  profile = 'default',
  checkVersion = true,
  checkFrequency = 24,
  version = 'stable',
}

local function should_check_version()
  local stat = uv.fs_stat(last_check_file)
  if not stat then
    return true
  end
  local lines = vim.fn.readfile(last_check_file)
  local last_check = tonumber(lines[1]) or 0
  return (os.time() - last_check) >= M.config.checkFrequency * 3600
end

local function record_version_check()
  vim.fn.mkdir(odoo_share, 'p')
  vim.fn.writefile({ tostring(os.time()) }, last_check_file)
end

local function check_version(release, executable)
  if (release ~= 'latest' and release ~= 'stable') or not should_check_version() then
    return
  end
  local github = require('odoo_ls.github')
  vim.system({ executable, '--version' }, { text = true }, function(out)
    if out.code ~= 0 or not out.stdout then
      return
    end
    local version = vim.trim(out.stdout):match('%S+$')
    local fetch = release == 'stable' and github.get_stable_release or github.get_latest_release
    fetch(function(tag, err)
      if err then
        return
      end
      record_version_check()
      if version ~= tag then
        vim.notify(
          '[odoo-ls] Update available: ' .. tag .. ' (current: ' .. version .. ')',
          vim.log.levels.INFO
        )
      end
    end)
  end)
end

--- Download and install the server + typeshed, then enable the client.
--- Honors the configured `version` channel unless `release` is given
--- (`'stable'`, `'latest'`, or a specific tag). Usable without `setup()`.
---@param release? string
function M.installOdooLs(release)
  release = release or (M.config and M.config.version) or 'stable'
  vim.notify('[odoo-ls] Installing...', vim.log.levels.INFO)
  require('odoo_ls.installer').download(release, function()
    vim.notify('[odoo-ls] Installation complete', vim.log.levels.INFO)
    -- enable() resets the cached config, so the lsp/ spec re-runs its binary
    -- resolution and picks up the fresh install (a user-pinned cmd still wins:
    -- vim.lsp.config overrides merge over the spec). It also re-fires FileType
    -- on already-open buffers, attaching them.
    vim.lsp.enable('odoo_ls')
  end)
end

--- Optional convenience. The plugin works without it. Forwards `profile`/`cmd`
--- into `vim.lsp.config('odoo_ls', ...)`, installs the server if none is found,
--- enables it, and (optionally) checks for updates.
---@param opts? { profile?: string, cmd?: string[], checkVersion?: boolean, checkFrequency?: integer, version?: string }
function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', defaults, opts or {})

  vim.api.nvim_create_user_command('OdooLsInstall', function(cmd_opts)
    M.installOdooLs(cmd_opts.args ~= '' and cmd_opts.args or nil)
  end, {
    nargs = '?',
    complete = function(arg_lead)
      local options = { 'stable', 'latest' }
      return vim.tbl_filter(function(opt)
        return opt:find(arg_lead, 1, true) == 1
      end, options)
    end,
  })

  local cfg = { settings = { Odoo = { selectedProfile = M.config.profile } } }
  if M.config.cmd then
    cfg.cmd = M.config.cmd
  end
  vim.lsp.config('odoo_ls', cfg)

  local executable = resolve.get_executable()
  if executable == '' then
    M.installOdooLs()
    return
  end

  vim.lsp.enable('odoo_ls')

  if M.config.checkVersion then
    check_version(M.config.version, executable)
  end
end

return M
