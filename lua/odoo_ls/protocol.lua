--- Custom `$Odoo/*` notifications of odoo-ls, normalised into the state the API and health read.
local M = {}

local levels = vim.log.levels

---@class odoo_ls.ConfigDiagnostic
---@field level integer 1=warning, 2=error
---@field message string
---@field profile string

---@class odoo_ls.ServerDiagnostic
---@field level integer 0=info, 1=warning, 2=error
---@field message string

---@class odoo_ls.State
---@field pid integer|nil          server process id (from `$Odoo/setPid`)
---@field loading string|nil       last loading status ('start'|'stop'|other)
---@field js boolean|nil           whether the server's tsserver runs (from `$Odoo/jsLsStatus`)
---@field profiles string[]|nil    non-abstract profile names, nil before the first snapshot
---@field config table<string, any>|nil       active profile's values as plain Lua values
---@field sources table<string, string[]>|nil  sorted sources of each key in `config`
---@field config_files string[]|nil  every config file that contributed a value to any profile
---@field config_diagnostics odoo_ls.ConfigDiagnostic[]
---@field server_diagnostics odoo_ls.ServerDiagnostic[]
---@field crashed boolean
---@field crash_info string|nil    full crash text (from panic hook)

--- Normalised server state, written only by the handlers below and read by the API and health.
---@type odoo_ls.State
local state = {
  config_diagnostics = {},
  server_diagnostics = {},
  crashed = false,
}

local function notify(msg, level)
  vim.notify(msg, level, { title = 'odoo_ls' })
end

--- `lsp-handler`s keyed by method, registered on the client by `lsp/odoo_ls.lua`.
---@type table<string, fun(err:any, result:any, ctx:any, config:any)>
local handlers = {}

-- The first notification of a new server, so state left by a previous one is cleared here
handlers['$Odoo/setPid'] = function(_, result)
  state.pid = type(result) == 'table' and result.server_pid or nil
  state.crashed, state.crash_info = false, nil
  state.config_diagnostics, state.server_diagnostics = {}, {}
end

-- Loading status, sent as a bare string ('start'|'stop'|other)
handlers['$Odoo/loadingStatusUpdate'] = function(_, result)
  if type(result) ~= 'string' then
    return
  end
  state.loading = result
  if result == 'start' or result == 'stop' then
    return
  end
  if result == 'git_locked' then
    notify('indexing paused: git index locked', levels.WARN)
  else
    notify('status: ' .. result, levels.INFO)
  end
end

handlers['$Odoo/invalid_python_path'] = function()
  notify(
    'invalid python_path: the server could not spawn Python. Check python_path in odools.toml.',
    levels.ERROR
  )
end

handlers['$Odoo/restartNeeded'] = function()
  notify('server requested a restart', levels.INFO)
  require('odoo_ls.api').restart()
end

-- Unwrap the `{value, sources, info}` leaves of a config key, collecting their sources.
local function unwrap(v, sources)
  if type(v) ~= 'table' then
    return v
  end
  if v.sources then
    for _, src in ipairs(v.sources) do
      sources[src] = true
    end
    return v.value
  end
  local out = {}
  for k, e in pairs(v) do
    out[k] = unwrap(e, sources)
  end
  return out
end

local PROFILE_ATTRS = { name = true, extends = true, abstract = true }

--- Whether the odools.toml at `path` has keys but no `[[config]]` table, so the server ignores it.
---@param path string
---@return boolean
function M.lacks_config_table(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  local has_key = false
  for _, line in ipairs(ok and lines or {}) do
    if line:match('^%s*%[%[config%]%]') then
      return false
    end
    has_key = has_key or line:match('^%s*[^#%s][^=]*=') ~= nil
  end
  return has_key
end

local warned_main, warned_format = false, false

-- Full configuration snapshot, ignoring the `html` field meant for the VS Code webview
handlers['$Odoo/setConfiguration'] = function(_, result, ctx)
  if type(result) ~= 'table' then
    return
  end
  local client = vim.lsp.get_client_by_id(ctx.client_id)
  local active = client and vim.tbl_get(client.config, 'settings', 'Odoo', 'selectedProfile') or 'default'
  local profiles, files = {}, {}
  state.config, state.sources = nil, nil
  for _, p in ipairs(result.configFile.config) do
    if not p.abstract then
      table.insert(profiles, p.name)
    end
    local values, sources = {}, {}
    for key, v in pairs(p) do
      if not PROFILE_ATTRS[key] then
        local set = {}
        values[key] = unwrap(v, set)
        sources[key] = vim.tbl_keys(set)
        table.sort(sources[key])
        for src in pairs(set) do
          if src:sub(1, 1) == '/' then
            files[src] = true
          end
        end
      end
    end
    if p.name == active then
      state.config, state.sources = values, sources
    end
  end
  state.profiles = profiles
  if not warned_main and active == 'default' and vim.tbl_contains(profiles, 'main') then
    warned_main = true
    notify("this plugin now selects the `default` profile\nto keep `main`: setup({ profile = 'main' }) or rename it", levels.INFO)
  end
  local toml = client and client.root_dir and client.root_dir .. '/odools.toml'
  if not warned_format and toml and M.lacks_config_table(toml) then
    warned_format = true
    notify('odools.toml has no [[config]] table, so the server ignores it\nwrap its keys in [[config]]: ' .. vim.fn.fnamemodify(toml, ':~'), levels.WARN)
  end
  state.config_files = vim.tbl_keys(files)
  table.sort(state.config_files)
  state.config_diagnostics = result.diagnostics or {}
  for _, d in ipairs(state.config_diagnostics) do
    local lvl = d.level == 2 and levels.ERROR or levels.WARN
    local where = d.profile and d.profile ~= '' and (' [' .. d.profile .. ']') or ''
    notify('config' .. where .. ': ' .. tostring(d.message), lvl)
  end
end

-- tsserver status, a bare boolean that is true while the server's tsserver runs
handlers['$Odoo/jsLsStatus'] = function(_, result)
  state.js = result
end

local function server_level(n)
  if n == 2 then
    return levels.ERROR
  elseif n == 1 then
    return levels.WARN
  end
  return levels.INFO
end

-- Runtime server diagnostics, such as a tsserver startup failure
handlers['$Odoo/diagnostic_config'] = function(_, result)
  if type(result) ~= 'table' then
    return
  end
  if result.action == 'replace' then
    state.server_diagnostics = {}
  end
  for _, m in ipairs(result.messages or {}) do
    table.insert(state.server_diagnostics, m)
    notify('server: ' .. tostring(m.message), server_level(m.level))
  end
end

-- Panic-hook crash notification, the one method without a `$` prefix
handlers['Odoo/displayCrashNotification'] = function(_, result)
  state.crashed = true
  local info = type(result) == 'table' and result.crashInfo or nil
  state.crash_info = info
  local short = info and info:sub(1, 400) or 'server crashed'
  if info and #info > 400 then
    short = short .. '…'
  end
  notify('server crashed: ' .. short .. '\n(run :OdooLs for details)', levels.ERROR)
end

M.handlers = handlers
M.state = state

--- Reset volatile state when the client exits, called from the spec `on_exit`.
function M._on_exit()
  state.pid = nil
  state.js = nil
  state.loading = 'stop'
end

return M
