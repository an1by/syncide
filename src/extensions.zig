const std = @import("std");
const builtin = @import("builtin");
const linker = @import("linker.zig");
const paths = @import("paths.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;

pub const InstalledExtInfo = struct {
    id: []const u8,
    version: []const u8,
    folder_name: []const u8,
};

const ParsedExtDir = struct {
    folder_name: []const u8,
    full_path: []const u8,
    id: []const u8,
    version: []const u8,
    uuid: ?[]const u8,
    raw_metadata_json: ?[]const u8,
};

fn compareSemver(a: []const u8, b: []const u8) std.math.Order {
    var it_a = std.mem.tokenizeAny(u8, a, ".-");
    var it_b = std.mem.tokenizeAny(u8, b, ".-");

    while (true) {
        const pa = it_a.next();
        const pb = it_b.next();
        if (pa == null and pb == null) {
            return .eq;
        }
        const sa = pa orelse "0";
        const sb = pb orelse "0";

        const na = std.fmt.parseInt(u64, sa, 10) catch null;
        const nb = std.fmt.parseInt(u64, sb, 10) catch null;
        if (na != null and nb != null) {
            if (na.? != nb.?) {
                return std.math.order(na.?, nb.?);
            }
        } else {
            const ord = std.mem.order(u8, sa, sb);
            if (ord != .eq) {
                return ord;
            }
        }
    }
}

fn readExtensionFolderMeta(
    arena: Allocator,
    io: Io,
    extensions_dir: []const u8,
    folder_name: []const u8,
) ?ParsedExtDir {
    const full_path = Dir.path.join(arena, &.{ extensions_dir, folder_name }) catch return null;
    const pkg_path = Dir.path.join(arena, &.{ full_path, "package.json" }) catch return null;
    const raw = Dir.cwd().readFileAlloc(io, pkg_path, arena, .limited(2 * 1024 * 1024)) catch return null;

    const parsed = std.json.parseFromSlice(std.json.Value, arena, raw, .{}) catch return null;
    if (parsed.value != .object) {
        return null;
    }
    const obj = parsed.value.object;
    const pub_val = obj.get("publisher") orelse return null;
    const name_val = obj.get("name") orelse return null;
    const ver_val = obj.get("version") orelse return null;
    if (pub_val != .string or name_val != .string or ver_val != .string) {
        return null;
    }
    if (pub_val.string.len == 0 or name_val.string.len == 0 or ver_val.string.len == 0) {
        return null;
    }

    const id_raw = std.fmt.allocPrint(arena, "{s}.{s}", .{ pub_val.string, name_val.string }) catch return null;
    for (id_raw) |*c| {
        c.* = std.ascii.toLower(c.*);
    }

    var uuid: ?[]const u8 = null;
    var raw_metadata_json: ?[]const u8 = null;
    if (obj.get("__metadata")) |meta_val| {
        if (meta_val == .object) {
            if (meta_val.object.get("id")) |id_v| {
                if (id_v == .string) {
                    uuid = arena.dupe(u8, id_v.string) catch null;
                }
            }
            var w: std.Io.Writer.Allocating = .init(arena);
            if (std.json.Stringify.value(meta_val, .{}, &w.writer)) |_| {
                raw_metadata_json = w.written();
            } else |_| {}
        }
    }

    return .{
        .folder_name = arena.dupe(u8, folder_name) catch return null,
        .full_path = full_path,
        .id = id_raw,
        .version = arena.dupe(u8, ver_val.string) catch return null,
        .uuid = uuid,
        .raw_metadata_json = raw_metadata_json,
    };
}

fn readObsoleteSet(arena: Allocator, io: Io, extensions_dir: []const u8) std.StringHashMapUnmanaged(bool) {
    var map: std.StringHashMapUnmanaged(bool) = .empty;
    const obs_path = Dir.path.join(arena, &.{ extensions_dir, ".obsolete" }) catch return map;
    const raw = Dir.cwd().readFileAlloc(io, obs_path, arena, .limited(512 * 1024)) catch return map;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, raw, .{}) catch return map;
    if (parsed.value != .object) {
        return map;
    }
    var it = parsed.value.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* == .bool and kv.value_ptr.bool) {
            const k = arena.dupe(u8, kv.key_ptr.*) catch continue;
            map.put(arena, k, true) catch {};
        }
    }
    return map;
}

fn isSafeSingleSegment(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
        return false;
    }
    return std.mem.indexOfAny(u8, name, "/\\:") == null;
}

