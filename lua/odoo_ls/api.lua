--- Client-side controls for the odoo-ls server: restart, profile switching,
--- the config view, logs and a statusline snapshot. These are ergonomics you
--- compose yourself; they are re-exported from `require('odoo_ls')`.
---
--- The server owns all real configuration (via `odools.toml`, discovered
--- server-side). The only client-side setting is which profile to select, and
--- switching it REQUIRES a server restart: the server reads its configuration
--- only on init (`workspace/didChangeConfiguration` is a no-op server-side).
local M = {}

local protocol = require('odoo_ls.protocol')

local NAME = 'odoo_ls'

local function notify(msg, level)
  vim.notify(msg, level, { title = 'odoo_ls' })
end

---@return vim.lsp.Client[]
local function get_clients()
  return vim.lsp.get_clients({ name = NAME })
end

---@return string
local function active_profile()
  local client = get_clients()[1]
  if client and client.config and client.config.settings then
    return vim.tbl_get(client.config.settings, 'Odoo', 'selectedProfile') or 'default'
  end
  local cfg = vim.lsp.config[NAME]
  return cfg and vim.tbl_get(cfg, 'settings', 'Odoo', 'selectedProfile') or 'default'
end

M.active_profile = active_profile

--- Restart the server: remember each client's config + attached buffers, stop
--- it (force-kill if graceful shutdown stalls, e.g. mid-index), then start it
--- again against the same buffers. Required after switching profiles.
---
--- Deliberately NOT the core `vim.lsp.enable(name, false)` + `enable(name,
--- true)` restart idiom: that starts the new client while the old one is still
--- shutting down (both briefly attached to the same buffers) and never
--- force-kills a stalled server.
function M.restart()
  local clients = get_clients()
  if #clients == 0 then
    -- nothing running yet: (re)enable so it starts on the next matching buffer
    vim.lsp.enable(NAME)
    return
  end
  for _, client in ipairs(clients) do
    local config = client.config
    local bufs = vim.tbl_keys(client.attached_buffers)
    client:stop()
    local timer = assert(vim.uv.new_timer())
    local waited = 0
    timer:start(
      50,
      50,
      vim.schedule_wrap(function()
        waited = waited + 50
        if not client:is_stopped() then
          if waited == 4000 then
            -- graceful shutdown stalled (e.g. mid-index); force-kill so we
            -- never start a second client next to a live one
            client:stop(true)
          end
          if waited < 8000 then
            return
          end
        end
        timer:stop()
        if not timer:is_closing() then
          timer:close()
        end
        -- The restarted client is created fresh from `config`, so its
        -- `settings.Odoo.selectedProfile` is what answers workspace/configuration.
        for _, bufnr in ipairs(bufs) do
          if vim.api.nvim_buf_is_valid(bufnr) then
            vim.lsp.start(config, { bufnr = bufnr })
          end
        end
      end)
    )
  end
end

--- Set the selected profile and restart the server so it takes effect.
--- Written to both the stored spec (for future `vim.lsp.enable` starts) and
--- the running client's `config.settings` (which `M.restart()` reuses).
---@param profile string
function M.set_profile(profile)
  vim.lsp.config(NAME, { settings = { Odoo = { selectedProfile = profile } } })
  for _, client in ipairs(get_clients()) do
    client.config.settings = client.config.settings or {}
    client.config.settings.Odoo = client.config.settings.Odoo or {}
    client.config.settings.Odoo.selectedProfile = profile
  end
  M.restart()
end

