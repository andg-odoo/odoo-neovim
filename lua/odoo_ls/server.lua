--- Where the odoo_ls_server binary lives: the managed install layout, launch command and updates.
local M = {}

local uv = vim.uv
local DOWNLOAD = 'https://github.com/odoo/odoo-ls/releases/download'
local EXE = vim.fn.has('win32') == 1 and 'odoo_ls_server.exe' or 'odoo_ls_server'

--- Server release this plugin version is built for, bumped with every odoo-ls release.
M.VERSION = '1.6.1'

--- Managed installs root: one `<tag>/` per release, `current` names the active one.
M.root = vim.fn.stdpath('data') .. '/odoo'

local noticed, installing = false, false

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'odoo_ls' })
end

---@param cmd string[]
---@param on_done fun(err: string?, stdout: string?)
local function run(cmd, on_done)
  local ok, err = pcall(vim.system, cmd, { text = true }, function(out)
    vim.schedule(function()
      if out.code == 0 then
        return on_done(nil, out.stdout)
      end
      local stderr = vim.trim(out.stderr or '')
      on_done(stderr ~= '' and stderr or ('%s exited with code %d'):format(cmd[1], out.code))
    end)
  end)
  if not ok then
    vim.schedule(function()
      on_done(tostring(err))
    end)
  end
end

--- Fetch `url` into the file `dest`, or into the callback's second argument when `dest` is nil.
---@param on_done fun(err: string?, body: string?)
function M.download(url, dest, on_done)
  local cmd = { 'curl', '-fsSL', '--connect-timeout', '15', url }
  if dest then
    vim.list_extend(cmd, { '-o', dest })
  end
  run(cmd, on_done)
end

---@return string? os, string? arch_or_err
function M.platform()
  local u = uv.os_uname()
  local os_name = ({ Darwin = 'darwin', Linux = 'linux', Windows_NT = 'win32' })[u.sysname]
  if os_name == 'linux' and uv.fs_stat('/etc/alpine-release') then
    os_name = 'alpine'
  end
  local x86, arm = 'x86_64', 'aarch64'
  local arch = ({ x86_64 = x86, ['x86-64'] = x86, AMD64 = x86, aarch64 = arm, arm64 = arm })[u.machine]
  if not os_name or not arch then
    return nil, ('unsupported platform: %s %s'):format(u.sysname, u.machine)
  end
  return os_name, arch
end

--- The tag written in `<root>/current`, or nil.
---@return string?
function M.tag()
  local ok, lines = pcall(vim.fn.readfile, M.root .. '/current')
  return ok and lines[1] and lines[1] ~= '' and lines[1] or nil
end

---@class odoo_ls.Resolution
---@field cmd string[]
---@field source 'managed'|'legacy'|'path'|'none'
---@field tag string?

--- Resolve the default launch command: managed install, then the legacy data-dir binary, then PATH.
---@return odoo_ls.Resolution
function M.resolve()
  local tag = M.tag()
  local managed = tag and ('%s/%s/%s'):format(M.root, tag, EXE)
  if managed and vim.fn.executable(managed) == 1 then
    return { cmd = { managed }, source = 'managed', tag = tag }
  end
  local legacy = M.root .. '/' .. EXE
  if vim.fn.executable(legacy) == 1 then
    return { cmd = { legacy }, source = 'legacy' }
  end
  return { cmd = { 'odoo_ls_server' }, source = vim.fn.executable('odoo_ls_server') == 1 and 'path' or 'none' }
end

--- The launch command in effect: the user's `cmd` when one is set, else the resolved one.
---@return odoo_ls.Resolution
function M.effective()
  local cmd = (vim.lsp.config.odoo_ls or {}).cmd
  if type(cmd) == 'table' then
    return { cmd = cmd, source = 'user' }
  end
  return M.resolve()
end