pub fn cleanObsoleteExtensions(arena: Allocator, io: Io, store_ext_dir: []const u8) usize {
    const obs = readObsoleteSet(arena, io, store_ext_dir);
    if (obs.count() == 0) {
        return 0;
    }

    var removed: usize = 0;
    var remaining: std.ArrayList([]const u8) = .empty;
    var it = obs.iterator();
    while (it.next()) |kv| {
        const folder = kv.key_ptr.*;
        if (!isSafeSingleSegment(folder)) {
            continue;
        }
        const target = Dir.path.join(arena, &.{ store_ext_dir, folder }) catch continue;
        if (Dir.cwd().deleteTree(io, target)) |_| {
            removed += 1;
        } else |_| {
            remaining.append(arena, folder) catch {};
        }
    }

    const obs_path = Dir.path.join(arena, &.{ store_ext_dir, ".obsolete" }) catch return removed;
    if (remaining.items.len == 0) {
        Dir.deleteFileAbsolute(io, obs_path) catch {};
    } else {
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: std.json.Stringify = .{ .writer = &out.writer };
        jw.beginObject() catch return removed;
        for (remaining.items) |rem| {
            jw.objectField(rem) catch {};
            jw.write(true) catch {};
        }
        jw.endObject() catch {};
        Dir.cwd().writeFile(io, .{ .sub_path = obs_path, .data = out.written() }) catch {};
    }

    return removed;
}

const ExistingEntryPreserve = struct {
    uuid: ?[]const u8,
    metadata_json: ?[]const u8,
};

/// Reconciles `<store_ext_dir>/extensions.json` with installed directories on disk.
pub fn reconcileExtensionsManifest(
    arena: Allocator,
    io: Io,
    store_ext_dir: []const u8,
) ![]InstalledExtInfo {
    try Dir.cwd().createDirPath(io, store_ext_dir);
    _ = cleanObsoleteExtensions(arena, io, store_ext_dir);

    const manifest_path = try Dir.path.join(arena, &.{ store_ext_dir, "extensions.json" });
    var preserve_by_folder: std.StringHashMapUnmanaged(ExistingEntryPreserve) = .empty;
    var preserve_by_id: std.StringHashMapUnmanaged(ExistingEntryPreserve) = .empty;

    if (Dir.cwd().readFileAlloc(io, manifest_path, arena, .limited(8 * 1024 * 1024))) |raw_man| {
        if (std.json.parseFromSlice(std.json.Value, arena, raw_man, .{})) |parsed| {
            if (parsed.value == .array) {
                for (parsed.value.array.items) |item| {
                    if (item != .object) {
                        continue;
                    }
                    const obj = item.object;
                    var uuid: ?[]const u8 = null;
                    var ext_id_lower: ?[]const u8 = null;
                    if (obj.get("identifier")) |ident| {
                        if (ident == .object) {
                            if (ident.object.get("uuid")) |u| {
                                if (u == .string) {
                                    uuid = try arena.dupe(u8, u.string);
                                }
                            }
                            if (ident.object.get("id")) |id_v| {
                                if (id_v == .string) {
                                    const tmp = try arena.dupe(u8, id_v.string);
                                    for (tmp) |*c| {
                                        c.* = std.ascii.toLower(c.*);
                                    }
                                    ext_id_lower = tmp;
                                }
                            }
                        }
                    }

                    var meta_json: ?[]const u8 = null;
                    if (obj.get("metadata")) |m| {
                        if (m == .object) {
                            var mw: std.Io.Writer.Allocating = .init(arena);
                            if (std.json.Stringify.value(m, .{}, &mw.writer)) |_| {
                                meta_json = mw.written();
                            } else |_| {}
                        }
                    }

                    const pres = ExistingEntryPreserve{
                        .uuid = uuid,
                        .metadata_json = meta_json,
                    };

                    if (obj.get("relativeLocation")) |rel_v| {
                        if (rel_v == .string) {
                            try preserve_by_folder.put(arena, try arena.dupe(u8, rel_v.string), pres);
                        }
                    }
                    if (ext_id_lower) |eid| {
                        try preserve_by_id.put(arena, eid, pres);
                    }
                }
            }
        } else |_| {}
    } else |_| {}

    var best_by_id: std.StringHashMapUnmanaged(ParsedExtDir) = .empty;
    var duplicates: std.ArrayList([]const u8) = .empty;

    var dir = try Dir.openDirAbsolute(io, store_ext_dir, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or entry.name.len == 0 or entry.name[0] == '.') {
            continue;
        }
        const meta = readExtensionFolderMeta(arena, io, store_ext_dir, entry.name) orelse continue;
        if (best_by_id.get(meta.id)) |prev| {
            if (compareSemver(meta.version, prev.version) != .lt) {
                try duplicates.append(arena, prev.full_path);
                try best_by_id.put(arena, meta.id, meta);
            } else {
                try duplicates.append(arena, meta.full_path);
            }
        } else {
            try best_by_id.put(arena, meta.id, meta);
        }
    }

    for (duplicates.items) |dup_path| {
        Dir.cwd().deleteTree(io, dup_path) catch {};
    }

    var metas: std.ArrayList(ParsedExtDir) = .empty;
    var bit = best_by_id.valueIterator();
    while (bit.next()) |val_ptr| {
        try metas.append(arena, val_ptr.*);
    }

    std.mem.sort(ParsedExtDir, metas.items, {}, struct {
        fn lessThan(_: void, a: ParsedExtDir, b: ParsedExtDir) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);

    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginArray();

    var summary_list: std.ArrayList(InstalledExtInfo) = .empty;
    const now_ms: i64 = @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));

    for (metas.items) |ext| {
        const pres = preserve_by_folder.get(ext.folder_name) orelse preserve_by_id.get(ext.id);
        const uuid = (if (pres) |p| p.uuid else null) orelse ext.uuid;
        const meta_json = (if (pres) |p| p.metadata_json else null) orelse ext.raw_metadata_json;
        const uri_path = try paths.toVsCodeUriPath(arena, ext.full_path);

        try jw.beginObject();

        try jw.objectField("identifier");
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(ext.id);
        if (uuid) |u| {
            try jw.objectField("uuid");
            try jw.write(u);
        }
        try jw.endObject();

        try jw.objectField("version");
        try jw.write(ext.version);

        try jw.objectField("location");
        try jw.beginObject();
        try jw.objectField("$mid");
        try jw.write(@as(u32, 1));
        try jw.objectField("path");
        try jw.write(uri_path);
        try jw.objectField("scheme");
        try jw.write("file");
        try jw.endObject();

        try jw.objectField("relativeLocation");
        try jw.write(ext.folder_name);

        if (meta_json) |mj| {
            try jw.objectField("metadata");
            try jw.beginWriteRaw();
            try out.writer.writeAll(mj);
            jw.endWriteRaw();
        } else {
            try jw.objectField("metadata");
            try jw.beginObject();
            try jw.objectField("installedTimestamp");
            try jw.write(now_ms);
            try jw.objectField("pinned");
            try jw.write(false);
            try jw.objectField("source");
            try jw.write("gallery");
            try jw.endObject();
        }

        try jw.endObject();

        try summary_list.append(arena, .{
            .id = ext.id,
            .version = ext.version,
            .folder_name = ext.folder_name,
        });
    }

    try jw.endArray();
    try Dir.cwd().writeFile(io, .{
        .sub_path = manifest_path,
        .data = out.written(),
    });

    return summary_list.toOwnedSlice(arena);
}

