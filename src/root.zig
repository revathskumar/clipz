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
    var stdout_buffer: [4096]u8 = undefined;

    const buf = try allocator.alloc(u8, history.items.len);
    defer allocator.free(buf);

    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    _ = std.mem.replace(u8, history.items, "\u{0}", "\n", buf);

    try stdout_writer.print("{s}", .{buf});
    try stdout_writer.flush();
}

pub fn writeToHistory(io: std.Io, environ: *std.process.Environ.Map, allocator: std.mem.Allocator, content: []const u8) !void {
    const full_path = try getCacheFullPath(io, environ, allocator, null);

    // std.debug.print("writeToHistory full_path : {s}\n", .{full_path});
    // std.debug.print("writeToHistory content : {s}\n", .{content});
    defer allocator.free(full_path);

    const dir = std.Io.Dir.cwd();
    const file = try dir.createFile(
        io,
        full_path,
        .{ .read = true, .truncate = true },
    );
    defer file.close(io);
    var buffer: [4096]u8 = undefined;

    var f_writer = file.writer(io, &buffer);
    const writer = &f_writer.interface;

    try writer.print("{s}", .{content});
    try writer.flush();
}

pub fn readFromHistory(io: std.Io, environ: *std.process.Environ.Map, allocator: std.mem.Allocator, history: *std.ArrayList(u8)) !void {
    const full_path = try getCacheFullPath(io, environ, allocator, null);

    std.debug.print("readFromHistory full_path : {s}\n", .{full_path});
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
