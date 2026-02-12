//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

const known_folders = @import("known_folders");

fn getCacheFullPath(io: std.Io, environ: *std.process.Environ.Map, allocator: std.mem.Allocator, file_name: ?[]const u8) ![]const u8 {
    const file = file_name orelse "clipz_history.txt";
    const cache_path = try known_folders.getPath(io, allocator, environ.*, known_folders.KnownFolder.cache) orelse return "";
    defer allocator.free(cache_path);

    return try std.fs.path.join(allocator, &[_][]const u8{ cache_path, file });
}

pub fn print(io: std.Io, allocator: std.mem.Allocator, history: *std.ArrayList(u8)) !void {
    const buf = try allocator.alloc(u8, history.items.len);
    defer allocator.free(buf);

    const stdout: std.Io.File = .stdout();
    _ = std.mem.replace(u8, history.items, "\u{0}", "\n", buf);

    try stdout.writeStreamingAll(io, buf);
}

pub fn writeToHistory(io: std.Io, environ: *std.process.Environ.Map, allocator: std.mem.Allocator, content: []const u8) !void {
    const full_path = try getCacheFullPath(io, environ, allocator, null);
    defer allocator.free(full_path);

    const dir = std.Io.Dir.cwd();
    const file = try dir.createFile(
        io,
        full_path,
        .{ .read = true, .truncate = true },
    );
    defer file.close(io);
    var buffer: [1024]u8 = undefined;

    var f_writer = file.writer(io, &buffer);
    const writer = &f_writer.interface;

    try writer.writeAll(content);
}

pub fn readFromHistory(io: std.Io, environ: *std.process.Environ.Map, allocator: std.mem.Allocator, history: *std.ArrayList(u8)) !void {
    const full_path = try getCacheFullPath(io, environ, allocator, null);
    defer allocator.free(full_path);

    const dir = std.Io.Dir.cwd();
    const file = try dir.openFile(io, full_path, .{});
    defer file.close(io);

    const file_len = (try file.stat(io)).size;

    const buf = try allocator.alloc(u8, file_len);
    defer allocator.free(buf);

    var f_reader = file.reader(io, buf);
    const reader = &f_reader.interface;
    const bytes = try reader.readAlloc(allocator, file_len);
    defer allocator.free(bytes);

    try history.appendSlice(allocator, bytes);
}
