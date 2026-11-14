const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const File = std.Io.File;
const Io = std.Io;
const flate = std.compress.flate;
const zip = std.zip;

pub fn makeTimestampSlugAlloc(arena: Allocator, io: Io) ![]const u8 {
    const ts = Io.Clock.real.now(io);
    const secs_signed = @divFloor(ts.nanoseconds, std.time.ns_per_s);
    const epoch_secs: u64 = if (secs_signed > 0) @intCast(secs_signed) else 0;
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();

    return std.fmt.allocPrint(
        arena,
        "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}",
        .{
            yd.year,
            md.month.numeric(),
            md.day_index + 1,
            ds.getHoursIntoDay(),
            ds.getMinutesIntoHour(),
            ds.getSecondsIntoMinute(),
        },
    );
}

const CollectedFile = struct {
    abs_path: []const u8,
    zip_rel_path: []const u8,
};

fn collectFilesRecursive(
    arena: Allocator,
    io: Io,
    base_dir: []const u8,
    rel_target: []const u8,
    out: *std.ArrayList(CollectedFile),
) !void {
    const abs_curr = try Dir.path.join(arena, &.{ base_dir, rel_target });
    const st = Dir.cwd().statFile(io, abs_curr, .{ .follow_symlinks = false }) catch return;
    if (st.kind == .sym_link) {
        return;
    }
    if (st.kind == .file) {
        const normalized_rel = try arena.dupe(u8, rel_target);
        for (normalized_rel) |*c| {
            if (c.* == '\\') {
                c.* = '/';
            }
        }
        try out.append(arena, .{
            .abs_path = abs_curr,
            .zip_rel_path = normalized_rel,
        });
        return;
    }
    if (st.kind == .directory) {
        var dir = Dir.openDirAbsolute(io, abs_curr, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            const child_rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel_target, entry.name });
            try collectFilesRecursive(arena, io, base_dir, child_rel, out);
        }
    }
}

const CentralEntryMeta = struct {
    name: []const u8,
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    method: zip.CompressionMethod,
    local_offset: u64,
};

fn deflateBytesAlloc(gpa: Allocator, raw: []const u8) ![]u8 {
    var out_alloc: std.Io.Writer.Allocating = .init(gpa);
    errdefer out_alloc.deinit();

    // Ensure backing writer buffer exceeds Compress.init assertion (> 8 bytes)
    try out_alloc.ensureUnusedCapacity(4096);

    const win_buf = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(win_buf);

    var comp = try flate.Compress.init(&out_alloc.writer, win_buf, .raw, .default);
    try comp.writer.writeAll(raw);
    try comp.writer.flush();
    // Finish raw deflate block
    comp.finish() catch return error.CompressionFailed;

    return out_alloc.toOwnedSlice();
}

