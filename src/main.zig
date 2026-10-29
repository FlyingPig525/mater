const std = @import("std");
const HttpClient = @import("HttpClient.zig");
const vaxis = @import("vaxis");
const Color = vaxis.Color;
const v = vaxis.vxfw;
const redir_buf_size = 8000;

const ColorScheme = struct {
    black: Color = .rgbFromUint(0x0e1013),
    bg0: Color = .rgbFromUint(0x1f2329),
    bg1: Color = .rgbFromUint(0x282c34),
    bg2: Color = .rgbFromUint(0x30363f),
    bg3: Color = .rgbFromUint(0x323641),
    bg_d: Color = .rgbFromUint(0x181b20),
    bg_blue: Color = .rgbFromUint(0x61afef),
    bg_yellow: Color = .rgbFromUint(0xe8c88c),
    fg: Color = .rgbFromUint(0xa0a8b7),
    purple: Color = .rgbFromUint(0xbf68d9),
    green: Color = .rgbFromUint(0x8ebd6b),
    orange: Color = .rgbFromUint(0xcc9057),
    blue: Color = .rgbFromUint(0x4fa6ed),
    yellow: Color = .rgbFromUint(0xe2b86b),
    cyan: Color = .rgbFromUint(0x48b0bd),
    red: Color = .rgbFromUint(0xe55561),
    grey: Color = .rgbFromUint(0x535965),
    light_grey: Color = .rgbFromUint(0x7a818e),
    dark_cyan: Color = .rgbFromUint(0x266269),
    dark_red: Color = .rgbFromUint(0x8b3434),
    dark_yellow: Color = .rgbFromUint(0x835d1a),
    dark_purple: Color = .rgbFromUint(0x7e3992),
};

const A = struct {
    server: []const u8,

    pub fn init(arena: *std.heap.ArenaAllocator, parsed: *std.json.Value) !std.json.Parsed(A) {
        return .{
            .arena = arena,
            .value = .{
                .server = (parsed.object.get("m.server") orelse return error.MissingRequiredField).string,
            },
        };
    }

    pub fn deinit(this: A, gpa: std.mem.Allocator) void {
        gpa.free(this.server);
    }
};

fn getVoidarcMatrixServer(gpa: std.mem.Allocator, io: std.Io) !HttpClient.Response(A) {
    var client = try HttpClient.init(gpa, io);
    defer client.deinit();
    const res = try client.requestJsonBodyless(A, .GET, try .parse("https://unredacted.org/.well-known/matrix/server"), true);
    return res;
}
test "get voidarc well-known server" {
    const res = try getVoidarcMatrixServer(std.testing.allocator, std.testing.io);
    try std.testing.expect(res == .success);
    switch (res) {
        .success => |a| {
            std.log.debug("{s}", .{a.value.server});
            try std.testing.expectEqualSlices(u8, "matrix.voidarc.co.uk:443", a.value.server);
        },
        .err => |err| {
            std.log.debug("{s}", .{err.value.err});
        },
    }
}

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    get: HttpClient.Response(A),
};

const Queue = @FieldType(vaxis.Loop(Event), "queue");

fn addToQueue(q: *Queue, gpa: std.mem.Allocator, io: std.Io) !void {
    const res = try getVoidarcMatrixServer(gpa, io);
    errdefer res.deinit();
    try q.push(.{ .get = res });
}


pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var buf: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &buf);
    defer tty.deinit();

    var vx = try vaxis.init(io, gpa, init.environ_map, .{});
    defer vx.deinit(gpa, tty.writer());

    var loop = vaxis.Loop(Event).init(io, &tty, &vx);

    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());

    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    const scheme: ColorScheme = .{};

    var input = vaxis.widgets.TextInput.init(gpa);
    defer input.deinit();
    var input_focused = false;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var fut = io.async(addToQueue, .{ &loop.queue, gpa, io });
    defer fut.cancel(io) catch {};


    while (true) {
        const e = try loop.nextEvent();
        _ = arena.reset(.free_all);
        if (e == .winsize) {
            try vx.resize(gpa, tty.writer(), e.winsize);
        }

        const win = vx.window();
        win.clear();

        switch (e) {
            .key_press => |key| {
                if (input_focused) blk: {
                    if (key.matchExact(vaxis.Key.escape, .{})) {
                        input_focused = false;
                        win.hideCursor();
                        break :blk;
                    }
                    try input.update(.{ .key_press = key });
                } else {
                    if (key.matchExact('q', .{})) {
                        break;
                    } else if (key.matchExact('i', .{})) {
                        input_focused = true;
                    }
                }
            },
            .get => |res| {
                defer res.deinit();
                switch (res) {
                    .success => |a| {
                        input.clearRetainingCapacity();
                        try input.insertSliceAtCursor(a.value.server);
                        vx.queueRefresh();
                    },
                    else => {},
                }
            },
            else => {},
        }

        const child = win.child(.{
            .x_off = (win.width / 2) - 15,
            .y_off = (win.height / 2) - 3,
            .width = 30,
            .height = 3,
            .border = .{
                .where = .all,
                .style = .{
                    .fg = if (input_focused) scheme.cyan else scheme.grey,
                },
            },
        });

        input.draw(child);
        if (!input_focused) {
            win.hideCursor();
        }

        try vx.render(tty.writer());
    }
}
