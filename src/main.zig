const std = @import("std");
const posix = std.posix;

const clipz = @import("clipz");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const log = std.log.scoped(.clipz);

const Context = struct {
    running: bool,
    display: *wl.Display,
    manager: *zwlr.DataControlManagerV1,
    seat: *wl.Seat,
    offer: ?*zwlr.DataControlOfferV1,
    mime_type: [*:0]const u8,
    history: std.ArrayList(u8),
    ally: std.mem.Allocator,
};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) posix.exit(1);
    var ally = gpa.allocator();
    const mime_type: [*:0]const u8 = try ally.dupeZ(u8, "text/plain;charset=utf-8");
    defer ally.free(std.mem.span(mime_type));

    var history: std.ArrayList(u8) = .empty;
    _ = clipz.readFromHistory(ally, &history) catch {};
    defer history.deinit(ally);

    var args = std.process.args();
    var command: []const u8 = "";

    while (args.next()) |arg| {
        std.debug.print("{s}\n", .{arg});
        if (std.mem.orderZ(u8, arg, "print") == .eq) {
            command = arg;
            break;
        }
    }

    if (std.mem.order(u8, command, "print") == .eq) {
        std.debug.print("print command : {s}\n", .{command});
        try clipz.print(ally, &history);
        posix.exit(0);
    }

    var context = Context{
        .running = true,
        .display = undefined,
        .manager = undefined,
        .seat = undefined,
        .offer = null,
        .mime_type = mime_type,
        .history = history,
        .ally = ally,
    };

    context.display = try wl.Display.connect(null);
    log.debug("connected to wayland display", .{});
    const display = context.display;
    const registry = try display.getRegistry();

    registry.setListener(*Context, listener, &context);

    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const device = try context.manager.getDataDevice(context.seat);
    defer device.destroy();
    device.setListener(*Context, deviceListener, &context);

    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    while (context.running) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    }

    // context.display.disconnect();
}

fn deviceListener(device: *zwlr.DataControlDeviceV1, event: zwlr.DataControlDeviceV1.Event, context: *Context) void {
    switch (event) {
        .data_offer => |offer| {
            offer.id.setListener(*Context, dataControlOfferListener, context);
        },
        .selection => |selection| {
            if (context.offer != null and context.offer == selection.id) {
                receive_data(device, selection.id, context) catch {};
                context.offer = null;
            }
        },
        .finished => {
            device.destroy();
        },
        .primary_selection => |primary_selection| {
            if (context.offer != null and context.offer == primary_selection.id) {
                receive_data(device, primary_selection.id, context) catch {};
                context.offer = null;
            }
        },
    }
}

fn dataControlOfferListener(offer: *zwlr.DataControlOfferV1, event: zwlr.DataControlOfferV1.Event, context: *Context) void {
    switch (event) {
        .offer => |off| {
            if (context.offer != null) {
                return;
            }

            if (std.mem.orderZ(u8, off.mime_type, std.mem.span(context.mime_type)) != .eq) {
                return;
            }

            context.offer = offer;
        },
    }
}

fn readMessage(socket: posix.socket_t, buf: []u8) []const u8 {
    var pos: usize = 0;
    while (true) {
        const n = posix.read(socket, buf[pos..]) catch 0;

        if (n <= 0) {
            return buf[0..pos];
        }
        const end = pos + n;
        const index = std.mem.indexOfScalar(u8, buf[pos..end], 0) orelse {
            pos = end;
            continue;
        };
        return buf[0 .. pos + index];
    }
}

fn receive_data(_: *zwlr.DataControlDeviceV1, offer: ?*zwlr.DataControlOfferV1, context: *Context) !void {
    var buf: [4068]u8 = undefined;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);

    offer.?.receive(std.mem.span(context.mime_type), pipe_fds[1]);
    _ = context.display.flush();
    posix.close(pipe_fds[1]);

    const ret = readMessage(pipe_fds[0], &buf);

    if (ret.len > 0) {
        try context.history.insert(context.ally, 0, 0);
        try context.history.insertSlice(context.ally, 0, ret);
        var it = std.mem.tokenizeAny(u8, context.history.items, "\u{0}");
        var item_count: u32 = 0;
        while (it.next()) |_| {
            item_count += 1;
        }

        log.info("history items count : items = {}, bytes = {} \n", .{ item_count, context.history.items.len });
        try clipz.writeToHistory(context.ally, context.history.items);

        try stdout.flush();
    }

    offer.?.destroy();
}

fn listener(registry: *wl.Registry, event: wl.Registry.Event, context: *Context) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                context.seat = registry.bind(global.name, wl.Seat, 1) catch return;
                context.seat.setListener(*Context, seatListener, context);
            } else if (std.mem.orderZ(u8, global.interface, zwlr.DataControlManagerV1.interface.name) == .eq) {
                context.manager = registry.bind(global.name, zwlr.DataControlManagerV1, 1) catch return;
            }
        },
        .global_remove => {},
    }
}

fn seatListener(_: *wl.Seat, event: wl.Seat.Event, _: *Context) void {
    switch (event) {
        .capabilities => |data| {
            std.debug.print("Seat capabilities\n  Pointer {}\n  Keyboard {}\n  Touch {}\n", .{
                data.capabilities.pointer,
                data.capabilities.keyboard,
                data.capabilities.touch,
            });
        },
        .name => {},
    }
}
