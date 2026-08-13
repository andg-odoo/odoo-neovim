--- `:checkhealth odoo_ls`
local M = {}

local NAME = 'odoo_ls'

local uv = vim.uv or vim.loop

local function resolved_cmd()
  local cfg = vim.lsp.config[NAME]
  if cfg and cfg.cmd then
    return cfg.cmd
  end
  return require('odoo_ls.resolve').resolve_cmd()
end

local function active_profile()
  return require('odoo_ls.api').active_profile()
end

-- The active profile's entry in the last setConfiguration, or nil.
local function profile_entry(profile)
  local cf = require('odoo_ls.protocol').state().config_file
  for _, p in ipairs(cf and cf.config or {}) do
    if p.name == profile then
      return p
    end
  end
end

-- Scalar config key: entries arrive as `{value=..., sources=...}`.
local function config_value(profile, key)
  local p = profile_entry(profile)
  local v = p and p[key]
  if type(v) == 'table' then
    return v.value
  end
  return v
end

-- List config key (e.g. addons_paths): array of `{value=...}` entries.
local function config_list(profile, key)
  local p = profile_entry(profile)
  local out = {}
  if p and vim.islist(p[key]) then
    for _, e in ipairs(p[key]) do
      if type(e) == 'table' and type(e.value) == 'string' and e.value ~= '' then
        table.insert(out, e.value)
      end
    end
  end
  return out
end

--- Every config file the server drew a value from, nil before the first snapshot arrives.
local function config_sources()
  local cf = require('odoo_ls.protocol').state().config_file
  if not cf or not cf.config then
    return nil
  end
  local seen, out = {}, {}
  local function collect(v)
    if type(v) ~= 'table' then
      return
    end
    for _, src in ipairs(v.sources or {}) do
      if type(src) == 'string' and src:sub(1, 1) == '/' and not seen[src] then
        seen[src] = true
        table.insert(out, src)
      end
    end
    if vim.islist(v) then
      for _, item in ipairs(v) do
        collect(item)
      end
    end
  end
  for _, profile in ipairs(cf.config) do
    for _, value in pairs(profile) do
      collect(value)
    end
  end
  table.sort(out)
  return out
end

-- The stdlib dir passed on the command line, if any (`--stdlib <dir>`).
local function stdlib_arg(cmd)
  for i, a in ipairs(cmd) do
    if a == '--stdlib' then
      return cmd[i + 1]
    end
  end
  return nil
end

