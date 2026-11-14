const std = @import("std");
const archive = @import("archive.zig");
const discovery = @import("discovery.zig");
const extensions = @import("extensions.zig");
const linker = @import("linker.zig");
const paths = @import("paths.zig");
const state_mod = @import("state.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;

pub const InitSyncOptions = struct {
    platform_paths: types.PlatformPaths,
    selected_ides: []const types.IdeInstallation,
    primary_ide: types.IdeInstallation,
    store_dir: []const u8,
    merge_extensions: bool,
    progress_out: ?*Io.Writer = null,
};

pub const SyncSummary = struct {
    store_dir: []const u8,
    extensions_total: usize,
    backups_created: []const []const u8,
    linked_ides: []const []const u8,
    warnings: []const []const u8,
};

fn seedStoreConfigFile(
    arena: Allocator,
    io: Io,
    src_path: []const u8,
    dst_path: []const u8,
    empty_fallback: []const u8,
) !void {
    if (Dir.path.dirname(dst_path)) |parent| {
        try Dir.cwd().createDirPath(io, parent);
    }

    if (!paths.pathsEqual(src_path, dst_path)) {
        if (Dir.accessAbsolute(io, src_path, .{})) |_| {
            const st = linker.inspectLink(arena, io, src_path, dst_path);
            if (st != .linked and st != .hardlinked) {
                try linker.copyFileAbsolute(io, src_path, dst_path);
                return;
            }
        } else |_| {}
    }

    if (Dir.accessAbsolute(io, dst_path, .{})) |_| {} else |_| {
        try Dir.cwd().writeFile(io, .{ .sub_path = dst_path, .data = empty_fallback });
    }
}

fn containsPath(list: []const []const u8, candidate: []const u8) bool {
    for (list) |item| {
        if (paths.pathsEqual(item, candidate)) {
            return true;
        }
    }
    return false;
}

pub fn initializeSync(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    opts: InitSyncOptions,
) !SyncSummary {
    const store = try paths.getStorePaths(arena, opts.store_dir);
    const ts_slug = try archive.makeTimestampSlugAlloc(arena, io);

    var managed: std.ArrayList(types.IdeInstallation) = .empty;
    try managed.append(arena, opts.primary_ide);
    for (opts.selected_ides) |ide| {
        var exists = false;
        for (managed.items) |m| {
            if (std.mem.eql(u8, m.id, ide.id)) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            try managed.append(arena, ide);
        }
    }

    var backups: std.ArrayList([]const u8) = .empty;
    var warnings: std.ArrayList([]const u8) = .empty;
    var seen_app_dirs: std.ArrayList([]const u8) = .empty;
    var seen_dot_dirs: std.ArrayList([]const u8) = .empty;

    // 1. Create compressed .zip backups inside each IDE's own folders BEFORE mutating links
    for (managed.items, 0..) |ide, idx| {
        if (opts.progress_out) |pw| {
            try pw.print("  [{d}/{d}] Backing up {s} ({s})...\n", .{
                idx + 1,
                managed.items.len,
                ide.name,
                ide.id,
            });
            try pw.flush();
        }
        if (!containsPath(seen_app_dirs.items, ide.app_dir)) {
            try seen_app_dirs.append(arena, ide.app_dir);
            if (try archive.backupIdeUserConfig(arena, gpa, io, environ_map, ide, ts_slug)) |zip_p| {
                try backups.append(arena, zip_p);
            }
        }
        if (!containsPath(seen_dot_dirs.items, ide.dot_dir)) {
            try seen_dot_dirs.append(arena, ide.dot_dir);
            if (try archive.backupIdeExtensions(arena, gpa, io, environ_map, ide, ts_slug)) |zip_p| {
                try backups.append(arena, zip_p);
            }
        }
    }

    // 2. Populate central store from Primary IDE (+ optional unique extensions from other IDEs)
    if (opts.progress_out) |pw| {
        try pw.print("  Populating central store from {s}...\n", .{opts.primary_ide.name});
        try pw.flush();
    }
    try Dir.cwd().createDirPath(io, store.user_dir);
    try Dir.cwd().createDirPath(io, store.extensions_dir);

    try seedStoreConfigFile(arena, io, opts.primary_ide.settings_path, store.settings_path, "{}\n");
    try seedStoreConfigFile(arena, io, opts.primary_ide.keybindings_path, store.keybindings_path, "[]\n");

    const ext_total = try extensions.populateStoreExtensions(
        arena,
        io,
        opts.primary_ide,
        managed.items,
        store.extensions_dir,
        opts.merge_extensions,
    );

    // 3. Link all selected IDEs
    var linked_names: std.ArrayList([]const u8) = .empty;
    var linked_ext_dirs: std.ArrayList([]const u8) = .empty;

    for (managed.items) |ide| {
        _ = linker.linkConfigFile(arena, io, ide.settings_path, store.settings_path) catch |err| {
            try warnings.append(arena, try std.fmt.allocPrint(arena, "{s} settings: {s}", .{ ide.name, @errorName(err) }));
            continue;
        };
        _ = linker.linkConfigFile(arena, io, ide.keybindings_path, store.keybindings_path) catch |err| {
            try warnings.append(arena, try std.fmt.allocPrint(arena, "{s} keybindings: {s}", .{ ide.name, @errorName(err) }));
            continue;
        };

        if (!containsPath(linked_ext_dirs.items, ide.extensions_dir)) {
            if (linker.linkExtensionsDir(arena, io, ide.extensions_dir, store.extensions_dir)) |_| {
                try linked_ext_dirs.append(arena, ide.extensions_dir);
            } else |err| {
                try warnings.append(
                    arena,
                    try std.fmt.allocPrint(arena, "{s} extensions: {s} (close IDE and run 'syncide sync')", .{ ide.name, @errorName(err) }),
                );
                continue;
            }
        }
        try linked_names.append(arena, ide.name);
    }

    // 4. Persist state.json
    var managed_ids = try arena.alloc([]const u8, managed.items.len);
    for (managed.items, 0..) |m, idx| {
        managed_ids[idx] = m.id;
    }

    try state_mod.saveState(arena, io, opts.platform_paths, .{
        .version = 1,
        .storeDir = store.store_dir,
        .primaryIdeId = opts.primary_ide.id,
        .managedIdeIds = managed_ids,
        .mergeExtensions = opts.merge_extensions,
    });

    return .{
        .store_dir = store.store_dir,
        .extensions_total = ext_total,
        .backups_created = try backups.toOwnedSlice(arena),
        .linked_ides = try linked_names.toOwnedSlice(arena),
        .warnings = try warnings.toOwnedSlice(arena),
    };
}

pub fn runManualSync(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    p: types.PlatformPaths,
    explicit_store_dir: ?[]const u8,
    include_new: bool,
) !SyncSummary {
    const st = (try state_mod.loadState(arena, io, p, explicit_store_dir)) orelse {
        return error.NotInitialized;
    };

    const store = try paths.getStorePaths(arena, st.storeDir);
    try Dir.cwd().createDirPath(io, store.user_dir);
    try Dir.cwd().createDirPath(io, store.extensions_dir);

    if (Dir.accessAbsolute(io, store.settings_path, .{})) |_| {} else |_| {
        try Dir.cwd().writeFile(io, .{ .sub_path = store.settings_path, .data = "{}\n" });
    }
    if (Dir.accessAbsolute(io, store.keybindings_path, .{})) |_| {} else |_| {
        try Dir.cwd().writeFile(io, .{ .sub_path = store.keybindings_path, .data = "[]\n" });
    }

    const discovered = try discovery.discoverIdes(arena, io, p);
    var managed_ids_list: std.ArrayList([]const u8) = .empty;
    for (st.managedIdeIds) |id| {
        try managed_ids_list.append(arena, id);
    }

    var warnings: std.ArrayList([]const u8) = .empty;

    for (discovered) |ide| {
        var is_managed = false;
        for (managed_ids_list.items) |mid| {
            if (std.mem.eql(u8, mid, ide.id)) {
                is_managed = true;
                break;
            }
        }
        if (!is_managed) {
            if (include_new) {
                try managed_ids_list.append(arena, ide.id);
            } else {
                try warnings.append(
                    arena,
                    try std.fmt.allocPrint(arena, "Unmanaged IDE detected: {s} (use '--include-new' to link)", .{ide.name}),
                );
            }
        }
    }

    var managed_ides: std.ArrayList(types.IdeInstallation) = .empty;
    for (discovered) |ide| {
        for (managed_ids_list.items) |mid| {
            if (std.mem.eql(u8, mid, ide.id)) {
                try managed_ides.append(arena, ide);
                break;
            }
        }
    }

    // Reconcile config edits if any link was replaced by an atomic save
    const ConfigKind = enum { settings, keybindings };
    for ([_]ConfigKind{ .settings, .keybindings }) |kind| {
        const store_file = if (kind == .settings) store.settings_path else store.keybindings_path;
        var newest_path = store_file;
        var newest_ns: i96 = if (Dir.cwd().statFile(io, store_file, .{ .follow_symlinks = true })) |s|
            s.mtime.nanoseconds
        else |_|
            0;

        for (managed_ides.items) |ide| {
            const ide_file = if (kind == .settings) ide.settings_path else ide.keybindings_path;
            const lstate = linker.inspectLink(arena, io, ide_file, store_file);
            if (lstate == .unlinked_real) {
                if (Dir.cwd().statFile(io, ide_file, .{ .follow_symlinks = false })) |ist| {
                    if (ist.mtime.nanoseconds > newest_ns) {
                        newest_ns = ist.mtime.nanoseconds;
                        newest_path = ide_file;
                    }
                } else |_| {}
            }
        }

        if (!paths.pathsEqual(newest_path, store_file)) {
            try linker.copyFileAbsolute(io, newest_path, store_file);
        }
    }

    const ts_slug = try archive.makeTimestampSlugAlloc(arena, io);
    var backups: std.ArrayList([]const u8) = .empty;
    var linked_names: std.ArrayList([]const u8) = .empty;
    var linked_ext_dirs: std.ArrayList([]const u8) = .empty;

    for (managed_ides.items) |ide| {
        const set_st = linker.inspectLink(arena, io, ide.settings_path, store.settings_path);
        const key_st = linker.inspectLink(arena, io, ide.keybindings_path, store.keybindings_path);
        if (set_st == .unlinked_real or key_st == .unlinked_real) {
            if (try archive.backupIdeUserConfig(arena, gpa, io, environ_map, ide, ts_slug)) |zip_p| {
                try backups.append(arena, zip_p);
            }
        }

        const ext_st = linker.inspectLink(arena, io, ide.extensions_dir, store.extensions_dir);
        if (ext_st == .unlinked_real) {
            if (try archive.backupIdeExtensions(arena, gpa, io, environ_map, ide, ts_slug)) |zip_p| {
                try backups.append(arena, zip_p);
            }
            _ = try extensions.populateStoreExtensions(arena, io, ide, &.{}, store.extensions_dir, false);
        }

        _ = linker.linkConfigFile(arena, io, ide.settings_path, store.settings_path) catch |err| {
            try warnings.append(arena, try std.fmt.allocPrint(arena, "{s} settings: {s}", .{ ide.name, @errorName(err) }));
            continue;
        };
        _ = linker.linkConfigFile(arena, io, ide.keybindings_path, store.keybindings_path) catch |err| {
            try warnings.append(arena, try std.fmt.allocPrint(arena, "{s} keybindings: {s}", .{ ide.name, @errorName(err) }));
            continue;
        };

        if (!containsPath(linked_ext_dirs.items, ide.extensions_dir)) {
            if (linker.linkExtensionsDir(arena, io, ide.extensions_dir, store.extensions_dir)) |_| {
                try linked_ext_dirs.append(arena, ide.extensions_dir);
            } else |err| {
                try warnings.append(
                    arena,
                    try std.fmt.allocPrint(arena, "{s} extensions: {s} (close IDE and run 'syncide sync')", .{ ide.name, @errorName(err) }),
                );
                continue;
            }
        }
        try linked_names.append(arena, ide.name);
    }

    const reconciled = try extensions.reconcileExtensionsManifest(arena, io, store.extensions_dir);

    try state_mod.saveState(arena, io, p, .{
        .version = 1,
        .storeDir = store.store_dir,
        .primaryIdeId = st.primaryIdeId,
        .managedIdeIds = try managed_ids_list.toOwnedSlice(arena),
        .mergeExtensions = st.mergeExtensions,
    });

    return .{
        .store_dir = store.store_dir,
        .extensions_total = reconciled.len,
        .backups_created = try backups.toOwnedSlice(arena),
        .linked_ides = try linked_names.toOwnedSlice(arena),
        .warnings = try warnings.toOwnedSlice(arena),
    };
}
