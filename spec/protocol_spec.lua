local protocol = require('odoo_ls.protocol')
local handlers = protocol.handlers

local function leaf(value, ...)
  return { value = value, sources = { ... }, info = '' }
end

-- Shaped like the server's `ConfigView` serialization: profiles arrive resolved, keys as leaves.
local payload = {
  html = { __all__ = '<div></div>' },
  configFile = {
    config = {
      {
        name = 'base',
        extends = '',
        abstract = true,
        odoo_path = leaf('/w/odoo', '/w/odools.toml'),
      },
      {
        name = 'src',
        extends = 'base',
        abstract = false,
        odoo_path = leaf('/w/odoo', '/w/odools.toml'),
        addons_paths = {
          leaf('/w/enterprise', '/w/src/odools.toml'),
          leaf('/w/odoo/addons', '$workspaceFolder:odoo', '/w/src/odools.toml'),
        },
        tsserver_command = leaf('tsserver', '$default'),
        file_cache = leaf(false, '/w/src/odools.toml'),
        diagnostic_settings = { OLS01000 = leaf('error', '/w/src/odools.toml') },
      },
      {
        name = 'other',
        extends = '',
        abstract = false,
        odoo_path = leaf('/x/odoo', '/x/odools.toml'),
      },
    },
  },
  diagnostics = {
    { level = 2, message = "Config profile 'other': odoo_path rejected", profile = 'other' },
    { level = 1, message = "Config profile 'src': unknown key", profile = 'src' },
  },
}

describe('protocol', function()
  local get_client_by_id = vim.lsp.get_client_by_id
  local notify = vim.notify

  before_each(function()
    vim.notify = function() end
    vim.lsp.get_client_by_id = function(id)
      assert.equal(7, id)
      return { config = { settings = { Odoo = { selectedProfile = 'src' } } } }
    end
    vim.lsp.config('odoo_ls', { settings = { Odoo = { selectedProfile = 'src' } } })
    handlers['$Odoo/setConfiguration'](nil, payload, { client_id = 7 })
    handlers['$Odoo/diagnostic_config'](nil, {
      action = 'replace',
      messages = { { level = 1, message = 'tsserver slow' }, { level = 0, message = 'indexing' } },
    })
    handlers['$Odoo/jsLsStatus'](nil, true)
  end)

  after_each(function()
    vim.lsp.get_client_by_id = get_client_by_id
    vim.notify = notify
  end)

  it('normalises the active profile into plain values and sources', function()
    local st = protocol.state
    assert.same({ 'src', 'other' }, st.profiles)
    assert.same({
      odoo_path = '/w/odoo',
      addons_paths = { '/w/enterprise', '/w/odoo/addons' },
      tsserver_command = 'tsserver',
      file_cache = false,
      diagnostic_settings = { OLS01000 = 'error' },
    }, st.config)
    assert.same({ '$workspaceFolder:odoo', '/w/src/odools.toml' }, st.sources.addons_paths)
    assert.same({ '$default' }, st.sources.tsserver_command)
    assert.same({ '/w/odools.toml', '/w/src/odools.toml', '/x/odools.toml' }, st.config_files)
    assert.is_true(st.js)
  end)

  it('forgets the previous server crash and diagnostics when a new server starts', function()
    handlers['Odoo/displayCrashNotification'](nil, { crashInfo = 'panicked' })
    handlers['$Odoo/diagnostic_config'](nil, { action = 'extend', messages = { { level = 2, message = 'late' } } })
    handlers['$Odoo/setPid'](nil, { server_pid = 42 })
    local st = protocol.state
    assert.same({ 42, false }, { st.pid, st.crashed })
    assert.same({}, st.config_diagnostics)
    assert.same({}, st.server_diagnostics)
  end)

  describe('health', function()
    local health = vim.health

    -- Runs the check and returns the calls made after the profile section starts.
    local function profile_section()
      local calls = {}
      vim.health = setmetatable({}, {
        __index = function(_, kind)
          return function(msg)
            table.insert(calls, { kind, msg })
          end
        end,
      })
      require('odoo_ls.health').check()
      for i, call in ipairs(calls) do
        if call[1] == 'start' and call[2] == 'odoo_ls: profile src' then
          return vim.list_slice(calls, i + 1)
        end
      end
    end

    after_each(function()
      vim.health = health
      protocol.state.crashed = false
    end)

    it('lists the file-set keys, counts the defaults and reports every diagnostic', function()
      assert.same({
        { 'info', 'addons_paths = /w/enterprise, /w/odoo/addons  ($workspaceFolder:odoo, /w/src/odools.toml)' },
        { 'info', 'diagnostic_settings = { OLS01000 = "error" }  (/w/src/odools.toml)' },
        { 'info', 'file_cache = false  (/w/src/odools.toml)' },
        { 'info', 'odoo_path = /w/odoo  (/w/odools.toml)' },
        { 'info', '1 other keys at their built-in defaults' },
        { 'info', 'other profiles: other' },
        { 'error', "config [other]: Config profile 'other': odoo_path rejected" },
        { 'warn', "config [src]: Config profile 'src': unknown key" },
        { 'warn', 'server: tsserver slow' },
        { 'info', 'server: indexing' },
      }, profile_section())
    end)

    it('cuts a crash to its first 20 lines', function()
      local lines = {}
      for i = 1, 30 do
        table.insert(lines, 'frame ' .. i)
      end
      handlers['Odoo/displayCrashNotification'](nil, { crashInfo = table.concat(lines, '\n') })
      local crash = profile_section()[11]
      assert.same({ 'error', table.concat(vim.list_slice(lines, 1, 20), '\n') }, crash)
    end)
  end)
end)