--- The `cmd` of the lsp/ spec: resolves on each start, so a fresh install needs no reload.
---@param dispatchers vim.lsp.rpc.Dispatchers
---@return vim.lsp.rpc.PublicClient
function M.start(dispatchers)
  local r = M.resolve()
  local msg = ({
    legacy = 'found a legacy odoo_ls_server, run :OdooLs install to switch to managed installs\n' .. r.cmd[1],
    none = 'no odoo_ls_server found, run :OdooLs install',
  })[r.source]
  if msg and not noticed then
    noticed = true
    notify(msg, r.source == 'none' and vim.log.levels.WARN or nil)
  end
  return vim.lsp.rpc.start(r.cmd, dispatchers)
end

local function activate(tag)
  vim.fn.writefile({ tag }, M.root .. '/current')
  for _, name in ipairs({ EXE, 'stdlib', 'typeshed' }) do
    local stat = uv.fs_lstat(M.root .. '/' .. name)
    if stat and stat.type == 'link' then
      uv.fs_unlink(M.root .. '/' .. name)
    end
  end
  for name, kind in vim.fs.dir(M.root) do
    local dir = M.root .. '/' .. name
    if kind == 'directory' and name ~= tag and uv.fs_stat(dir .. '/' .. EXE) then
      -- A running server on Windows locks its dir, so this cleanup is best-effort.
      pcall(vim.fn.delete, dir, 'rf')
    end
  end
end

--- Install a release into `<root>/<tag>/` and make it current, calling `on_done(err)` either way.
---@param tag string
---@param on_done? fun(err: string?)
function M.install(tag, on_done)
  on_done = on_done or function() end
  local os_name, arch = M.platform()
  local refused = installing and 'an install is already running' or not os_name and arch
  if refused then
    notify('install failed: ' .. refused, vim.log.levels.ERROR)
    return on_done(refused)
  end
  installing = true
  local tmp
  local function finish(err)
    installing = false
    if err then
      if tmp then
        vim.fn.delete(tmp, 'rf')
      end
      notify('install failed: ' .. err, vim.log.levels.ERROR)
      return on_done(err)
    end
    activate(tag)
    notify('installed odoo_ls_server ' .. tag)
    on_done()
  end
  local dir = M.root .. '/' .. tag
  if uv.fs_stat(dir .. '/' .. EXE) and uv.fs_stat(dir .. '/typeshed') then
    return finish()
  end
  notify('installing odoo_ls_server ' .. tag .. '...')
  tmp = dir .. '.tmp'
  vim.fn.delete(tmp, 'rf')
  vim.fn.mkdir(tmp .. '/typeshed', 'p')
  local archive = ('odoo-%s-%s-%s.%s'):format(os_name, arch, tag, os_name == 'win32' and 'zip' or 'tar.gz')
  local server, typeshed = tmp .. '/' .. archive, tmp .. '/typeshed.zip'
  local unzip = os_name == 'win32' and { 'tar', '-xf', typeshed, '-C', tmp .. '/typeshed' }
    or { 'unzip', '-oq', typeshed, '-d', tmp .. '/typeshed' }
  local steps = {
    function(cb) M.download(('%s/%s/%s'):format(DOWNLOAD, tag, archive), server, cb) end,
    function(cb) run({ 'tar', os_name == 'win32' and '-xf' or '-xzf', server, '-C', tmp }, cb) end,
    function(cb) M.download(('%s/%s/typeshed.zip'):format(DOWNLOAD, tag), typeshed, cb) end,
    function(cb) run(unzip, cb) end,
  }
  local i = 0
  local function step(step_err)
    i = i + 1
    if step_err then
      return finish(step_err)
    elseif steps[i] then
      return steps[i](step)
    elseif not uv.fs_stat(tmp .. '/' .. EXE) then
      return finish(archive .. ' holds no ' .. EXE)
    end
    vim.fn.delete(server)
    vim.fn.delete(typeshed)
    -- An install dir left by the previous installer may be partial.
    vim.fn.delete(dir, 'rf')
    local ok, rename_err = uv.fs_rename(tmp, dir)
    finish(not ok and rename_err or nil)
  end
  step()
end

return M
