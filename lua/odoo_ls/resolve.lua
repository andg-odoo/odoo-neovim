--- Single source of truth for locating the `odoo_ls_server` binary and building
--- the launch command. Used by the `lsp/odoo_ls.lua` spec and `:checkhealth`.
---
--- Resolution precedence (a `cmd` a user set via `vim.lsp.config`/`setup()`
--- wins over all of this by merge and is NOT considered here):
---   1. `odoo_ls_server` on `PATH`
---   2. the installer's data-dir binary (`stdpath('data')/odoo/odoo_ls_server`)
--- When the data-dir binary is used and its bundled typeshed stdlib is present,
--- `--stdlib` is appended so the server finds the standard library without an
--- `odools.toml`.
local M = {}

local uv = vim.uv or vim.loop

--- Root of the installer's managed install (matches installer.lua's layout).
M.data_dir = vim.fn.stdpath('data') .. '/odoo'

local function data_binary()
  return M.data_dir .. '/odoo_ls_server'
end

local function data_stdlib()
  return M.data_dir .. '/stdlib'
end

---@class odoo_ls.Resolution
---@field cmd string[]                 command to launch the server
---@field source 'path'|'data'|'none'  where the binary came from
---@field binary string                the resolved executable (name or path)
---@field stdlib string|nil            stdlib dir passed via --stdlib, if any

--- Resolve the default server command.
---@return odoo_ls.Resolution
function M.resolve()
  -- (1) PATH
  if vim.fn.executable('odoo_ls_server') == 1 then
    return { cmd = { 'odoo_ls_server' }, source = 'path', binary = 'odoo_ls_server' }
  end
  -- (2) data-dir install
  local bin = data_binary()
  if vim.fn.executable(bin) == 1 then
    local cmd = { bin }
    local stdlib
    if uv.fs_stat(data_stdlib()) then
      stdlib = data_stdlib()
      table.insert(cmd, '--stdlib')
      table.insert(cmd, stdlib)
    end
    return { cmd = cmd, source = 'data', binary = bin, stdlib = stdlib }
  end
  -- nothing installed: keep a well-formed default so the spec still loads
  return { cmd = { 'odoo_ls_server' }, source = 'none', binary = 'odoo_ls_server' }
end

--- Convenience: just the command list for the spec.
---@return string[]
function M.resolve_cmd()
  return M.resolve().cmd
end

--- Back-compat with the installer flow: '' when nothing is found, else the
--- resolved binary (name or absolute path).
---@return string
function M.get_executable()
  local r = M.resolve()
  return r.source == 'none' and '' or r.binary
end

--- The release tag of the data-dir install, read from the managed symlink
--- (`data/odoo/odoo_ls_server` -> `data/odoo/<tag>/odoo_ls_server`), or nil.
---@return string|nil
function M.installed_tag()
  local target = uv.fs_readlink(data_binary())
  if not target then
    return nil
  end
  return vim.fs.basename(vim.fs.dirname(target))
end

return M