/// Pure-Zig DEFLATE + ZIP64 archive builder (zero external tool fallback).
pub fn createZipPure(
    gpa: Allocator,
    io: Io,
    zip_path: []const u8,
    base_dir: []const u8,
    rel_targets: []const []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var files: std.ArrayList(CollectedFile) = .empty;
    for (rel_targets) |rel| {
        try collectFilesRecursive(arena, io, base_dir, rel, &files);
    }

    if (Dir.path.dirname(zip_path)) |parent| {
        try Dir.cwd().createDirPath(io, parent);
    }

    var out_file = try Dir.createFileAbsolute(io, zip_path, .{ .truncate = true });
    defer out_file.close(io);

    var write_buf: [16384]u8 = undefined;
    var fw = out_file.writer(io, &write_buf);
    const w = &fw.interface;

    var central: std.ArrayList(CentralEntryMeta) = .empty;
    var offset: u64 = 0;

    // Bit 11 (0x0800) indicates UTF-8 file names
    const utf8_flags: zip.LocalFileHeader = undefined;
    _ = utf8_flags;
    const raw_utf8_flag: u16 = 0x0800;

    for (files.items) |f| {
        const raw = try Dir.cwd().readFileAlloc(io, f.abs_path, gpa, .limited(256 * 1024 * 1024));
        defer gpa.free(raw);

        const crc = std.hash.Crc32.hash(raw);
        var compressed_owned: ?[]u8 = null;
        defer if (compressed_owned) |cb| gpa.free(cb);

        var payload: []const u8 = raw;
        var method: zip.CompressionMethod = .store;
        if (raw.len > 0) {
            if (deflateBytesAlloc(gpa, raw)) |comp_bytes| {
                if (comp_bytes.len < raw.len) {
                    compressed_owned = comp_bytes;
                    payload = comp_bytes;
                    method = .deflate;
                } else {
                    gpa.free(comp_bytes);
                }
            } else |_| {}
        }

        const local_offset = offset;
        var lfh = zip.LocalFileHeader{
            .signature = zip.local_file_header_sig,
            .version_needed_to_extract = 20,
            .flags = @bitCast(raw_utf8_flag),
            .compression_method = method,
            .last_modification_time = 0,
            .last_modification_date = 0x0021, // 1980-01-01 valid DOS date
            .crc32 = crc,
            .compressed_size = @intCast(payload.len),
            .uncompressed_size = @intCast(raw.len),
            .filename_len = @intCast(f.zip_rel_path.len),
            .extra_len = 0,
        };
        if (builtin.cpu.arch.endian() != .little) {
            std.mem.byteSwapAllFields(zip.LocalFileHeader, &lfh);
        }

        try w.writeAll(std.mem.asBytes(&lfh));
        try w.writeAll(f.zip_rel_path);
        if (payload.len > 0) {
            try w.writeAll(payload);
        }
        offset += @sizeOf(zip.LocalFileHeader) + f.zip_rel_path.len + payload.len;

        try central.append(arena, .{
            .name = f.zip_rel_path,
            .crc32 = crc,
            .compressed_size = @intCast(payload.len),
            .uncompressed_size = @intCast(raw.len),
            .method = method,
            .local_offset = local_offset,
        });
    }

    const cd_start = offset;
    for (central.items) |entry| {
        const need_z64_off = entry.local_offset >= std.math.maxInt(u32);
        const extra_len: u16 = if (need_z64_off) 12 else 0;

        var cdh = zip.CentralDirectoryFileHeader{
            .signature = zip.central_file_header_sig,
            .version_made_by = 45,
            .version_needed_to_extract = if (need_z64_off) 45 else 20,
            .flags = @bitCast(raw_utf8_flag),
            .compression_method = entry.method,
            .last_modification_time = 0,
            .last_modification_date = 0x0021,
            .crc32 = entry.crc32,
            .compressed_size = entry.compressed_size,
            .uncompressed_size = entry.uncompressed_size,
            .filename_len = @intCast(entry.name.len),
            .extra_len = extra_len,
            .comment_len = 0,
            .disk_number = 0,
            .internal_file_attributes = 0,
            .external_file_attributes = 0,
            .local_file_header_offset = if (need_z64_off) std.math.maxInt(u32) else @intCast(entry.local_offset),
        };
        if (builtin.cpu.arch.endian() != .little) {
            std.mem.byteSwapAllFields(zip.CentralDirectoryFileHeader, &cdh);
        }

        try w.writeAll(std.mem.asBytes(&cdh));
        try w.writeAll(entry.name);
        if (need_z64_off) {
            var extra_buf: [12]u8 = undefined;
            std.mem.writeInt(u16, extra_buf[0..2], 0x0001, .little);
            std.mem.writeInt(u16, extra_buf[2..4], 8, .little);
            std.mem.writeInt(u64, extra_buf[4..12], entry.local_offset, .little);
            try w.writeAll(&extra_buf);
        }
        offset += @sizeOf(zip.CentralDirectoryFileHeader) + entry.name.len + extra_len;
    }

    const cd_size = offset - cd_start;
    const count = central.items.len;
    const need_z64_eocd = count >= std.math.maxInt(u16) or
        cd_size >= std.math.maxInt(u32) or
        cd_start >= std.math.maxInt(u32);

    if (need_z64_eocd) {
        const z64_offset = offset;
        var eocd64 = zip.EndRecord64{
            .signature = zip.end_record64_sig,
            .end_record_size = 44,
            .version_made_by = 45,
            .version_needed_to_extract = 45,
            .disk_number = 0,
            .central_directory_disk_number = 0,
            .record_count_disk = count,
            .record_count_total = count,
            .central_directory_size = cd_size,
            .central_directory_offset = cd_start,
        };
        var loc64 = zip.EndLocator64{
            .signature = zip.end_locator64_sig,
            .zip64_disk_count = 0,
            .record_file_offset = z64_offset,
            .total_disk_count = 1,
        };
        if (builtin.cpu.arch.endian() != .little) {
            std.mem.byteSwapAllFields(zip.EndRecord64, &eocd64);
            std.mem.byteSwapAllFields(zip.EndLocator64, &loc64);
        }
        try w.writeAll(std.mem.asBytes(&eocd64));
        try w.writeAll(std.mem.asBytes(&loc64));
    }

    var eocd = zip.EndRecord{
        .signature = zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = @intCast(@min(count, std.math.maxInt(u16))),
        .record_count_total = @intCast(@min(count, std.math.maxInt(u16))),
        .central_directory_size = @intCast(@min(cd_size, std.math.maxInt(u32))),
        .central_directory_offset = @intCast(@min(cd_start, std.math.maxInt(u32))),
        .comment_len = 0,
    };
    if (builtin.cpu.arch.endian() != .little) {
        std.mem.byteSwapAllFields(zip.EndRecord, &eocd);
    }
    try w.writeAll(std.mem.asBytes(&eocd));
    try fw.flush();
}

