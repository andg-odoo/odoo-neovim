local M = {}

M.base_url = "https://api.github.com/repos/odoo/odoo-ls/releases"
M.download_url = "https://github.com/odoo/odoo-ls/releases/download"

function M.get_latest_release(callback)
    vim.system({ 'curl', '-sL', M.base_url .. '?per_page=100' }, { text = true }, function(out)
        vim.schedule(function()
            if out.code ~= 0 or not out.stdout then
                callback(nil, "Curl request failed")
                return
            end
            local ok, parsed = pcall(vim.fn.json_decode, out.stdout)
            if not ok or not parsed then
                callback(nil, "Failed to parse JSON")
                return
            end
            for _, r in ipairs(parsed) do
                callback(r.tag_name)
                return
            end
            callback(nil, "No releases found")
        end)
    end)
end

function M.get_stable_release(callback)
    vim.system({ 'curl', '-sL', M.base_url .. '/latest' }, { text = true }, function(out)
        vim.schedule(function()
            if out.code ~= 0 or not out.stdout then
                callback(nil, "Curl request failed")
                return
            end

            local ok, parsed = pcall(vim.fn.json_decode, out.stdout)
            if ok and parsed and parsed.tag_name then
                callback(parsed.tag_name)
            else
                callback(nil, "Failed to parse JSON")
            end
        end)
    end)
end

function M.download_asset(url, output, callback)
    vim.system({ 'curl', '-sL', '-o', output, url }, {}, function(out)
        vim.schedule(function()
            callback(out.code == 0)
        end)
    end)
end

-- Blocking variant used when a caller needs the file on disk before continuing
-- (e.g. fetching config_schema.json while scaffolding an odools.toml).
function M.download_asset_sync(url, output)
    local ok, res = pcall(function()
        return vim.system({ 'curl', '-sfL', '-o', output, url }, {}):wait(15000)
    end)
    return ok and res.code == 0
end

return M
