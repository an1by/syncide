const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const paths = @import("paths.zig");
const discovery = @import("discovery.zig");
const archive = @import("archive.zig");
const linker = @import("linker.zig");
const state_mod = @import("state.zig");
const updater = @import("updater.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;

pub const RestoreMode = enum {
    rollback_backups,
    duplicate_shared,
};

pub const IdeRestoreOutcome = struct {
    ide_id: []const u8,
    ide_name: []const u8,
    user_from_backup: bool,
    ext_from_backup: bool,
};

pub const UninstallPlanInfo = struct {
    has_state: bool,
    store_dir: ?[]const u8,
    linked_ides: []types.IdeInstallation,
    ide_backup_count: usize,
};

pub const UninstallStoreSummary = struct {
    outcomes: []IdeRestoreOutcome,
    removed_store_dirs: [][]const u8,
    warnings: [][]const u8,
};

fn isLinkManagedOrActive(
    arena: Allocator,
    io: Io,
    ide: types.IdeInstallation,
    st: types.SyncState,
    sp: types.StorePaths,
) bool {
    for (st.managedIdeIds) |mid| {
        if (std.mem.eql(u8, mid, ide.id)) {
            return true;
        }
    }
    const rep = linker.inspectIdeLinks(arena, io, ide, sp);
    const set_linked = rep.settings_state == .linked or
        rep.settings_state == .hardlinked or
        rep.settings_state == .broken;
    const key_linked = rep.keybindings_state == .linked or
        rep.keybindings_state == .hardlinked or
        rep.keybindings_state == .broken;
    const ext_linked = rep.extensions_state == .linked or rep.extensions_state == .broken;
    return set_linked or key_linked or ext_linked;
}

pub fn inspectUninstallPlan(
    arena: Allocator,
    io: Io,
    p: types.PlatformPaths,
    explicit_store_dir: ?[]const u8,
) !UninstallPlanInfo {
    const st_opt = try state_mod.loadState(arena, io, p, explicit_store_dir);
    if (st_opt == null) {
        return .{
            .has_state = false,
            .store_dir = null,
            .linked_ides = &.{},
            .ide_backup_count = 0,
        };
    }

    const st = st_opt.?;
    const sp = try paths.getStorePaths(arena, st.storeDir);
    const discovered = try discovery.discoverIdes(arena, io, p);

    var linked: std.ArrayList(types.IdeInstallation) = .empty;
    for (discovered) |ide| {
        if (isLinkManagedOrActive(arena, io, ide, st, sp)) {
            try linked.append(arena, ide);
        }
    }

    const backups = try archive.findIdeBackups(arena, io, linked.items);
    return .{
        .has_state = true,
        .store_dir = st.storeDir,
        .linked_ides = try linked.toOwnedSlice(arena),
        .ide_backup_count = backups.len,
    };
}

fn restoreIdeRollbackWithFallback(
    arena: Allocator,
    io: Io,
    ide: types.IdeInstallation,
    store: types.StorePaths,
) !IdeRestoreOutcome {
    const rep = linker.inspectIdeLinks(arena, io, ide, store);

    const set_was_linked = rep.settings_state == .linked or
        rep.settings_state == .hardlinked or
        rep.settings_state == .broken;
    const key_was_linked = rep.keybindings_state == .linked or
        rep.keybindings_state == .hardlinked or
        rep.keybindings_state == .broken;
    const ext_was_linked = rep.extensions_state == .linked or rep.extensions_state == .broken;

    // Step 1: Detach active links first so zip extraction never writes through symlinks into store
    if (set_was_linked) {
        linker.removeLinkOnly(io, ide.settings_path);
    }
    if (key_was_linked) {
        linker.removeLinkOnly(io, ide.keybindings_path);
    }
    if (ext_was_linked) {
        linker.removeLinkOnly(io, ide.extensions_dir);
    }

    var user_from_backup = false;
    if (try archive.findLatestCategoryBackupAlloc(arena, io, ide.app_dir, "user")) |u_zip| {
        if (archive.extractZipOverwrite(io, u_zip, ide.app_dir)) |_| {
            user_from_backup = true;
        } else |_| {}
    }

    if (!user_from_backup) {
        if (set_was_linked) {
            if (Dir.accessAbsolute(io, store.settings_path, .{})) |_| {
                try linker.copyFileAbsolute(io, store.settings_path, ide.settings_path);
            } else |_| {}
        }
        if (key_was_linked) {
            if (Dir.accessAbsolute(io, store.keybindings_path, .{})) |_| {
                try linker.copyFileAbsolute(io, store.keybindings_path, ide.keybindings_path);
            } else |_| {}
        }
    }

    var ext_from_backup = false;
    if (rep.extensions_state != .unlinked_real) {
        if (try archive.findLatestCategoryBackupAlloc(arena, io, ide.dot_dir, "extensions")) |e_zip| {
            if (archive.extractZipOverwrite(io, e_zip, ide.dot_dir)) |_| {
                ext_from_backup = true;
            } else |_| {}
        }
    }

    if (!ext_from_backup and ext_was_linked) {
        if (Dir.accessAbsolute(io, store.extensions_dir, .{})) |_| {
            try linker.copyTreeAbsolute(arena, io, store.extensions_dir, ide.extensions_dir);
        } else |_| {}
    }

    return .{
        .ide_id = ide.id,
        .ide_name = ide.name,
        .user_from_backup = user_from_backup,
        .ext_from_backup = ext_from_backup,
    };
}

pub fn restoreIdesAndRemoveStore(
    arena: Allocator,
    io: Io,
    p: types.PlatformPaths,
    explicit_store_dir: ?[]const u8,
    mode: RestoreMode,
) !UninstallStoreSummary {
    var outcomes: std.ArrayList(IdeRestoreOutcome) = .empty;
    var removed_dirs: std.ArrayList([]const u8) = .empty;
    var warnings: std.ArrayList([]const u8) = .empty;

    const st_opt = try state_mod.loadState(arena, io, p, explicit_store_dir);
    if (st_opt) |st| {
        const sp = try paths.getStorePaths(arena, st.storeDir);
        const discovered = try discovery.discoverIdes(arena, io, p);

        for (discovered) |ide| {
            if (!isLinkManagedOrActive(arena, io, ide, st, sp)) {
                continue;
            }

            switch (mode) {
                .rollback_backups => {
                    const out = try restoreIdeRollbackWithFallback(arena, io, ide, sp);
                    try outcomes.append(arena, out);
                },
                .duplicate_shared => {
                    try linker.unlinkIde(arena, io, ide, sp);
                    try outcomes.append(arena, .{
                        .ide_id = ide.id,
                        .ide_name = ide.name,
                        .user_from_backup = false,
                        .ext_from_backup = false,
                    });
                },
            }
        }

        if (Dir.accessAbsolute(io, st.storeDir, .{})) |_| {
            if (Dir.cwd().deleteTree(io, st.storeDir)) |_| {
                try removed_dirs.append(arena, st.storeDir);
            } else |err| {
                const msg = try std.fmt.allocPrint(
                    arena,
                    "Could not fully delete store directory '{s}' ({s}) — close running IDEs and remove manually if needed.",
                    .{ st.storeDir, @errorName(err) },
                );
                try warnings.append(arena, msg);
            }
        } else |_| {}
    }

    if (Dir.accessAbsolute(io, p.default_store_dir, .{})) |_| {
        var already_listed = false;
        for (removed_dirs.items) |rd| {
            if (paths.pathsEqual(rd, p.default_store_dir)) {
                already_listed = true;
                break;
            }
        }
        if (Dir.cwd().deleteTree(io, p.default_store_dir)) |_| {
            if (!already_listed) {
                try removed_dirs.append(arena, p.default_store_dir);
            }
        } else |err| {
            const msg = try std.fmt.allocPrint(
                arena,
                "Could not delete config directory '{s}' ({s}).",
                .{ p.default_store_dir, @errorName(err) },
            );
            try warnings.append(arena, msg);
        }
    } else |_| {}

    return .{
        .outcomes = try outcomes.toOwnedSlice(arena),
        .removed_store_dirs = try removed_dirs.toOwnedSlice(arena),
        .warnings = try warnings.toOwnedSlice(arena),
    };
}

fn dirHasUnrelatedFiles(io: Io, dir_path: []const u8) bool {
    var dir = Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return false;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (!std.ascii.startsWithIgnoreCase(entry.name, "syncide")) {
            return true;
        }
    }
    return false;
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) {
        return false;
    }
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
            return true;
        }
    }
    return false;
}

