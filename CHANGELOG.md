# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow the
odoo-ls server: each server release gets a plugin release with the same number,
even when the client is unchanged.

## [1.6.1] - Unreleased

First versioned release, turning the configuration snippet into a full client.

### Breaking

- The default selected profile is `default` (was `main`). The server always has
  a built-in `default` profile. To keep `main`, pass `profile = 'main'` to
  `setup()`, set `settings.Odoo.selectedProfile`, or rename the profile.
- The client attaches only to files under an `odools.toml`, and that file's
  directory is the workspace folder. It used to attach to any buffer with the
  current working directory as the workspace folder.
- Filetypes are now `python`, `xml`, `csv`, `javascript` and `typescript` (was
  `python` and `xml`).
- `odools.toml` must hold its keys in `[[config]]` tables. The top-level keys of
  the old README example were never read by the server.

### Added

- `:OdooLs` command: `health` (the default), `profile`, `restart`, `logs` and
  `install` subcommands.
- `require('odoo_ls')` with `setup()`, `restart()`, `set_profile()` and
  `install()`.
- Managed server installs: downloads the server release matching the plugin
  version and its typeshed into `stdpath('data')/odoo/<tag>/`. `setup()`
  installs it when the server is missing or the managed install is another
  release, so updating the plugin updates the server.
- Handling of the server's `$Odoo/*` notifications: configuration snapshot,
  diagnostics, loading status, crashes.
- `:checkhealth odoo_ls`, with the active profile's file-set keys and every
  config and server diagnostic.
- One-time notices for a `main` profile left unselected and for an
  `odools.toml` without a `[[config]]` table.

### Changed

- The server binary is resolved on each start: the managed install, then the
  legacy `stdpath('data')/odoo/odoo_ls_server`, then `PATH`.
- Only `utf-16` is advertised as position encoding, so the client can share
  buffers with lemminx.
