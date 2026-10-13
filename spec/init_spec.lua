describe('odoo_ls', function()
  it('exposes only setup, restart, set_profile and install', function()
    local odoo_ls = require('odoo_ls')
    local keys = vim.tbl_keys(odoo_ls)
    table.sort(keys)
    assert.same({ 'install', 'restart', 'set_profile', 'setup' }, keys)
    for _, key in ipairs(keys) do
      assert.equal('function', type(odoo_ls[key]))
    end
  end)

  describe('setup', function()
    local server = require('odoo_ls.server')
    local orig_effective, orig_install, orig_enable = server.effective, server.install, vim.lsp.enable
    local installed, enabled

    before_each(function()
      installed, enabled = {}, 0
      server.install = function(tag, on_done)
        table.insert(installed, tag)
        on_done('offline')
      end
      vim.lsp.enable = function()
        enabled = enabled + 1
      end
    end)

    after_each(function()
      server.effective, server.install, vim.lsp.enable = orig_effective, orig_install, orig_enable
    end)

    local function setup_with(resolution)
      server.effective = function()
        return resolution
      end
      require('odoo_ls').setup()
    end

    it('keeps a managed install that matches the plugin version', function()
      setup_with({ source = 'managed', tag = server.VERSION, cmd = {} })
      assert.same({}, installed)
      assert.equal(1, enabled)
    end)

    it('replaces an outdated managed install and still starts it when that fails', function()
      setup_with({ source = 'managed', tag = '1.0.0', cmd = {} })
      assert.same({ server.VERSION }, installed)
      assert.equal(1, enabled)
    end)

    it('installs when no server resolves and leaves the client off when that fails', function()
      setup_with({ source = 'none', cmd = {} })
      assert.same({ server.VERSION }, installed)
      assert.equal(0, enabled)
    end)

    it('never replaces a server it does not manage', function()
      setup_with({ source = 'path', cmd = {} })
      assert.same({}, installed)
      assert.equal(1, enabled)
    end)
  end)
end)