fn stripSyncideRcSnippet(arena: Allocator, io: Io, rc_path: []const u8) bool {
    const raw = Dir.cwd().readFileAlloc(io, rc_path, arena, .limited(2 * 1024 * 1024)) catch return false;
    if (std.mem.indexOf(u8, raw, "# syncide") == null) {
        return false;
    }

    var out: std.ArrayList(u8) = .empty;
    var skip_next = false;
    var modified = false;

    var it = std.mem.splitScalar(u8, raw, '\n');
    var first = true;
    while (it.next()) |line_raw| {
        const trimmed = std.mem.trim(u8, line_raw, " \t\r");
        if (std.mem.eql(u8, trimmed, "# syncide")) {
            skip_next = true;
            modified = true;
            continue;
        }
        if (skip_next) {
            skip_next = false;
            continue;
        }
        if (!first) {
            out.append(arena, '\n') catch return false;
        }
        first = false;
        out.appendSlice(arena, line_raw) catch return false;
    }

    if (!modified) {
        return false;
    }

    Dir.cwd().writeFile(io, .{ .sub_path = rc_path, .data = out.items }) catch return false;
    return true;
}

pub fn cleanSystemPath(
    arena: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    p: types.PlatformPaths,
    exe_path: []const u8,
) bool {
    const exe_dir = Dir.path.dirname(exe_path) orelse return false;
    const is_dedicated = containsAsciiIgnoreCase(exe_dir, "syncide") or !dirHasUnrelatedFiles(io, exe_dir);
    if (!is_dedicated) {
        return false;
    }

    if (builtin.os.tag == .windows) {
        const sys_root = environ_map.get("SystemRoot") orelse "C:\\Windows";
        const ps_exe = Dir.path.join(arena, &.{
            sys_root,
            "System32",
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe",
        }) catch return false;

        var child_env = std.process.Environ.Map.init(arena);
        for (environ_map.keys(), environ_map.values()) |k, v| {
            child_env.put(k, v) catch return false;
        }
        child_env.put("SYNCIDE_CLEAN_DIR", exe_dir) catch return false;

        const ps_script =
            "$target = ([string]$env:SYNCIDE_CLEAN_DIR).TrimEnd('\\'); " ++
            "$up = [Environment]::GetEnvironmentVariable('Path', 'User'); " ++
            "if ($up) { " ++
            "$flt = @($up -split ';' | Where-Object { $_ -and (-not $_.TrimEnd('\\').Equals($target, [StringComparison]::OrdinalIgnoreCase)) }); " ++
            "$next = $flt -join ';'; " ++
            "if ($next -ne $up) { [Environment]::SetEnvironmentVariable('Path', $next, 'User') } " ++
            "}";

        var child = std.process.spawn(io, .{
            .argv = &.{ ps_exe, "-NoProfile", "-NonInteractive", "-Command", ps_script },
            .environ_map = &child_env,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .create_no_window = true,
        }) catch return false;

        const term = child.wait(io) catch return false;
        return term.success();
    }

    var any_cleaned = false;
    const rc_names = [_][]const u8{ ".bashrc", ".zshrc", ".profile" };
    for (rc_names) |rc_name| {
        if (Dir.path.join(arena, &.{ p.home_dir, rc_name })) |rc_path| {
            if (stripSyncideRcSnippet(arena, io, rc_path)) {
                any_cleaned = true;
            }
        } else |_| {}
    }

    if (Dir.path.join(arena, &.{ p.home_dir, ".config", "fish", "conf.d", "syncide.fish" })) |fish_path| {
        if (Dir.deleteFileAbsolute(io, fish_path)) |_| {
            any_cleaned = true;
        } else |_| {}
    } else |_| {}

    return any_cleaned;
}

