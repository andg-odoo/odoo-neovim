-- Mason package spec: the server release this plugin is built for, with its typeshed next to the binary
local asset = {}
for target, platform in pairs({
  linux_x64_gnu = 'linux-x86_64',
  linux_arm64_gnu = 'linux-aarch64',
  linux_x64_musl = 'alpine-x86_64',
  linux_arm64_musl = 'alpine-aarch64',
  darwin_x64 = 'darwin-x86_64',
  darwin_arm64 = 'darwin-aarch64',
  win_x64 = 'win32-x86_64',
  win_arm64 = 'win32-aarch64',
}) do
  local win = target:match('^win') ~= nil
  table.insert(asset, {
    target = target,
    file = { ('odoo-%s-{{version}}.%s'):format(platform, win and 'zip' or 'tar.gz'), 'typeshed.zip:typeshed/' },
    bin = win and 'odoo_ls_server.exe' or 'odoo_ls_server',
  })
end

return {
  schema = 'registry+v1',
  name = 'odoo-ls',
  description = 'Language server for Odoo: Python, XML, CSV and JS files of Odoo modules.',
  homepage = 'https://github.com/odoo/odoo-ls',
  licenses = { 'LGPL-3.0-only' },
  languages = { 'Python', 'XML' },
  categories = { 'LSP' },
  source = { id = 'pkg:github/odoo/odoo-ls@' .. require('odoo_ls.server').VERSION, asset = asset },
  bin = { odoo_ls_server = '{{source.asset.bin}}' },
}