fn verifyZipArchive(io: Io, zip_path: []const u8) !void {
    var f = try Dir.openFileAbsolute(io, zip_path, .{});
    defer f.close(io);

    const st = try f.stat(io);
    if (st.size < 22) {
        return error.TruncatedBackupArchive;
    }

    var magic: [2]u8 = undefined;
    var r = f.reader(io, &.{});
    const n = r.interface.readSliceShort(&magic) catch return error.CorruptBackupArchive;
    if (n < 2 or magic[0] != 'P' or magic[1] != 'K') {
        return error.InvalidZipSignature;
    }
}

pub fn createCompressedZip(
    gpa: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    zip_path: []const u8,
    base_dir: []const u8,
    rel_targets: []const []const u8,
) !void {
    if (Dir.path.dirname(zip_path)) |parent| {
        try Dir.cwd().createDirPath(io, parent);
    }
    Dir.deleteFileAbsolute(io, zip_path) catch {};

    var native_ok = false;

    if (builtin.os.tag == .windows) {
        const sys_root = environ_map.get("SystemRoot") orelse "C:\\Windows";
        const tar_exe = try Dir.path.join(gpa, &.{ sys_root, "System32", "tar.exe" });
        defer gpa.free(tar_exe);

        if (Dir.accessAbsolute(io, tar_exe, .{})) |_| {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(gpa);
            try argv.appendSlice(gpa, &.{ tar_exe, "-a", "-c", "-f", zip_path, "-C", base_dir });
            try argv.appendSlice(gpa, rel_targets);

            var child = std.process.spawn(io, .{
                .argv = argv.items,
                .environ_map = environ_map,
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
                .create_no_window = true,
            }) catch null;

            if (child) |*c| {
                const term = c.wait(io) catch std.process.Child.Term{ .unknown = 1 };
                if (term.success()) {
                    if (verifyZipArchive(io, zip_path)) |_| {
                        native_ok = true;
                    } else |_| {}
                }
            }
        } else |_| {}
    } else {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "zip", "-r", "-q", zip_path });
        try argv.appendSlice(gpa, rel_targets);

        var child = std.process.spawn(io, .{
            .argv = argv.items,
            .cwd = .{ .path = base_dir },
            .environ_map = environ_map,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch null;

        if (child) |*c| {
            const term = c.wait(io) catch std.process.Child.Term{ .unknown = 1 };
            if (term.success()) {
                if (verifyZipArchive(io, zip_path)) |_| {
                    native_ok = true;
                } else |_| {}
            }
        }
    }

    if (!native_ok) {
        try createZipPure(gpa, io, zip_path, base_dir, rel_targets);
    }

    try verifyZipArchive(io, zip_path);
}

const USER_BACKUP_CANDIDATES = [_][]const u8{
    "settings.json",
    "keybindings.json",
    "tasks.json",
    "mcp.json",
    "snippets",
};

pub fn backupIdeUserConfig(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    ide: types.IdeInstallation,
    ts_slug: []const u8,
) !?[]const u8 {
    var rel_targets: std.ArrayList([]const u8) = .empty;

    for (USER_BACKUP_CANDIDATES) |cand| {
        const abs_cand = try Dir.path.join(arena, &.{ ide.user_dir, cand });
        const st = Dir.cwd().statFile(io, abs_cand, .{ .follow_symlinks = false }) catch continue;
        if (st.kind == .file or st.kind == .directory) {
            const rel = try Dir.path.join(arena, &.{ "User", cand });
            try rel_targets.append(arena, rel);
        }
    }

    if (rel_targets.items.len == 0) {
        return null;
    }

    const zip_name = try std.fmt.allocPrint(arena, "syncide-backup-user-{s}.zip", .{ts_slug});
    const zip_path = try Dir.path.join(arena, &.{ ide.app_dir, zip_name });
    try createCompressedZip(gpa, io, environ_map, zip_path, ide.app_dir, rel_targets.items);
    return zip_path;
}

pub fn backupIdeExtensions(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    ide: types.IdeInstallation,
    ts_slug: []const u8,
) !?[]const u8 {
    const st = Dir.cwd().statFile(io, ide.extensions_dir, .{ .follow_symlinks = false }) catch return null;
    if (st.kind != .directory) {
        return null;
    }

    var dir = Dir.openDirAbsolute(io, ide.extensions_dir, .{ .iterate = true }) catch return null;
    var has_any = false;
    {
        defer dir.close(io);
        var it = dir.iterate();
        if ((it.next(io) catch null) != null) {
            has_any = true;
        }
    }
    if (!has_any) {
        return null;
    }

    const ext_base = Dir.path.basename(ide.extensions_dir);
    const zip_name = try std.fmt.allocPrint(arena, "syncide-backup-extensions-{s}.zip", .{ts_slug});
    const zip_path = try Dir.path.join(arena, &.{ ide.dot_dir, zip_name });
    try createCompressedZip(gpa, io, environ_map, zip_path, ide.dot_dir, &.{ext_base});
    return zip_path;
}