pub fn scheduleOrRemoveBinary(
    arena: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    exe_path: []const u8,
) !void {
    const exe_dir = Dir.path.dirname(exe_path) orelse return error.InvalidExecutablePath;

    if (std.fmt.allocPrint(arena, "{s}.old", .{exe_path})) |old_p| {
        Dir.deleteFileAbsolute(io, old_p) catch {};
    } else |_| {}

    if (builtin.os.tag != .windows) {
        Dir.deleteFileAbsolute(io, exe_path) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => return error.UninstallPermissionDenied,
            else => return err,
        };
        if (containsAsciiIgnoreCase(exe_dir, "syncide")) {
            Dir.deleteDirAbsolute(io, exe_dir) catch {};
            if (Dir.path.dirname(exe_dir)) |parent_dir| {
                if (containsAsciiIgnoreCase(parent_dir, "syncide")) {
                    Dir.deleteDirAbsolute(io, parent_dir) catch {};
                }
            }
        }
        return;
    }

    const trash_exe = try std.fmt.allocPrint(arena, "{s}.uninstall", .{exe_path});
    Dir.deleteFileAbsolute(io, trash_exe) catch {};

    updater.moveExecutableOrFile(io, exe_path, trash_exe) catch {
        return error.UninstallPermissionDenied;
    };

    const sys_root = environ_map.get("SystemRoot") orelse "C:\\Windows";
    const ps_exe = try Dir.path.join(arena, &.{
        sys_root,
        "System32",
        "WindowsPowerShell",
        "v1.0",
        "powershell.exe",
    });

    var child_env = std.process.Environ.Map.init(arena);
    for (environ_map.keys(), environ_map.values()) |k, v| {
        try child_env.put(k, v);
    }
    try child_env.put("SYNCIDE_DEL_EXE", trash_exe);

    if (containsAsciiIgnoreCase(exe_dir, "syncide")) {
        try child_env.put("SYNCIDE_DEL_DIR", exe_dir);
        if (Dir.path.dirname(exe_dir)) |parent_dir| {
            if (containsAsciiIgnoreCase(parent_dir, "syncide")) {
                try child_env.put("SYNCIDE_DEL_PARENT", parent_dir);
            }
        }
    }

    const ps_cleanup =
        "Start-Sleep -Milliseconds 600; " ++
        "if ($env:SYNCIDE_DEL_EXE) { Remove-Item -LiteralPath $env:SYNCIDE_DEL_EXE -Force -ErrorAction SilentlyContinue }; " ++
        "if ($env:SYNCIDE_DEL_DIR -and @(Get-ChildItem -LiteralPath $env:SYNCIDE_DEL_DIR -Force -ErrorAction SilentlyContinue).Count -eq 0) { Remove-Item -LiteralPath $env:SYNCIDE_DEL_DIR -Force -ErrorAction SilentlyContinue }; " ++
        "if ($env:SYNCIDE_DEL_PARENT -and @(Get-ChildItem -LiteralPath $env:SYNCIDE_DEL_PARENT -Force -ErrorAction SilentlyContinue).Count -eq 0) { Remove-Item -LiteralPath $env:SYNCIDE_DEL_PARENT -Force -ErrorAction SilentlyContinue }";

    _ = std.process.spawn(io, .{
        .argv = &.{ ps_exe, "-NoProfile", "-NonInteractive", "-Command", ps_cleanup },
        .cwd = .{ .path = sys_root },
        .environ_map = &child_env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch {};
}