--- Pick a profile via `vim.ui.select` and apply it. Profiles are the
--- non-abstract entries from the last `$Odoo/setConfiguration`, plus a
--- `"Disabled"` entry (a client-side convention that makes the server idle).
function M.select_profile()
  local cf = protocol.state().config_file
  if not cf or not cf.config then
    notify('no configuration received from the server yet', vim.log.levels.WARN)
    return
  end
  local profiles = {}
  for _, p in ipairs(cf.config) do
    if not p.abstract then
      table.insert(profiles, p.name)
    end
  end
  table.insert(profiles, 'Disabled')
  local current = active_profile()
  vim.ui.select(profiles, {
    prompt = 'odoo_ls profile:',
    format_item = function(item)
      return item == current and (item .. '  (current)') or item
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice == current then
      notify('profile "' .. choice .. '" is already active', vim.log.levels.INFO)
      return
    end
    M.set_profile(choice)
  end)
end

--- Cheap status snapshot for statuslines. No allocation-heavy work.
---@return { running:boolean, loading:string|nil, pid:integer|nil, profile:string|nil, config_errors:integer, config_warnings:integer, crashed:boolean }
function M.status()
  local st = protocol.state()
  local client = get_clients()[1]
  local profile
  if client and client.config and client.config.settings then
    profile = vim.tbl_get(client.config.settings, 'Odoo', 'selectedProfile')
  end
  local errors, warnings = 0, 0
  for _, d in ipairs(st.config_diagnostics) do
    if d.level == 2 then
      errors = errors + 1
    else
      warnings = warnings + 1
    end
  end
  for _, d in ipairs(st.server_diagnostics) do
    if d.level == 2 then
      errors = errors + 1
    elseif d.level == 1 then
      warnings = warnings + 1
    end
  end
  return {
    running = client ~= nil,
    loading = st.loading,
    pid = st.pid,
    profile = profile,
    config_errors = errors,
    config_warnings = warnings,
    crashed = st.crashed,
  }
end

-- Render a single config-key entry (scalar `{value,sources,info}` or a list of
-- such) as markdown lines.
local function render_key(key, v, indent)
  indent = indent or ''
  if type(v) == 'table' and v.value ~= nil then
    local src = ''
    if type(v.sources) == 'table' and #v.sources > 0 then
      src = ('  _(sources: %s)_'):format(table.concat(vim.tbl_map(tostring, v.sources), ', '))
    end
    return { ('%s- **%s**: `%s`%s'):format(indent, key, tostring(v.value), src) }
  elseif vim.islist(v) then
    local vals = {}
    for _, e in ipairs(v) do
      if type(e) == 'table' and e.value ~= nil then
        table.insert(vals, tostring(e.value))
      else
        table.insert(vals, tostring(e))
      end
    end
    return { ('%s- **%s**: [%s]'):format(indent, key, table.concat(vals, ', ')) }
  end
  return { ('%s- **%s**: %s'):format(indent, key, (vim.inspect(v):gsub('%s+', ' '))) }
end

local RESERVED = { name = true, extends = true, abstract = true }

local function config_report()
  local st = protocol.state()
  local lines = {}
  local function add(s)
    table.insert(lines, s or '')
  end

  add('# odoo-ls')
  add('')
  add('- **active profile**: `' .. active_profile() .. '`')
  add('- **server pid**: ' .. tostring(st.pid or '-'))
  add('- **loading**: ' .. tostring(st.loading or '-'))
  if st.crashed then
    add('- **crashed**: yes')
  end
  add('')

  local cf = st.config_file
  if cf and cf.config then
    add('## Profiles')
    add('')
    for _, p in ipairs(cf.config) do
      local tags = {}
      if p.extends and p.extends ~= '' then
        table.insert(tags, 'extends ' .. p.extends)
      end
      if p.abstract then
        table.insert(tags, 'abstract')
      end
      local suffix = #tags > 0 and (' _(' .. table.concat(tags, ', ') .. ')_') or ''
      add(('### %s%s'):format(tostring(p.name), suffix))
      local keys = {}
      for k in pairs(p) do
        if not RESERVED[k] then
          table.insert(keys, k)
        end
      end
      table.sort(keys)
      if #keys == 0 then
        add('- _(no explicit keys)_')
      else
        for _, k in ipairs(keys) do
          vim.list_extend(lines, render_key(k, p[k]))
        end
      end
      add('')
    end
  else
    add('_No configuration received from the server yet._')
    add('')
  end

  if #st.config_diagnostics > 0 then
    add('## Config diagnostics')
    add('')
    for _, d in ipairs(st.config_diagnostics) do
      local tag = d.level == 2 and 'ERROR' or 'WARN'
      local where = d.profile and d.profile ~= '' and (' [' .. d.profile .. ']') or ''
      add(('- **%s**%s: %s'):format(tag, where, tostring(d.message)))
    end
    add('')
  end

  if #st.server_diagnostics > 0 then
    add('## Server diagnostics')
    add('')
    for _, d in ipairs(st.server_diagnostics) do
      local tag = ({ [0] = 'INFO', [1] = 'WARN', [2] = 'ERROR' })[d.level] or 'INFO'
      add(('- **%s**: %s'):format(tag, tostring(d.message)))
    end
    add('')
  end

  if st.crashed and st.crash_info then
    add('## Crash')
    add('')
    add('```')
    for _, l in ipairs(vim.split(st.crash_info, '\n', { plain = true })) do
      add(l)
    end
    add('```')
  end

  return lines
end

--- Open a scratch float rendering the active profile, all profiles with their
--- key values/sources, and any config/server diagnostics. Rendered as markdown.
function M.show_config()
  local lines = config_report()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  local width = math.min(100, math.floor(vim.o.columns * 0.85))
  -- fit the float to its content; long lines wrap, so budget an extra row
  -- per line that exceeds the width, capped at 80% of the editor
  local content_height = 0
  for _, l in ipairs(lines) do
    content_height = content_height + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
  end
  local height = math.max(3, math.min(content_height, math.floor(vim.o.lines * 0.8)))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' odoo_ls config ',
  })
  vim.wo[win].wrap = true
  vim.wo[win].conceallevel = 2
  vim.keymap.set('n', 'q', '<cmd>close<cr>', { buffer = buf, nowait = true, desc = 'close' })
end

--- Open the newest server log file (`<exe_dir>/logs/`).
function M.open_logs()
  local exe = require('odoo_ls.resolve').resolve().binary
  local path = vim.fn.exepath(exe)
  if path == '' then
    -- resolve may return an absolute path (data-dir install) that is not on PATH
    if vim.uv.fs_stat(exe) then
      path = exe
    else
      notify('server binary not found: ' .. exe, vim.log.levels.ERROR)
      return
    end
  end
  local dir = vim.fs.joinpath(vim.fs.dirname(path), 'logs')
  if vim.fn.isdirectory(dir) == 0 then
    notify('no logs directory: ' .. dir, vim.log.levels.WARN)
    return
  end
  local newest, newest_mtime
  for name, t in vim.fs.dir(dir) do
    if t == 'file' then
      local full = vim.fs.joinpath(dir, name)
      local stat = vim.uv.fs_stat(full)
      if stat and (not newest_mtime or stat.mtime.sec > newest_mtime) then
        newest_mtime = stat.mtime.sec
        newest = full
      end
    end
  end
  vim.cmd.edit(vim.fn.fnameescape(newest or dir))
end

return M
