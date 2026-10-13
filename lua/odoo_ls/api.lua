--- Client controls: restart, profile switching, status and logs.
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

--- Stop each client, force-killing a stalled shutdown, then start it again on the same buffers.
function M.restart()
  local clients = get_clients()
  if #clients == 0 then
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
            -- force-kill a stalled shutdown so the restart never overlaps a live client
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
        for _, bufnr in ipairs(bufs) do
          if vim.api.nvim_buf_is_valid(bufnr) then
            vim.lsp.start(config, { bufnr = bufnr })
          end
        end
      end)
    )
  end
end

--- Select `profile` in the stored spec and the running clients' settings, then restart.
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

--- Pick a profile from the last snapshot, or `"Disabled"` to idle the server, and apply it.
function M.select_profile()
  if not protocol.state.profiles then
    notify('no configuration received from the server yet', vim.log.levels.WARN)
    return
  end
  local profiles = vim.list_extend(vim.list_slice(protocol.state.profiles), { 'Disabled' })
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

--- Open the newest server log file (`<exe_dir>/logs/`).
function M.open_logs()
  local exe = require('odoo_ls.server').effective().cmd[1]
  local path = vim.fn.exepath(exe)
  if path == '' then
    notify('server binary not found: ' .. tostring(exe), vim.log.levels.ERROR)
    return
  end
  local dir = vim.fs.joinpath(vim.fs.dirname(vim.uv.fs_realpath(path) or path), 'logs')
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