pub fn populateStoreExtensions(
    arena: Allocator,
    io: Io,
    primary_ide: types.IdeInstallation,
    other_ides: []const types.IdeInstallation,
    store_ext_dir: []const u8,
    merge_others: bool,
) !usize {
    try Dir.cwd().createDirPath(io, store_ext_dir);

    var installed_ids: std.StringHashMapUnmanaged(void) = .empty;
    {
        var store_dir = try Dir.openDirAbsolute(io, store_ext_dir, .{ .iterate = true });
        defer store_dir.close(io);
        var it = store_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory and entry.name.len > 0 and entry.name[0] != '.') {
                if (readExtensionFolderMeta(arena, io, store_ext_dir, entry.name)) |meta| {
                    try installed_ids.put(arena, meta.id, {});
                }
            }
        }
    }

    const CopyCtx = struct {
        fn copyFromSource(
            alloc: Allocator,
            io_ctx: Io,
            src_ext_dir: []const u8,
            dst_ext_dir: []const u8,
            is_primary: bool,
            seen: *std.StringHashMapUnmanaged(void),
        ) !void {
            if (paths.pathsEqual(src_ext_dir, dst_ext_dir)) {
                return;
            }
            const st = Dir.cwd().statFile(io_ctx, src_ext_dir, .{ .follow_symlinks = false }) catch return;
            if (st.kind != .directory) {
                return;
            }

            if (is_primary) {
                const src_man = try Dir.path.join(alloc, &.{ src_ext_dir, "extensions.json" });
                const dst_man = try Dir.path.join(alloc, &.{ dst_ext_dir, "extensions.json" });
                if (Dir.accessAbsolute(io_ctx, src_man, .{})) |_| {
                    if (Dir.accessAbsolute(io_ctx, dst_man, .{})) |_| {} else |_| {
                        linker.copyFileAbsolute(io_ctx, src_man, dst_man) catch {};
                    }
                } else |_| {}
            }

            const obs = readObsoleteSet(alloc, io_ctx, src_ext_dir);
            var src_dir = Dir.openDirAbsolute(io_ctx, src_ext_dir, .{ .iterate = true }) catch return;
            defer src_dir.close(io_ctx);

            var it = src_dir.iterate();
            while (try it.next(io_ctx)) |entry| {
                if (entry.kind != .directory or entry.name.len == 0 or entry.name[0] == '.') {
                    continue;
                }
                if (obs.contains(entry.name)) {
                    continue;
                }
                const meta = readExtensionFolderMeta(alloc, io_ctx, src_ext_dir, entry.name) orelse continue;
                if (seen.contains(meta.id)) {
                    continue;
                }
                const dst_folder = try Dir.path.join(alloc, &.{ dst_ext_dir, entry.name });
                if (Dir.accessAbsolute(io_ctx, dst_folder, .{})) |_| {} else |_| {
                    try linker.copyTreeAbsolute(alloc, io_ctx, meta.full_path, dst_folder);
                }
                try seen.put(alloc, meta.id, {});
            }
        }
    };

    try CopyCtx.copyFromSource(arena, io, primary_ide.extensions_dir, store_ext_dir, true, &installed_ids);

    if (merge_others) {
        for (other_ides) |ide| {
            if (!std.mem.eql(u8, ide.id, primary_ide.id)) {
                try CopyCtx.copyFromSource(arena, io, ide.extensions_dir, store_ext_dir, false, &installed_ids);
            }
        }
    }

    const final_list = try reconcileExtensionsManifest(arena, io, store_ext_dir);
    return final_list.len;
}

