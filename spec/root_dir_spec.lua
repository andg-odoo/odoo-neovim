local spec = dofile('lsp/odoo_ls.lua')

local function root_for(path)
  local bufnr = vim.fn.bufadd(path)
  local root
  spec.root_dir(bufnr, function(dir)
    root = dir
  end)
  return root
end

describe('root_dir', function()
  local tmp = vim.fn.tempname()

  before_each(function()
    vim.fn.mkdir(tmp .. '/project/addons/sale', 'p')
    vim.fn.mkdir(tmp .. '/elsewhere', 'p')
    vim.fn.writefile({}, tmp .. '/project/odools.toml')
  end)

  after_each(function()
    vim.fn.delete(tmp, 'rf')
  end)

  it('attaches at the nearest odools.toml', function()
    assert.equals(tmp .. '/project', root_for(tmp .. '/project/addons/sale/models.py'))
  end)

  it('does not attach without an odools.toml above the file', function()
    assert.is_nil(root_for(tmp .. '/elsewhere/script.py'))
  end)
end)
