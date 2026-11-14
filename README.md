# syncide

Tiny, zero-dependency CLI utility written in **Zig** to share `settings.json`, `keybindings.json`, and `extensions/` across all Visual Studio Code–based IDEs (VS Code, Cursor, Windsurf, Trae, VSCodium, Antigravity, Positron, Void, Kiro, and custom forks) without duplicating disk space.

## Installation

**Windows (PowerShell):**

```powershell
irm https://raw.githubusercontent.com/an1by/syncide/main/install.ps1 | iex
```

**Linux & macOS:**

```sh
curl -fsSL https://raw.githubusercontent.com/an1by/syncide/main/install.sh | sh
```

### Uninstall

Interactive uninstall lets you choose how linked IDEs are restored before removing the store, `PATH` entry, and `syncide` binary:
1. **Rollback from backups (default)** — unpacks each IDE's `.zip` backups if available (falls back to copying shared config if backups were cleaned).
2. **Duplicate shared config** — keeps the current unified settings, keybindings & extensions duplicated across all IDEs.

```sh
syncide uninstall                  # Interactive choice (1: rollback / 2: duplicate) + confirmation
syncide uninstall -f               # Force uninstall with default mode 1 (rollback from .zip backups)
syncide uninstall -f --duplicate   # Force uninstall with mode 2 (duplicate shared config everywhere)
```

Or via standalone one-liners:

**Windows (PowerShell):**

```powershell
irm https://raw.githubusercontent.com/an1by/syncide/main/uninstall.ps1 | iex
```

**Linux & macOS:**

```sh
curl -fsSL https://raw.githubusercontent.com/an1by/syncide/main/uninstall.sh | sh
```

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

# Create compressed .zip backups and print created archive paths
syncide backups create
syncide backups create cursor

# List existing .zip backup archives and sizes
syncide backups list

# Remove .zip backup archives (asks [y/N] confirmation unless -f/--force)
syncide backups clean
syncide backups clean -f
syncide backups clean -f cursor

# Self-update syncide binary from GitHub Releases (verifies SHA-256)
syncide update
syncide update --check

# Uninstall syncide (prompts mode 1: rollback .zip backups / mode 2: duplicate shared config)
syncide uninstall
syncide uninstall -f

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