const FALLBACK_CLIS = [_][]const u8{ "code", "cursor", "codium", "windsurf", "trae", "agy", "code-insiders" };

fn findInPath(
    arena: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    name: []const u8,
) ?[]const u8 {
    const path_val = environ_map.get("PATH") orelse environ_map.get("Path") orelse return null;
    const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var it = std.mem.tokenizeScalar(u8, path_val, sep);
    while (it.next()) |dir_entry| {
        const clean_dir = std.mem.trim(u8, dir_entry, " \t\"");
        if (clean_dir.len == 0) {
            continue;
        }
        if (builtin.os.tag == .windows) {
            const suffixes = [_][]const u8{ ".cmd", ".exe", "" };
            for (suffixes) |sfx| {
                const file_name = std.fmt.allocPrint(arena, "{s}{s}", .{ name, sfx }) catch continue;
                const cand = Dir.path.join(arena, &.{ clean_dir, file_name }) catch continue;
                if (Dir.accessAbsolute(io, cand, .{})) |_| {
                    return cand;
                } else |_| {}
            }
        } else {
            const cand = Dir.path.join(arena, &.{ clean_dir, name }) catch continue;
            if (Dir.accessAbsolute(io, cand, .{})) |_| {
                return cand;
            } else |_| {}
        }
    }
    return null;
}

pub fn findIdeCliBinary(
    arena: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    preferred_ides: []const types.IdeInstallation,
) ?[]const u8 {
    for (preferred_ides) |ide| {
        for (ide.cli_names) |cli| {
            if (findInPath(arena, io, environ_map, cli)) |hit| {
                return hit;
            }
        }
    }
    for (FALLBACK_CLIS) |cli| {
        if (findInPath(arena, io, environ_map, cli)) |hit| {
            return hit;
        }
    }

    if (builtin.os.tag == .windows) {
        const local_app = environ_map.get("LOCALAPPDATA") orelse "";
        const prog_files = environ_map.get("ProgramFiles") orelse "C:\\Program Files";
        const cands = [_][]const u8{
            Dir.path.join(arena, &.{ prog_files, "Microsoft VS Code", "bin", "code.cmd" }) catch "",
            Dir.path.join(arena, &.{ local_app, "Programs", "Microsoft VS Code", "bin", "code.cmd" }) catch "",
            Dir.path.join(arena, &.{ local_app, "Programs", "cursor", "resources", "app", "bin", "cursor.cmd" }) catch "",
            Dir.path.join(arena, &.{ local_app, "Programs", "Windsurf", "bin", "windsurf.cmd" }) catch "",
            Dir.path.join(arena, &.{ local_app, "Programs", "Trae", "bin", "trae.cmd" }) catch "",
        };
        for (cands) |cand| {
            if (cand.len > 0) {
                if (Dir.accessAbsolute(io, cand, .{})) |_| {
                    return cand;
                } else |_| {}
            }
        }
    }
    return null;
}

