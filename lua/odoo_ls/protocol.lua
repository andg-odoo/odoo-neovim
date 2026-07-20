--- Custom `$Odoo/*` notification protocol for the odoo-ls language server.
---
--- The server owns all real configuration (via `odools.toml`, discovered
--- server-side). This module only reflects the small stream of server-pushed
--- notifications into `vim.notify` and a module-local state table that the
--- public API (`odoo_ls`) reads for statuslines, `:OdooLs config`, and health.
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
---@field config_file table|nil    `configFile` from `$Odoo/setConfiguration`
---@field config_diagnostics odoo_ls.ConfigDiagnostic[]
---@field server_diagnostics odoo_ls.ServerDiagnostic[]
---@field crashed boolean
---@field crash_info string|nil    full crash text (from panic hook)

---@type odoo_ls.State
local state = {
  pid = nil,
  loading = nil,
  config_file = nil,
  config_diagnostics = {},
  server_diagnostics = {},
  crashed = false,
  crash_info = nil,
}

local function notify(msg, level)
  vim.notify(msg, level, { title = 'odoo_ls' })
end

--- LSP notification handlers keyed by method. Registered on the client via
--- `lsp/odoo_ls.lua`. Signature matches nvim's `lsp-handler`:
--- `fun(err, result, ctx, config)` where `result` is the notification params.
--- All handlers are resilient to nil / unexpected payloads.
---@type table<string, fun(err:any, result:any, ctx:any, config:any)>
local handlers = {}

handlers['$Odoo/setPid'] = function(_, result)
  if type(result) == 'table' then
    state.pid = result.server_pid
  end
end

-- Loading status. Payload is a BARE STRING ('start'|'stop'|other).
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
  require('odoo_ls').restart()
end

-- Full configuration snapshot (profiles + config-file diagnostics).
-- The `html` field is vscode webview fodder and is ignored.
handlers['$Odoo/setConfiguration'] = function(_, result)
  if type(result) ~= 'table' then
    return
  end
  state.config_file = result.configFile
  state.config_diagnostics = result.diagnostics or {}
  for _, d in ipairs(state.config_diagnostics) do
    local lvl = d.level == 2 and levels.ERROR or levels.WARN
    local where = d.profile and d.profile ~= '' and (' [' .. d.profile .. ']') or ''
    notify('config' .. where .. ': ' .. tostring(d.message), lvl)
  end
end

local function server_level(n)
  if n == 2 then
    return levels.ERROR
  elseif n == 1 then
    return levels.WARN
  end
  return levels.INFO
end

-- Runtime server diagnostics (e.g. tsserver startup failure).
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

-- Panic-hook crash notification. NOTE: no `$` prefix.
handlers['Odoo/displayCrashNotification'] = function(_, result)
  state.crashed = true
  local info = type(result) == 'table' and result.crashInfo or nil
  state.crash_info = info
  local short = info and info:sub(1, 400) or 'server crashed'
  if info and #info > 400 then
    short = short .. '…'
  end
  notify('server crashed: ' .. short .. '\n(run :OdooLs config for full details)', levels.ERROR)
end

M.handlers = handlers

--- Reset volatile state when the client exits. Called from the spec `on_exit`.
function M._on_exit()
  state.pid = nil
  state.loading = 'stop'
end

--- Read-only shallow copy of the current protocol state.
---@return odoo_ls.State
function M.state()
  return {
    pid = state.pid,
    loading = state.loading,
    config_file = state.config_file,
    config_diagnostics = state.config_diagnostics,
    server_diagnostics = state.server_diagnostics,
    crashed = state.crashed,
    crash_info = state.crash_info,
  }
end

return M
