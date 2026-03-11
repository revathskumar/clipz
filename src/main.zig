const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");

const clipz = @import("clipz");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const log = std.log.scoped(.clipz);

const Commands = enum {
    daemon,
    help,
    print,
    version,
};

const Context = struct {
    io: std.Io,
    environ: *std.process.Environ.Map,
    running: bool,
    display: *wl.Display,
    manager: *zwlr.DataControlManagerV1,
    seat: *wl.Seat,
    device: *zwlr.DataControlDeviceV1,
    registry: *wl.Registry,
    offer: ?*zwlr.DataControlOfferV1,
    mime_type: [*:0]const u8,
    history: std.ArrayList(u8),
    ally: std.mem.Allocator,
};

var ctx = Context{
    .io = undefined,
    .environ = undefined,
    .running = true,
    .display = undefined,
    .manager = undefined,
    .seat = undefined,
    .device = undefined,
    .registry = undefined,
    .offer = null,
    .mime_type = "",
    .history = .empty,
    .ally = undefined,
};

fn signalHandler(signo: std.os.linux.SIG) callconv(.c) void {
    if (signo == std.os.linux.SIG.INT) {
        teardown();
        log.info("exiting", .{});

        std.debug.print("SIGINT signal\n", .{});
        std.process.exit(0);
    }
}

fn teardown() void {
    std.debug.print("teardown called\n", .{});

    ctx.history.deinit(ctx.ally);
    ctx.manager.destroy();
    ctx.seat.destroy();
    ctx.registry.destroy();
    ctx.device.destroy();

    ctx.display.disconnect();
}

pub fn main(init: std.process.Init) anyerror!void {
    ctx.io = init.io;
    ctx.environ = init.environ_map;

    ctx.ally = init.gpa;
    ctx.mime_type = try ctx.ally.dupeZ(u8, "text/plain;charset=utf-8");
    defer ctx.ally.free(std.mem.span(ctx.mime_type));

    var sa = std.os.linux.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };

    _ = std.os.linux.sigaction(std.os.linux.SIG.INT, &sa, null);

    // var args = std.process.args();
    var args = init.minimal.args.iterate();
    var command: Commands = .help;

    while (args.next()) |arg| {
        if (std.mem.orderZ(u8, arg, "daemon") == .eq) {
            command = .daemon;
            break;
        }
        if (std.mem.orderZ(u8, arg, "help") == .eq) {
            command = .help;
            break;
        }
        if (std.mem.orderZ(u8, arg, "print") == .eq) {
            command = .print;
            break;
        }
        if (std.mem.orderZ(u8, arg, "version") == .eq) {
            command = .version;
            break;
        }
    }

    switch (command) {
        .daemon, .print => {
            log.debug("about to read history file", .{});
            _ = try clipz.readFromHistory(init.io, init.environ_map, ctx.ally, &ctx.history);

            var it = std.mem.tokenizeAny(u8, ctx.history.items, "\u{0}");

            var item_count: u32 = 0;
            while (it.next()) |_| {
                item_count += 1;
            }
            log.info("history items count : items = {} , bytes = {} \n", .{ item_count, ctx.history.items.len });
        },
        else => {},
    }

    switch (command) {
        .daemon => {
            ctx.display = try wl.Display.connect(null);
            log.debug("connected to wayland display", .{});
            const display = ctx.display;
            ctx.registry = try display.getRegistry();
            defer ctx.registry.destroy();

            ctx.registry.setListener(*Context, listener, &ctx);

            if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

            ctx.device = try ctx.manager.getDataDevice(ctx.seat);
            defer ctx.device.destroy();
            ctx.device.setListener(*Context, deviceListener, &ctx);

            if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

            while (ctx.running) {
                if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
            }
        },
        .help => {
            const help_text =
                \\Clipz : Clipboard selection history
                \\
                \\Commands:
                \\
                \\  daemon    run the clipz daemon
                \\  help      show help message
                \\  print     print the selection history
                \\  version   show version number
                \\
            ;

            const stdout: std.Io.File = .stdout();
            try stdout.writeStreamingAll(init.io, help_text);
            std.process.exit(0);
        },
        .print => {
            std.debug.print("print command : {}\n", .{command});
            try clipz.print(init.io, ctx.ally, &ctx.history);
            std.process.exit(0);
        },
        .version => {
            var stdout_buffer: [32]u8 = undefined;
            var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
            const stdout = &stdout_writer.interface;

            try stdout.print("Clipz : v{s} \n", .{build_options.version});
            try stdout.flush();
            std.process.exit(0);
        },
    }
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
                // receive_data(device, primary_selection.id, context) catch {};
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

fn replaceNewlines(ret: []const u8, buf: []u8) []const u8 {
    var i: usize = 0;
    for (ret) |byte| {
        if (byte == '\n' or byte == '\r') {
            // buf[i] = 0xA0;
            // buf[i] = '\u{00A0}';
            buf[i] = 0xC2;

            i += 1;
            buf[i] = 0xA0;
        } else {
            buf[i] = byte;
        }
        i += 1;
    }
    return buf[0..i];
}

fn receive_data(_: *zwlr.DataControlDeviceV1, offer: ?*zwlr.DataControlOfferV1, context: *Context) !void {
    var buf: [4068]u8 = undefined;
    var ret_buf: [4068]u8 = undefined;

    var pipe_fds: [2]i32 = undefined;
    _ = std.os.linux.pipe(&pipe_fds);
    defer _ = std.os.linux.close(pipe_fds[0]);

    offer.?.receive(std.mem.span(context.mime_type), pipe_fds[1]);
    _ = context.display.flush();
    _ = std.os.linux.close(pipe_fds[1]);

    const msg = readMessage(pipe_fds[0], &buf);
    const ret = replaceNewlines(msg, &ret_buf);

    if (ret.len > 0) {
        try context.history.insert(context.ally, 0, 0);
        try context.history.insertSlice(context.ally, 0, ret);
        var it = std.mem.tokenizeAny(u8, context.history.items, "\u{0}");
        var item_count: u32 = 0;
        while (it.next()) |_| {
            item_count += 1;
        }

        log.info("receive_data history items count : items = {}, bytes = {} \n", .{ item_count, context.history.items.len });
        try clipz.writeToHistory(context.io, context.environ, context.ally, context.history.items);
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
