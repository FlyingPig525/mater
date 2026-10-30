const std = @import("std");
const HttpClient = @import("HttpClient.zig");
const Error = @import("Error.zig");
const vaxis = @import("vaxis");
const Color = vaxis.Color;
const LabelledWindow = @import("LabelledWindow.zig");
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

const WellKnownClientInfo = struct {
    homeserver: []const u8,
    identity_server: ?[]const u8,

    pub fn init(arena: *std.heap.ArenaAllocator, parsed: *std.json.Value) !std.json.Parsed(WellKnownClientInfo) {
        if (parsed.* != .object) return error.MissingRequiredField;
        const obj = parsed.object;
        const h = obj.get("m.homeserver") orelse return error.MissingRequiredField;
        if (h != .object) return error.InvalidType;
        const homeserver = h.object.get("base_url") orelse return error.MissingRequiredField;
        if (homeserver != .string) return error.InvalidType;
        const i = obj.get("m.identity_server");
        var identity: ?[]const u8 = null;
        if (i) |id| {
            const json_id = id.object.get("base_url") orelse return error.MissingRequiredField;
            if (json_id != .string) return error.InvalidType;
            identity = json_id.string;
        }

        return .{
            .arena = arena,
            .value = .{
                .homeserver = homeserver.string,
                .identity_server = identity,
            },
        };
    }
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
    login: LoginScreen.LoginEvent,
};

const Queue = @FieldType(vaxis.Loop(Event), "queue");

fn addToQueue(q: *Queue, gpa: std.mem.Allocator, io: std.Io) !void {
    const res = try getVoidarcMatrixServer(gpa, io);
    errdefer res.deinit();
    try q.push(.{ .get = res });
}

const widgets = vaxis.widgets;

pub fn Focus(comptime T: type) type {
    return struct {
        focused: bool = false,
        widget: T,

        pub fn init(widget: T) @This() {
            return .{
                .widget = widget,
            };
        }
    };
}

const MatrixId = struct {
    username: []const u8,
    homeserver: std.Uri,
    gpa: std.mem.Allocator,

    const max_len = 255;
    const ParseError = error{ InvalidFormat, InvalidLength };
    pub fn parse(gpa: std.mem.Allocator, str: []const u8) (std.mem.Allocator.Error || ParseError)!MatrixId {
        // the smallest possibly valid id would be a:a, so 3 chars
        if (str.len > max_len or str.len <= 3) return ParseError.InvalidLength;
        const split_n = std.mem.cut(u8, if (str[0] == '@') str[1..] else str, ":");
        if (split_n == null) return ParseError.InvalidFormat;
        const split = split_n.?;
        if (split.@"0".len == 0) return ParseError.InvalidFormat;
        if (std.mem.findNone(u8, split.@"0", "abcdefghijklmnopqrstuvwxyz1234567890._=-/+") != null) return ParseError.InvalidFormat;
        const homeserver = try std.mem.concat(gpa, u8, &.{ "https://", split.@"1" });
        errdefer gpa.free(homeserver);
        const uri = std.Uri.parse(homeserver) catch return ParseError.InvalidFormat;
        return .{
            .username = try gpa.dupe(u8, split.@"0"),
            .homeserver = uri,
            .gpa = gpa,
        };
    }

    pub fn deinit(this: MatrixId) void {
        this.gpa.free(this.username);
    }
};

