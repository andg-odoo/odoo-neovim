--- `:OdooLs init` - scaffold a starter `odools.toml` in the current working
--- directory with best-effort auto-detection.
local M = {}

local uv = vim.uv or vim.loop

local function notify(msg, level)
  vim.notify(msg, level, { title = 'odoo_ls' })
end

-- Resolve a `config_schema.json` next to `odools.toml` so taplo (the TOML
-- language server) can complete and validate every key. Precedence:
--   (a) a config_schema.json already sitting next to the target file
--   (b) the odoo-ls crate's `print_config_schema` binary, if on PATH
--   (c) the release asset for the installed data-dir tag, downloaded on the fly
--   (d) otherwise skip the schema line entirely
-- Returns the `#:schema` header string (possibly empty).
local function resolve_schema(dir)
  local schema_path = vim.fs.joinpath(dir, 'config_schema.json')

  -- (a) already present
  if uv.fs_stat(schema_path) then
    return '#:schema ./config_schema.json\n\n'
  end

  -- (b) local crate binary
  local schema_bin = vim.fn.exepath('print_config_schema')
  if schema_bin ~= '' then
    local ok, res = pcall(function()
      return vim.system({ schema_bin }, { cwd = dir }):wait(10000)
    end)
    if ok and res.code == 0 and uv.fs_stat(schema_path) then
      return '#:schema ./config_schema.json\n\n'
    end
  end

  -- (c) download the asset for the installed release tag (release installs have
  --     no local crate binary). Reuses github.lua when the installer is present.
  local ok_resolve, resolve = pcall(require, 'odoo_ls.resolve')
  local ok_github, github = pcall(require, 'odoo_ls.github')
  if ok_resolve and ok_github and type(github.download_asset_sync) == 'function' then
    local tag = resolve.installed_tag()
    if tag then
      local url = ('%s/%s/config_schema.json'):format(github.download_url, tag)
      if github.download_asset_sync(url, schema_path) and uv.fs_stat(schema_path) then
        return '#:schema ./config_schema.json\n\n'
      end
    end
  end

  -- (d) skip
  return ''
end

--- Scaffold a starter `odools.toml` in the current working directory.
--- Detection is best-effort: `odoo-bin` upward from cwd or one level down for
--- `odoo_path`, an `enterprise` checkout next to it for `addons_paths`, and the
--- active virtualenv (else `python3`) for `python_path`.
function M.init_config()
  local dir = vim.fn.getcwd()
  local path = vim.fs.joinpath(dir, 'odools.toml')
  if uv.fs_stat(path) then
    notify('odools.toml already exists here - opening it', vim.log.levels.INFO)
    vim.cmd.edit(vim.fn.fnameescape(path))
    return
  end

  local odoo_path
  local found = vim.fs.find('odoo-bin', { upward = true, path = dir })[1]
  if found then
    odoo_path = vim.fs.dirname(found)
  else
    for name, t in vim.fs.dir(dir) do
      if t == 'directory' and uv.fs_stat(vim.fs.joinpath(dir, name, 'odoo-bin')) then
        odoo_path = vim.fs.joinpath(dir, name)
        break
      end
    end
  end

  local python = 'python3'
  if vim.env.VIRTUAL_ENV then
    python = vim.fs.joinpath(vim.env.VIRTUAL_ENV, 'bin', 'python')
  elseif vim.fn.exepath('python3') ~= '' then
    python = vim.fn.exepath('python3')
  end

  local addons = {}
  if odoo_path then
    local enterprise = vim.fs.joinpath(vim.fs.dirname(odoo_path), 'enterprise')
    if uv.fs_stat(enterprise) then
      table.insert(addons, enterprise)
    end
  end

  local header = resolve_schema(dir)

  local quoted = vim.tbl_map(function(p)
    return ('"%s"'):format(p)
  end, addons)
  local content = header
    .. table.concat({
      '[[config]]',
      'name = "default"',
      ('odoo_path = "%s"'):format(odoo_path or '/path/to/odoo'),
      ('addons_paths = [%s]'):format(table.concat(quoted, ', ')),
      ('python_path = "%s"'):format(python),
      '',
      '# Common optional keys:',
      '# additional_stubs = ["/path/to/typeshed/stubs"]',
      '# stdlib = "/path/to/typeshed/stdlib"',
      '# tsserver_command = "tsserver"  # "" disables JS/OWL features',
      '# disable_javascript = false',
      '# auto_refresh_delay = 1000',
      '# diag_missing_imports = "all"',
    }, '\n')
    .. '\n'

  vim.fn.writefile(vim.split(content, '\n'), path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  notify(
    'created ' .. path .. (header ~= '' and ' (+ config_schema.json for taplo)' or ''),
    vim.log.levels.INFO
  )
end

return M
