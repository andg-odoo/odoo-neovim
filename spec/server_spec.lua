local uv = vim.uv

local server, root, fixtures, failing, downloads, notices

local function write_exe(path, body)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile({ '#!/bin/sh', body or 'true' }, path)
  vim.fn.setfperm(path, 'rwxr-xr-x')
end

local function build_fixtures(tags)
  local dir = vim.fn.tempname()
  local os_name, arch = server.platform()
  for _, tag in ipairs(tags) do
    local src = ('%s/src-%s'):format(dir, tag)
    write_exe(src .. '/odoo_ls_server', 'echo ' .. tag)
    local name = ('odoo-%s-%s-%s.tar.gz'):format(os_name, arch, tag)
    vim.system({ 'tar', '-czf', dir .. '/' .. name, '-C', src, 'odoo_ls_server' }):wait()
    fixtures[name] = dir .. '/' .. name
  end
  vim.fn.mkdir(dir .. '/typeshed/stdlib', 'p')
  vim.fn.writefile({}, dir .. '/typeshed/stdlib/builtins.pyi')
  vim.system({ 'zip', '-qr', dir .. '/typeshed.zip', 'stdlib' }, { cwd = dir .. '/typeshed' }):wait()
  fixtures['typeshed.zip'] = dir .. '/typeshed.zip'
end

local function install(release)
  local done, err = false, nil
  server.install(release, function(e)
    done, err = true, e
  end)
  assert.is_true(vim.wait(5000, function()
    return done
  end))
  return err
end

local function exists(path)
  return uv.fs_stat(path) ~= nil
end

describe('odoo_ls.server', function()
  local orig_notify, orig_path, orig_uname, orig_start = vim.notify, vim.env.PATH, uv.os_uname, vim.lsp.rpc.start

  before_each(function()
    package.loaded['odoo_ls.server'] = nil
    server = require('odoo_ls.server')
    root = vim.fn.tempname() .. '/odoo'
    server.root = root
    vim.env.PATH = '/usr/bin:/bin'
    fixtures, failing, downloads, notices = {}, {}, {}, {}
    server.download = function(url, dest, on_done)
      local name = vim.fs.basename(url)
      table.insert(downloads, name)
      vim.schedule(function()
        if failing[name] or not fixtures[name] then
          return on_done('curl: (22) The requested URL returned error: 404')
        end
        uv.fs_copyfile(fixtures[name], dest)
        on_done()
      end)
    end
    vim.notify = function(msg)
      table.insert(notices, msg)
    end
    build_fixtures({ '1.5.0', '1.6.0' })
  end)

  after_each(function()
    vim.notify, vim.env.PATH, uv.os_uname, vim.lsp.rpc.start = orig_notify, orig_path, orig_uname, orig_start
  end)

  it('installs a release into <tag>/ and makes it current', function()
    assert.is_nil(install('1.6.0'))
    assert.equal('1.6.0', server.tag())
    assert.is_true(exists(root .. '/1.6.0/typeshed/stdlib/builtins.pyi'))
    assert.is_false(exists(root .. '/1.6.0.tmp'))
    assert.same({ cmd = { root .. '/1.6.0/odoo_ls_server' }, source = 'managed', tag = '1.6.0' }, server.resolve())
    assert.equal('1.6.0\n', vim.system({ root .. '/1.6.0/odoo_ls_server' }):wait().stdout)
  end)

  it('leaves no trace and keeps current when the server download fails', function()
    install('1.5.0')
    failing[('odoo-%s-%s-1.6.0.tar.gz'):format(server.platform())] = true
    assert.matches('error: 404', install('1.6.0'))
    assert.equal('1.5.0', server.tag())
    assert.is_false(exists(root .. '/1.6.0'))
    assert.is_false(exists(root .. '/1.6.0.tmp'))
    assert.matches('install failed: curl', notices[#notices])
  end)

  it('leaves no trace and keeps current when the typeshed download fails', function()
    install('1.5.0')
    failing['typeshed.zip'] = true
    assert.matches('error: 404', install('1.6.0'))
    assert.equal('1.5.0', server.tag())
    assert.is_false(exists(root .. '/1.6.0'))
    assert.is_false(exists(root .. '/1.6.0.tmp'))
  end)

  it('switches current back on a downgrade and removes the other install', function()
    install('1.6.0')
    assert.is_nil(install('1.5.0'))
    assert.equal('1.5.0', server.tag())
    assert.equal(root .. '/1.5.0/odoo_ls_server', server.resolve().cmd[1])
    assert.is_false(exists(root .. '/1.6.0'))
  end)

  it('reuses a complete <tag>/ without downloading', function()
    install('1.6.0')
    install('1.5.0')
    downloads = {}
    assert.is_nil(install('1.5.0'))
    assert.same({}, downloads)
  end)

  it('resolves managed over legacy over PATH', function()
    assert.same({ cmd = { 'odoo_ls_server' }, source = 'none' }, server.resolve())
    local bin = vim.fn.tempname()
    write_exe(bin .. '/odoo_ls_server')
    vim.env.PATH = bin .. ':/usr/bin:/bin'
    assert.equal('path', server.resolve().source)
    write_exe(root .. '/odoo_ls_server')
    assert.same({ cmd = { root .. '/odoo_ls_server' }, source = 'legacy' }, server.resolve())
    install('1.6.0')
    assert.equal('managed', server.resolve().source)
  end)

  it('removes legacy symlinks on install but keeps hand-placed files', function()
    write_exe(root .. '/odoo_ls_server')
    vim.fn.mkdir(root .. '/old/typeshed', 'p')
    uv.fs_symlink(root .. '/old/typeshed', root .. '/typeshed')
    uv.fs_symlink(root .. '/old/typeshed', root .. '/stdlib')
    install('1.6.0')
    assert.is_true(exists(root .. '/odoo_ls_server'))
    assert.is_nil(uv.fs_lstat(root .. '/typeshed'))
    assert.is_nil(uv.fs_lstat(root .. '/stdlib'))
  end)

  it('aborts on an unsupported platform before any download', function()
    uv.os_uname = function()
      return { sysname = 'Plan9', machine = 'mips' }
    end
    assert.equal('unsupported platform: Plan9 mips', install('1.6.0'))
    assert.same({}, downloads)
    assert.is_false(exists(root))
  end)

  it('notices a legacy server once per session', function()
    write_exe(root .. '/odoo_ls_server')
    local started = {}
    vim.lsp.rpc.start = function(cmd)
      table.insert(started, cmd[1])
    end
    server.start({})
    server.start({})
    assert.same({ root .. '/odoo_ls_server', root .. '/odoo_ls_server' }, started)
    assert.same({ 'found a legacy odoo_ls_server, run :OdooLs install to switch to managed installs\n' .. root .. '/odoo_ls_server' }, notices)
  end)

  it('notices a missing server and starts a fresh install without a reload', function()
    vim.lsp.rpc.start = function() end
    server.start({})
    server.start({})
    assert.same({ 'no odoo_ls_server found, run :OdooLs install' }, notices)
    install('1.6.0')
    local started
    vim.lsp.rpc.start = function(cmd)
      started = cmd[1]
    end
    server.start({})
    assert.equal(root .. '/1.6.0/odoo_ls_server', started)
  end)

  it('reports a user cmd as the effective one', function()
    vim.lsp.config('odoo_ls', { cmd = { '/bin/sh' } })
    assert.same({ cmd = { '/bin/sh' }, source = 'user' }, server.effective())
  end)
end)