function M.check()
  local h = vim.health
  local resolve = require('odoo_ls.resolve')
  h.start('odoo-ls.nvim')

  -- Neovim version -----------------------------------------------------------
  if vim.fn.has('nvim-0.11.2') == 1 then
    local v = vim.version()
    h.ok(('Neovim %d.%d.%d'):format(v.major, v.minor, v.patch))
  else
    h.error('Neovim 0.11.2+ is required')
  end

  -- Server binary ------------------------------------------------------------
  -- Report which of the three sources won: an explicit user `cmd`, `PATH`, or
  -- the installer's data-dir binary.
  local cmd = resolved_cmd()
  local default = resolve.resolve()
  local source
  if vim.deep_equal(cmd, default.cmd) then
    source = default.source
  else
    source = 'user'
  end
  local labels = {
    user = 'user cmd (vim.lsp.config/setup)',
    path = 'PATH',
    data = 'installer data-dir',
    none = 'none',
  }

  local exe = cmd[1]
  local path = vim.fn.exepath(exe)
  if path == '' and uv.fs_stat(exe) then
    path = exe -- absolute path not on PATH (data-dir install)
  end
  if path == '' then
    h.error('server binary not found (source: ' .. labels[source] .. '): ' .. tostring(exe), {
      'Install via :OdooLsInstall (downloads a release), or',
      'put odoo_ls_server on PATH, or',
      "point at it: vim.lsp.config('odoo_ls', { cmd = { '/abs/path/odoo_ls_server' } })",
    })
  else
    local version = 'version unknown'
    local ok, res = pcall(function()
      return vim.system({ exe, '--version' }, { text = true }):wait(5000)
    end)
    if ok and res and res.stdout and vim.trim(res.stdout) ~= '' then
      version = vim.trim(res.stdout)
    end
    h.ok(('server binary [%s]: %s (%s)'):format(labels[source], path, version))
    local tag = resolve.installed_tag()
    if tag then
      h.info('installer data-dir release: ' .. tag)
    end
  end

  -- odools.toml ---------------------------------------------------------------
  -- The snapshot is authoritative because --config-path pins only one of several merged sources.
  local pinned
  for i, arg in ipairs(cmd) do
    if arg == '--config-path' then
      pinned = cmd[i + 1]
    end
  end
  local running = vim.lsp.get_clients({ name = NAME })[1]
  if pinned and not uv.fs_stat(vim.fs.normalize(pinned)) then
    h.error('--config-path points at a missing file: ' .. pinned)
  end
  local sources = config_sources()
  if sources and #sources > 0 then
    local lines = { ('odools.toml in effect (%d):'):format(#sources) }
    for _, src in ipairs(sources) do
      table.insert(lines, ('  %s%s'):format(src, src == pinned and '  (pinned via --config-path)' or ''))
    end
    h.ok(table.concat(lines, '\n'))
  elseif sources then
    h.info('no odools.toml contributed a value - the server is running on built-in defaults')
  else
    -- No snapshot yet (client down, or setConfiguration not in): show what would be read.
    local start_dir = (running and running.root_dir) or vim.fn.getcwd()
    local found = vim.fs.find('odools.toml', { upward = true, path = start_dir })
    local candidates = {}
    if pinned then
      table.insert(candidates, pinned .. '  (pinned via --config-path)')
    end
    for _, f in ipairs(found) do
      if f ~= pinned then
        table.insert(candidates, f .. ('  (found upward from %s)'):format(start_dir))
      end
    end
    if #candidates > 0 then
      h.info(table.concat(
        vim.list_extend({ 'odools.toml candidates (start the client for the definitive list):' }, candidates),
        '\n  '
      ))
    else
      h.info(('no odools.toml found upward from %s - the server will run with built-in defaults ("default" profile)'):format(start_dir))
    end
  end

  -- Client -------------------------------------------------------------------
  local clients = vim.lsp.get_clients({ name = NAME })
  if #clients == 0 then
    h.info('client not running (open a python/xml/csv/javascript file in a project to start it)')
  else
    local st = require('odoo_ls.protocol').state()
    for _, c in ipairs(clients) do
      h.ok(('client running (id=%d, server pid=%s, profile=%s)'):format(c.id, tostring(st.pid or '?'), active_profile()))
    end
    if st.loading then
      h.info('loading status: ' .. st.loading)
    end
    if st.crashed then
      h.error('the server reported a crash - see :OdooLs config')
    end
    if #st.config_diagnostics > 0 or #st.server_diagnostics > 0 then
      h.warn(('%d config diagnostic(s), %d server diagnostic(s) - see :OdooLs config'):format(
        #st.config_diagnostics,
        #st.server_diagnostics
      ))
    end

    -- Per-buffer checks: two independent verdicts.
    -- (scope) Files outside odoo_path/addons_paths are analyzed as isolated
    -- "custom entry points" - model completions/hover degraded while the
    -- client looks healthy (reads as "the plugin broke" when opening a file
    -- from another odoo worktree).
    -- (coverage) The server fully re-analyzes MODIFIED buffers only when they
    -- live under a workspace folder: an uncovered buffer silently degrades on
    -- its first edit (types become Any, semantic tokens drop) until reloaded,
    -- even inside odoo_path.
    local function realpaths(list)
      return vim.tbl_map(function(p)
        return uv.fs_realpath(p) or p
      end, list)
    end
    local function under(path, dirs)
      for _, d in ipairs(dirs) do
        if path == d or path:sub(1, #d + 1) == d .. '/' then
          return true
        end
      end
      return false
    end
    local prof = active_profile()
    local roots = {}
    local odoo_path = config_value(prof, 'odoo_path')
    if type(odoo_path) == 'string' and odoo_path ~= '' then
      table.insert(roots, odoo_path)
    end
    vim.list_extend(roots, config_list(prof, 'addons_paths'))
    roots = realpaths(roots)
    if #roots == 0 then
      h.info('buffer scope not checked (no odoo_path/addons_paths received from the server yet)')
    end
    local in_scope = 0
    for _, c in ipairs(clients) do
      local folders = realpaths(vim.tbl_map(function(wf)
        return vim.uri_to_fname(wf.uri)
      end, c.workspace_folders or {}))
      if #folders == 0 then
        h.warn('client has no workspace folders - every buffer degrades on its first edit')
      end
      for buf in pairs(c.attached_buffers or {}) do
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= '' then
          local real = uv.fs_realpath(name) or name
          local short = vim.fn.fnamemodify(name, ':~')
          if #roots > 0 and not under(real, roots) then
            h.warn(short .. ' is OUTSIDE odoo_path/addons_paths - analyzed as an isolated custom entry point (model completions/hover degraded)', {
              'Add its addons directory to addons_paths in odools.toml, or',
              'switch to a profile whose odoo_path covers this checkout (:OdooLs profile)',
            })
          elseif #roots > 0 then
            in_scope = in_scope + 1
          end
          if #folders > 0 and not under(real, folders) then
            h.warn(short .. ' is not under any WORKSPACE FOLDER - analysis degrades on the first edit (types become Any) until the file is reloaded', {
              'Cover your checkouts explicitly:',
              "vim.lsp.config('odoo_ls', { workspace_folders = { { uri = vim.uri_from_fname('/path/to/odoo'), name = 'odoo' } } })",
              'or open the file from a directory whose root_markers resolve to the checkout.',
            })
          end
        end
      end
    end
    if in_scope > 0 then
      h.ok(('%d attached buffer(s) inside the configured project'):format(in_scope))
    end

    -- File watcher ----------------------------------------------------------
    -- The server registers a workspace/didChangeWatchedFiles watcher, but
    -- Neovim only honors it when the CLIENT advertised dynamicRegistration
    -- for it - which core disables by default on Linux/BSD (limited backends,
    -- see neovim #27807). Both halves must be true for watching to work.
    local c = clients[1]
    local advertised = vim.tbl_get(c.capabilities, 'workspace', 'didChangeWatchedFiles', 'dynamicRegistration') == true
    local registered = false
    for _, regs in pairs(c.registrations or {}) do
      for _, reg in ipairs(regs) do
        if reg.method == 'workspace/didChangeWatchedFiles' then
          registered = true
        end
      end
    end
    if advertised and registered then
      h.ok('file watching active (registered + advertised)')
      h.info('watching can be heavy over very large trees')
    elseif not advertised then
      h.warn('file watching is OFF: Neovim disables it by default on this OS, so external changes (git pull, branch switches, generated files) will NOT refresh the server index', {
        'Opt in (mind the CPU cost on huge trees):',
        "vim.lsp.config('odoo_ls', { capabilities = { workspace = { didChangeWatchedFiles = { dynamicRegistration = true } } } })",
        'Without it, use :OdooLs restart after external changes.',
      })
    else
      h.info('watcher registration not received yet - it arrives shortly after the server initializes')
    end
    h.info('no odools.toml is covered by the watcher: edit them inside Neovim or the changes are missed')
  end

  -- typeshed / stdlib --------------------------------------------------------
  -- Data-dir installs bundle typeshed (and the spec points --stdlib at it).
  -- PATH/cargo binaries have no bundled stubs, so the standard library must be
  -- supplied via odools.toml (stdlib / additional_stubs) or a --stdlib flag.
  local stdlib = stdlib_arg(cmd)
  if stdlib then
    if uv.fs_stat(stdlib) then
      h.ok('stdlib (--stdlib): ' .. stdlib)
    else
      h.warn('--stdlib points at a missing directory: ' .. stdlib)
    end
  elseif source == 'data' then
    local typeshed = resolve.data_dir .. '/typeshed'
    if uv.fs_stat(typeshed) then
      h.ok('bundled typeshed: ' .. typeshed)
    else
      h.warn('data-dir install has no typeshed - reinstall via :OdooLsInstall')
    end
  else
    h.info('no bundled typeshed for this binary - supply the standard library via odools.toml (stdlib / additional_stubs) or a --stdlib flag')
  end

  -- tsserver -----------------------------------------------------------------
  local profile = active_profile()
  local tsserver = config_value(profile, 'tsserver_command')
  if tsserver == nil then
    -- fall back to the documented default
    tsserver = 'tsserver'
  end
  if tsserver == '' then
    h.info('tsserver_command is empty - JavaScript/OWL features are deliberately disabled')
  else
    local tspath = vim.fn.exepath(tsserver)
    if tspath ~= '' then
      h.ok('tsserver: ' .. tspath)
    elseif tsserver == 'tsserver' then
      h.warn('tsserver not found - JavaScript/OWL features will silently degrade', {
        'Install it: npm install -g typescript',
        'or set tsserver_command in odools.toml (empty string disables JS features)',
      })
    else
      h.warn('tsserver_command "' .. tostring(tsserver) .. '" not found on PATH')
    end
  end

  -- Companion language servers ----------------------------------------------
  local companions = vim.lsp.get_clients({ name = 'pyright' })
  vim.list_extend(companions, vim.lsp.get_clients({ name = 'basedpyright' }))
  if #companions > 0 then
    h.warn('pyright/basedpyright is also attached - it overlaps with odoo-ls Python features and may conflict')
  end
  h.info('ruff (formatting/linting only) coexists fine with odoo-ls')
end

return M