fn validateSafeExtArg(arg: []const u8) !void {
    const trimmed = std.mem.trim(u8, arg, " \t");
    if (trimmed.len == 0) {
        return error.UnsafeExtensionArgument;
    }
    if (std.mem.indexOfAny(u8, arg, "\r\n\x00\"&|<>^`$;") != null) {
        return error.UnsafeExtensionArgument;
    }
}

fn runIdeCli(
    arena: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    cli_path: []const u8,
    cli_args: []const []const u8,
) !bool {
    var argv: std.ArrayList([]const u8) = .empty;

    if (builtin.os.tag == .windows and
        (std.ascii.endsWithIgnoreCase(cli_path, ".cmd") or std.ascii.endsWithIgnoreCase(cli_path, ".bat")))
    {
        const comspec = environ_map.get("ComSpec") orelse "C:\\Windows\\System32\\cmd.exe";
        try argv.appendSlice(arena, &.{ comspec, "/c", cli_path });
        try argv.appendSlice(arena, cli_args);
    } else {
        try argv.append(arena, cli_path);
        try argv.appendSlice(arena, cli_args);
    }

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = environ_map,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
        .create_no_window = false,
    });
    const term = try child.wait(io);
    return term.success();
}

pub fn installExtensionsToStore(
    arena: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    store_ext_dir: []const u8,
    targets: []const []const u8,
    preferred_ides: []const types.IdeInstallation,
    force: bool,
) !void {
    const cli = findIdeCliBinary(arena, io, environ_map, preferred_ides) orelse {
        return error.IdeCliNotFound;
    };

    try Dir.cwd().createDirPath(io, store_ext_dir);

    for (targets) |target| {
        try validateSafeExtArg(target);
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(arena, &.{ "--extensions-dir", store_ext_dir, "--install-extension", target });
        if (force) {
            try args.append(arena, "--force");
        }
        const ok = try runIdeCli(arena, io, environ_map, cli, args.items);
        if (!ok) {
            return error.ExtensionInstallFailed;
        }
    }

    _ = try reconcileExtensionsManifest(arena, io, store_ext_dir);
}

pub const UninstallResult = struct {
    removed: []const []const u8,
    not_found: []const []const u8,
};

pub fn uninstallExtensionsFromStore(
    arena: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    store_ext_dir: []const u8,
    targets: []const []const u8,
    preferred_ides: []const types.IdeInstallation,
) !UninstallResult {
    try Dir.cwd().createDirPath(io, store_ext_dir);
    const cli_opt = findIdeCliBinary(arena, io, environ_map, preferred_ides);

    var removed: std.ArrayList([]const u8) = .empty;
    var not_found: std.ArrayList([]const u8) = .empty;

    for (targets) |raw_target| {
        try validateSafeExtArg(raw_target);
        const lower_id = try arena.dupe(u8, raw_target);
        for (lower_id) |*c| {
            c.* = std.ascii.toLower(c.*);
        }

        var did_remove = false;
        if (cli_opt) |cli| {
            const ok = runIdeCli(
                arena,
                io,
                environ_map,
                cli,
                &.{ "--extensions-dir", store_ext_dir, "--uninstall-extension", lower_id },
            ) catch false;
            if (ok) {
                did_remove = true;
            }
        }

        if (Dir.openDirAbsolute(io, store_ext_dir, .{ .iterate = true })) |dir_val| {
            var dir = dir_val;
            defer dir.close(io);
            var it = dir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind != .directory or entry.name.len == 0 or entry.name[0] == '.') {
                    continue;
                }
                const meta = readExtensionFolderMeta(arena, io, store_ext_dir, entry.name) orelse continue;
                if (std.mem.eql(u8, meta.id, lower_id)) {
                    Dir.cwd().deleteTree(io, meta.full_path) catch {};
                    did_remove = true;
                }
            }
        } else |_| {}

        if (did_remove) {
            try removed.append(arena, lower_id);
        } else {
            try not_found.append(arena, lower_id);
        }
    }

    _ = try reconcileExtensionsManifest(arena, io, store_ext_dir);
    return .{
        .removed = try removed.toOwnedSlice(arena),
        .not_found = try not_found.toOwnedSlice(arena),
    };
}