const LoginScreen = struct {
    username: Focus(widgets.TextInput),
    password: Focus(widgets.TextInput),
    scheme: *const ColorScheme,
    io: std.Io,
    gpa: std.mem.Allocator,
    queue: *Queue,
    req: ?std.Io.Future(void) = null,
    status: Status = .awaiting_submission,
    locked: bool = false,

    pub const LoginEvent = union(enum) {
        status: Status,
    };

    pub const Status = union(enum) {
        awaiting_submission,
        parsing,
        requesting,
        checking_version,
        // should always be used with @errorName so i dont have to do memory management
        err: []const u8,
        network_err: std.json.Parsed(Error),

        const awaiting_text: []const u8 = "[s]ubmit";
        const parsing_text = "Parsing ID";
        const requesting_text = "Requesting client details";
        const checking_text = "Checking homeserver versions";
        pub fn text(this: Status) []const u8 {
            return switch (this) {
                .awaiting_submission => awaiting_text,
                .parsing => parsing_text,
                .requesting => requesting_text,
                .checking_version => checking_text,
                .err => |str| str,
                .network_err => |err| err.value.err_code_str,
            };
        }

        pub fn deinit(this: Status) void {
            if (this == .network_err) {
                this.network_err.deinit();
            }
        }
    };
    pub fn init(gpa: std.mem.Allocator, scheme: *const ColorScheme, io: std.Io, queue: *Queue) !LoginScreen {
        return .{
            .username = .init(.init(gpa)),
            .password = .init(.init(gpa)),
            .gpa = gpa,
            .scheme = scheme,
            .io = io,
            .queue = queue,
        };
    }

    pub fn deinit(this: *LoginScreen) void {
        if (this.req) |*req| {
            req.cancel(this.io);
        }
        this.username.widget.deinit();
        this.password.widget.deinit();
    }

    pub fn focused(this: *const LoginScreen) bool {
        return this.username.focused or this.password.focused;
    }

    pub fn update(this: *LoginScreen, e: Event) !bool {
        switch (e) {
            .key_press => |key| {
                if (key.matchExact(vaxis.Key.escape, .{})) {
                    this.username.focused = false;
                    this.password.focused = false;
                }
                if (!this.locked) {
                    if (this.username.focused) {
                        try this.username.widget.update(.{ .key_press = key });
                        this.status.deinit();
                        this.status = .awaiting_submission;
                    } else if (this.password.focused) {
                        try this.password.widget.update(.{ .key_press = key });
                        this.status.deinit();
                        this.status = .awaiting_submission;
                    }
                }
                if (key.matchExact('q', .{}) and !this.focused()) {
                    return false;
                } else if (key.matchExact('u', .{})) {
                    this.username.focused = true;
                } else if (key.matchExact('p', .{})) {
                    this.password.focused = true;
                } else if (key.matchExact('s', .{}) and this.status == .awaiting_submission) {
                    if (this.req) |*req| {
                        req.cancel(this.io);
                    }
                    this.status = .parsing;
                    this.locked = true;
                    this.req = this.io.async(submitWrapper, .{ this.queue, this.io, this.gpa, try this.username.widget.toOwnedContents(this.gpa), try this.password.widget.toOwnedContents(this.gpa) });
                }
            },
            .login => |lE| {
                switch (lE) {
                    .status => |status| {
                        this.status = status;
                        if (status == .err or status == .network_err) {
                            this.locked = false;
                        }
                    },
                }
            },
            else => {},
        }

        return true;
    }

    fn submitWrapper(q: *Queue, io: std.Io, gpa: std.mem.Allocator, username: []const u8, password: []const u8) void {
        submit(q, io, gpa, username, password) catch |err| {
            q.push(.{ .login = .{ .status = .{ .err = @errorName(err) } } }) catch return;
        };
    }
    fn submit(q: *Queue, io: std.Io, gpa: std.mem.Allocator, username: []const u8, password: []const u8) !void {
        defer {
            gpa.free(username);
            gpa.free(password);
        }
        const parsed = try MatrixId.parse(gpa, username);
        defer parsed.deinit();

        q.push(.{ .login = .{ .status = .requesting } }) catch return;
        var client = try HttpClient.init(gpa, io);
        defer client.deinit();

        const well_known_uri = try std.fmt.allocPrint(gpa, "{f}/.well-known/matrix/client", .{ parsed.homeserver });
        defer gpa.free(well_known_uri);
        const client_info = try client.requestJsonBodyless(WellKnownClientInfo, .GET, std.Uri.parse(well_known_uri) catch return, true);
        switch (client_info) {
            .success => |info| {
                defer client_info.deinit();
                std.log.debug("{s}", .{ info.value.homeserver });
            },
            // err deinit happens when status get overridden
            .err => |err| {
                try q.push(.{ .login = .{ .status = .{ .network_err = err } } });
            },
        }
    }

    pub fn draw(this: *LoginScreen, _: std.mem.Allocator, win: vaxis.Window) !void {
        if (win.height < 7) return error.WindowTooSmall;
        const spacing = @divFloor((win.height - 6), 3);
        var user_win = LabelledWindow.init("[u]sername (fully-qualified)", if (this.username.focused) this.scheme.cyan else this.scheme.fg, win, .{
            .x_off = 1,
            .y_off = spacing,
            .width = win.width - 2,
            .height = 3,
            .border = .{
                .where = .all,
                .style = .{
                    .fg = if (this.username.focused) this.scheme.cyan else this.scheme.grey,
                },
            },
        });
        const pass_win = LabelledWindow.init("[p]assword", if (this.password.focused) this.scheme.cyan else this.scheme.fg, win, .{
            .x_off = 1,
            .y_off = 3 + (spacing * 2),
            .width = win.width - 2,
            .height = 3,
            .border = .{
                .where = .all,
                .style = .{
                    .fg = if (this.password.focused) this.scheme.cyan else this.scheme.grey,
                },
            },
        });

        this.username.widget.draw(user_win);
        this.password.widget.draw(pass_win);
        if (this.username.focused) {
            user_win.showCursor(this.username.widget.prev_cursor_idx, 0);
        }

        if (!this.username.focused and !this.password.focused) {
            win.hideCursor();
        }

        const text = this.status.text();
        const info_win = win.child(.{
            .x_off = (win.width / 2) - @as(u16, @intCast(text.len / 2)),
            .y_off = 5 + (spacing * 3),
            .width = win.width,
            .height = 1,
        });

        _ = info_win.printSegment(
            .{
                .text = text,
                .style = .{ .fg = if (this.status != .err) this.scheme.green else this.scheme.red },
            },
            .{},
        );
    }
};

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

    var login = try LoginScreen.init(gpa, &scheme, io, &loop.queue);
    defer login.deinit();

    while (true) {
        const e = try loop.nextEvent();
        _ = arena.reset(.free_all);
        if (e == .winsize) {
            try vx.resize(gpa, tty.writer(), e.winsize);
        }

        const win = vx.window();
        win.clear();

        _ = try login.update(e);
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
                    if (key.matchExact('q', .{}) and !login.focused()) {
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

        const child = LabelledWindow.init("Login", scheme.fg, win, .{
            .height = @min(win.height, 11),
            .width = @min(win.width, 60),
            .x_off = (win.width / 2) - (@min(win.width, 60) / 2),
            .y_off = (win.height / 2) - (@min(win.height, 11) / 2),
            .border = .{ .where = .all },
        });

        try login.draw(arena.allocator(), child);

        try vx.render(tty.writer());
    }
}
