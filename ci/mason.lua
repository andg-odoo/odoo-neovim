-- CI check: install odoo-ls through the plugin's mason registry, start it, hover a stdlib call
vim.cmd('filetype on')
local ws = vim.fs.normalize(vim.env.WS)
vim.opt.rtp:prepend(vim.fs.normalize(vim.env.MASON_NVIM))
vim.opt.rtp:prepend(vim.fn.getcwd())
local function out(...)
  io.stdout:write(table.concat(vim.tbl_map(tostring, { ... }), ' ') .. '\n')
end
local function fail(msg)
  out('FAIL', msg)
  vim.cmd('cquit 1')
end

require('mason').setup({ registries = { 'lua:odoo_ls.mason' } })
local reg = require('mason-registry')
local done = false
reg.refresh(function() done = true end)
vim.wait(30000, function() return done end)
local pkg = reg.get_package('odoo-ls')
done = false
local ok_install, install_err
pkg:install({}, function(success, err) ok_install, install_err, done = success, err, true end)
vim.wait(600000, function() return done end, 500)
if not ok_install then
  return fail('mason install: ' .. vim.inspect(install_err))
end
local pkg_dir = vim.fs.joinpath(vim.env.MASON, 'packages', 'odoo-ls')
for name, kind in vim.fs.dir(pkg_dir) do
  out('pkg', name, kind)
end
out('installed', pkg:get_installed_version())

vim.notify = function(m) out('notify', m) end
require('odoo_ls').setup()
local r = require('odoo_ls.server').resolve()
out('resolve', r.source, r.cmd[1])
if r.source ~= 'mason' then
  return fail('expected the mason source')
end

vim.cmd.edit(ws .. '/my_mod/models/partner.py')
if not vim.wait(30000, function() return #vim.lsp.get_clients({ name = 'odoo_ls', bufnr = 0 }) > 0 end, 200) then
  return fail('client did not attach, filetype=' .. vim.bo.filetype)
end
local state = require('odoo_ls.protocol').state
vim.wait(600000, function() return state.loading == 'stop' end, 1000)
out('loading', state.loading)

local client = vim.lsp.get_clients({ name = 'odoo_ls' })[1]
local params = vim.lsp.util.make_position_params(0, 'utf-16')
params.position = { line = 9, character = 20 }
local res = client:request_sync('textDocument/hover', params, 60000)
local hover = res and res.result and res.result.contents and (res.result.contents.value or vim.inspect(res.result.contents)) or 'nil'
out('hover os.getcwd', (hover:gsub('\n', ' | ')))

vim.cmd('checkhealth odoo_ls')
for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
  if l:match('%S') then
    out('H', l)
  end
end
if not hover:find('-> str', 1, true) then
  return fail('os.getcwd() did not resolve through the bundled typeshed')
end
out('PASS')
vim.cmd('qall!')
