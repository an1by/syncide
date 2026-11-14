const std = @import("std");
const paths = @import("paths.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;

fn parseStateBytes(arena: Allocator, raw: []const u8) !types.SyncState {
    const parsed = try std.json.parseFromSlice(types.SyncState, arena, raw, .{
        .ignore_unknown_fields = true,
    });
    const val = parsed.value;
    if (val.version != 1 or val.storeDir.len == 0 or val.primaryIdeId.len == 0) {
        return error.InvalidSyncState;
    }

    const ids = try arena.alloc([]const u8, val.managedIdeIds.len);
    for (val.managedIdeIds, 0..) |item, i| {
        ids[i] = try arena.dupe(u8, item);
    }

    return .{
        .version = 1,
        .storeDir = try paths.trimTrailingSepAlloc(arena, val.storeDir),
        .primaryIdeId = try arena.dupe(u8, val.primaryIdeId),
        .managedIdeIds = ids,
        .mergeExtensions = val.mergeExtensions,
    };
}

pub fn loadState(
    arena: Allocator,
    io: Io,
    p: types.PlatformPaths,
    explicit_store_dir: ?[]const u8,
) !?types.SyncState {
    if (explicit_store_dir) |custom| {
        const sp = try paths.getStorePaths(arena, custom);
        if (Dir.cwd().readFileAlloc(io, sp.state_path, arena, .limited(1024 * 1024))) |raw| {
            return try parseStateBytes(arena, raw);
        } else |_| {}
    }

    const boot_raw = Dir.cwd().readFileAlloc(io, p.bootstrap_state_path, arena, .limited(1024 * 1024)) catch {
        return null;
    };
    const bootstrap = try parseStateBytes(arena, boot_raw);
    const target_sp = try paths.getStorePaths(arena, bootstrap.storeDir);
    if (!paths.pathsEqual(target_sp.state_path, p.bootstrap_state_path)) {
        if (Dir.cwd().readFileAlloc(io, target_sp.state_path, arena, .limited(1024 * 1024))) |custom_raw| {
            return try parseStateBytes(arena, custom_raw);
        } else |_| {}
    }
    return bootstrap;
}

pub fn saveState(arena: Allocator, io: Io, p: types.PlatformPaths, st: types.SyncState) !void {
    const normalized: types.SyncState = .{
        .version = 1,
        .storeDir = try paths.trimTrailingSepAlloc(arena, st.storeDir),
        .primaryIdeId = st.primaryIdeId,
        .managedIdeIds = st.managedIdeIds,
        .mergeExtensions = st.mergeExtensions,
    };

    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(normalized, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    const payload = out.written();

    if (Dir.path.dirname(p.bootstrap_state_path)) |parent| {
        try Dir.cwd().createDirPath(io, parent);
    }
    try Dir.cwd().writeFile(io, .{
        .sub_path = p.bootstrap_state_path,
        .data = payload,
    });

    const target_sp = try paths.getStorePaths(arena, normalized.storeDir);
    if (!paths.pathsEqual(target_sp.state_path, p.bootstrap_state_path)) {
        if (Dir.path.dirname(target_sp.state_path)) |parent| {
            try Dir.cwd().createDirPath(io, parent);
        }
        try Dir.cwd().writeFile(io, .{
            .sub_path = target_sp.state_path,
            .data = payload,
        });
    }
}
