# syncide

Tiny, zero-dependency CLI utility written in **Zig** to share `settings.json`, `keybindings.json`, and `extensions/` across all Visual Studio Code–based IDEs (VS Code, Cursor, Windsurf, Trae, VSCodium, Antigravity, Positron, Void, Kiro, and custom forks) without duplicating disk space.

## Features

- **Automatic IDE Discovery**: Detects installed VS Code forks across Windows (`%APPDATA%` / `%USERPROFILE%`), Linux (`$XDG_CONFIG_HOME` / `~/.config` / `$HOME`), and macOS (`~/Library/Application Support`), ignoring backup/non-VSCode directories.
- **Safe `.zip` Backups First**: Compresses existing `User` configs and `extensions/` into `.zip` archives directly inside each IDE's folder before linking.
- **Zero Disk Duplication & Live Sync**:
  - Links `settings.json` and `keybindings.json` via symbolic links (with Windows hardlink fallback) so changes in one IDE immediately apply to all others.
  - Links `extensions/` via native Win32 NTFS Junctions (`FSCTL_SET_REPARSE_POINT`, no admin required) on Windows and directory symlinks on Linux/macOS, using atomic rename-swaps so open language servers never corrupt folders.
- **Manifest Reconciliation**: Normalizes `extensions/extensions.json`, deduplicates versions, and cleans `.obsolete` entries.
- **Tiny Footprint**: ~640 KB on Windows, ~300 KB static `musl` binary on Linux.

## Usage

```sh
# Scan detected IDEs and check link status
syncide status

# Interactive setup: pick IDEs to sync (default: all), choose primary IDE, backup (.zip) & link
syncide init

# Verify/repair links, reconcile unlinked edits & rebuild extensions.json
syncide sync
syncide sync --include-new

# Manage shared extensions
syncide extension list
syncide extension install esbenp.prettier-vscode
syncide extension uninstall esbenp.prettier-vscode

# Safely detach an IDE back into standalone copies
syncide unlink cursor
syncide unlink all
```

> **Note**: Close running IDEs before initial `syncide init` so language server binaries inside `extensions/` are not locked by active processes.

## Building from Source

Requires **Zig `0.17.1`+**:

```sh
zig build              # Outputs stripped small binary into ./build/
zig build test         # Runs unit & isolated sandbox integration tests
```

## License

Licensed under the [GNU General Public License v3.0](LICENSE).
