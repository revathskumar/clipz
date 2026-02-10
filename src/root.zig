//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

const known_folders = @import("known_folders");

const file_name = "clipz_history.txt";

pub fn print(allocator: std.mem.Allocator, history: *std.ArrayList(u8)) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var history_with_newline: std.ArrayList(u8) = .empty;
    defer history_with_newline.deinit(allocator);

    const buf = try allocator.alloc(u8, history.items.len);
    defer allocator.free(buf);

    _ = std.mem.replace(u8, history.items, "\u{0}", "\n", buf);
    try stdout.print("{s}", .{buf});
    try stdout.flush();
}

pub fn writeToHistory(allocator: std.mem.Allocator, content: []const u8) !void {
    const cache_path = try known_folders.getPath(allocator, known_folders.KnownFolder.cache) orelse return;
    defer allocator.free(cache_path);

    const full_path = try std.fs.path.join(allocator, &[_][]const u8{ cache_path, file_name });
    defer allocator.free(full_path);

    const file = try std.fs.cwd().createFile(
        full_path,
        .{ .read = true, .truncate = true },
    );
    defer file.close();

    try file.writeAll(content);
}

pub fn readFromHistory(allocator: std.mem.Allocator, history: *std.ArrayList(u8)) !void {
    const cache_path = try known_folders.getPath(allocator, known_folders.KnownFolder.cache) orelse return;
    defer allocator.free(cache_path);

    const full_path = try std.fs.path.join(allocator, &[_][]const u8{ cache_path, file_name });
    defer allocator.free(full_path);

    var file = try std.fs.cwd().openFile(full_path, .{});
    defer file.close();

    const file_len = (try file.stat()).size;

    const buf = try allocator.alloc(u8, file_len);
    defer allocator.free(buf);

    _ = try file.readAll(buf);

    try history.appendSlice(allocator, buf);
}