describe('setConfiguration notices', function()
  local get_client_by_id, notify = vim.lsp.get_client_by_id, vim.notify
  local tmp, notices, active, set_configuration

  local function snapshot(...)
    local config = {}
    for _, name in ipairs({ ... }) do
      table.insert(config, { name = name, abstract = false })
    end
    set_configuration(nil, { configFile = { config = config } }, { client_id = 1 })
  end

  before_each(function()
    package.loaded['odoo_ls.protocol'] = nil
    set_configuration = require('odoo_ls.protocol').handlers['$Odoo/setConfiguration']
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    notices, active = {}, 'default'
    vim.notify = function(msg)
      table.insert(notices, msg)
    end
    vim.lsp.get_client_by_id = function()
      return { root_dir = tmp, config = { settings = { Odoo = { selectedProfile = active } } } }
    end
  end)

  after_each(function()
    vim.lsp.get_client_by_id, vim.notify = get_client_by_id, notify
    vim.fn.delete(tmp, 'rf')
  end)

  it('tells a former main user once that default is now selected', function()
    snapshot('default', 'main')
    snapshot('default', 'main')
    assert.equal(1, #notices)
    assert.truthy(notices[1]:find("setup({ profile = 'main' })", 1, true))
  end)

  it('stays quiet when main is selected or does not exist', function()
    active = 'main'
    snapshot('default', 'main')
    active = 'default'
    snapshot('default', 'src')
    assert.same({}, notices)
  end)

  it('warns once about an odools.toml with top-level keys', function()
    vim.fn.writefile({ '# old snippet', 'name = "main"', 'odoo_path = "odoo"' }, tmp .. '/odools.toml')
    snapshot('default')
    snapshot('default')
    assert.same({ 'odools.toml has no [[config]] table, so the server ignores it\nwrap its keys in [[config]]: ' .. vim.fn.fnamemodify(tmp .. '/odools.toml', ':~') }, notices)
  end)

  it('accepts an odools.toml with a [[config]] table', function()
    vim.fn.writefile({ '#:schema x', '', '[[config]]', 'name = "default"' }, tmp .. '/odools.toml')
    snapshot('default')
    assert.same({}, notices)
  end)

  it('accepts an empty or comment-only odools.toml', function()
    vim.fn.writefile({}, tmp .. '/odools.toml')
    snapshot('default')
    vim.fn.writefile({ '# name = "main"', '   ' }, tmp .. '/odools.toml')
    snapshot('default')
    assert.same({}, notices)
  end)
end)
