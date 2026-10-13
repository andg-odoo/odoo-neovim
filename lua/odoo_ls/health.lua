--- `:checkhealth odoo_ls`
local M = {}

local NAME = 'odoo_ls'

local uv = vim.uv

local protocol = require('odoo_ls.protocol')
local st = protocol.state

function M.check()
  local h = vim.health
  local server = require('odoo_ls.server')
  local profile = require('odoo_ls.api').active_profile()
  h.start('odoo-ls.nvim')

  if vim.fn.has('nvim-0.11.2') == 1 then
    local v = vim.version()
    h.ok(('Neovim %d.%d.%d'):format(v.major, v.minor, v.patch))
  else
    h.error('Neovim 0.11.2+ is required')
  end

  local resolved = server.effective()
  local cmd, source = resolved.cmd, resolved.source
  local label = ({
    user = 'user cmd (vim.lsp.config/setup)',
    managed = 'managed ' .. tostring(resolved.tag),
    legacy = 'legacy data-dir binary',
    path = 'PATH',
    none = 'none',
  })[source]

  local exe = cmd[1]
  local path = vim.fn.exepath(exe)
  if path == '' then
    h.error('server binary not found (source: ' .. label .. '): ' .. tostring(exe), {
      'Install a release with :OdooLs install, or',
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
    h.ok(('server binary [%s]: %s (%s)'):format(label, path, version))
    if source == 'legacy' then
      h.warn('legacy hand-placed install, run :OdooLs install to switch to managed installs')
    end
    local found = version:match('(%d+%.%d+%.%d+)')
    if found and found ~= server.VERSION then
      local fix = source == 'managed' and 'Run :OdooLs install' or 'Run :OdooLs install, or install odoo_ls_server ' .. server.VERSION
      h.warn(('server %s does not match the plugin version %s'):format(found, server.VERSION), { fix })
    end
  end

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
  local toml = running and running.root_dir and running.root_dir .. '/odools.toml'
  if toml and protocol.lacks_config_table(toml) then
    h.warn('odools.toml has no [[config]] table, so the server ignores it: ' .. vim.fn.fnamemodify(toml, ':~'), { 'Wrap its keys in [[config]]' })
  end
  local sources = st.config_files
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

  local clients = vim.lsp.get_clients({ name = NAME })
  if #clients == 0 then
    h.info('client not running (it attaches to python/xml/csv/js/ts files under an odools.toml)')
  else
    for _, c in ipairs(clients) do
      h.ok(('client running (id=%d, server pid=%s, profile=%s)'):format(c.id, tostring(st.pid or '?'), profile))
    end
    if st.loading then
      h.info('loading status: ' .. st.loading)
    end
    -- Files outside odoo_path/addons_paths are analyzed as isolated custom entry points
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
    local cfg = st.config or {}
    local roots = realpaths(vim.list_extend({ cfg.odoo_path }, cfg.addons_paths or {}))
    if #roots == 0 then
      h.info('buffer scope not checked (no odoo_path/addons_paths received from the server yet)')
    end
    local in_scope = 0
    for _, c in ipairs(clients) do
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
        end
      end
    end
    if in_scope > 0 then
      h.ok(('%d attached buffer(s) inside the configured project'):format(in_scope))
    end

    -- Watching needs both the server registration and the client capability (neovim#27807)
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

  -- The server loads typeshed from next to its own executable (odoo-ls server/src/core/odoo.rs).
  local typeshed = path ~= '' and vim.fs.joinpath(vim.fs.dirname(uv.fs_realpath(path) or path), 'typeshed')
  if typeshed and uv.fs_stat(typeshed .. '/stdlib') then
    h.ok('bundled typeshed: ' .. typeshed)
  elseif st.config and st.config.stdlib and st.config.stdlib ~= '' then
    h.ok('stdlib (odools.toml): ' .. st.config.stdlib)
  else
    h.info('no typeshed next to the binary - supply the standard library via odools.toml (stdlib / additional_stubs)')
  end

  local tsserver = vim.tbl_get(st, 'config', 'tsserver_command') or 'tsserver'
  if st.js ~= nil then
    h.info('tsserver running in the server: ' .. (st.js and 'yes' or 'no'))
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

  local companions = vim.lsp.get_clients({ name = 'pyright' })
  vim.list_extend(companions, vim.lsp.get_clients({ name = 'basedpyright' }))
  if #companions > 0 then
    h.warn('pyright/basedpyright is also attached - it overlaps with odoo-ls Python features and may conflict')
  end
  h.info('ruff (formatting/linting only) coexists fine with odoo-ls')

  if not st.config then
    h.info('no configuration received from the server yet')
  else
    h.start('odoo_ls: profile ' .. profile)
    local keys = vim.tbl_keys(st.config)
    table.sort(keys)
    local defaults = 0
    for _, k in ipairs(keys) do
      local v, sources = st.config[k], st.sources[k]
      -- `$default` is the server's built-in value, `$cli` and `$workspaceFolder:` are derived ones
      if vim.iter(sources):any(function(src)
        return src ~= '$default'
      end) then
        local shown = vim.islist(v) and table.concat(vim.tbl_map(tostring, v), ', ')
          or type(v) == 'table' and vim.inspect(v):gsub('%s+', ' ')
          or tostring(v)
        h.info(('%s = %s  (%s)'):format(k, shown, table.concat(sources, ', ')))
      else
        defaults = defaults + 1
      end
    end
    h.info(('%d other keys at their built-in defaults'):format(defaults))
    local others = vim.tbl_filter(function(name)
      return name ~= profile
    end, st.profiles)
    if #others > 0 then
      h.info('other profiles: ' .. table.concat(others, ', '))
    end
  end
  for _, d in ipairs(st.config_diagnostics) do
    local where = d.profile and d.profile ~= '' and (' [' .. d.profile .. ']') or ''
    local report = d.level == 2 and h.error or h.warn
    report('config' .. where .. ': ' .. tostring(d.message))
  end
  for _, d in ipairs(st.server_diagnostics) do
    local report = ({ [1] = h.warn, [2] = h.error })[d.level] or h.info
    report('server: ' .. tostring(d.message))
  end
  if st.crashed then
    local lines = vim.split(st.crash_info or 'server crashed', '\n', { plain = true })
    h.error(table.concat(vim.list_slice(lines, 1, 20), '\n'), { 'full text in :OdooLs logs' })
  end
end

return M
