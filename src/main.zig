const std = @import("std");
const HttpClient = @import("HttpClient.zig");
const Error = @import("Error.zig");
const vaxis = @import("vaxis");
const Color = vaxis.Color;
const LabelledWindow = @import("LabelledWindow.zig");
const v = vaxis.vxfw;
const Parsed = std.json.Parsed;
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

    pub fn parse(arena: *std.heap.ArenaAllocator, parsed: *std.json.Value) !Parsed(WellKnownClientInfo) {
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

    pub fn clone(this: WellKnownClientInfo, gpa: std.mem.Allocator) !WellKnownClientInfo {
        return .{
            .homeserver = try gpa.dupe(u8, this.homeserver),
            .identity_server = if (this.identity_server) |i| try gpa.dupe(u8, i) else null,
        };
    }

    pub fn stringify(this: WellKnownClientInfo, gpa: std.mem.Allocator) !Parsed(std.json.Value) {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        var value = std.json.Value{.object = .empty};
        var hs_value = std.json.Value{.object = .empty};
        try hs_value.object.put(alloc, "base_url", .{ .string = try alloc.dupe(u8, this.homeserver) });
        try value.object.put(alloc, "m.homeserver", hs_value);
        if (this.identity_server) |identity| {
            try value.object.put(alloc, "m.identity", .{ .string = try alloc.dupe(u8, identity) });
        }

        return .{
            .arena = arena,
            .value = value,
        };
    }
};

const LoginFlows = struct {
    flows: []Flow,

    pub fn parse(arena: *std.heap.ArenaAllocator, parsed: *std.json.Value) !Parsed(LoginFlows) {
        if (parsed.* != .object) return error.MissingRequiredField;
        const obj = parsed.object;
        const flows_arr = obj.get("flows") orelse return error.MissingRequiredField;
        if (flows_arr != .array) return error.MissingRequiredField;
        const flows = try arena.allocator().alloc(Flow, flows_arr.array.items.len);
        for (0..flows.len) |i| {
            flows[i] = try Flow.init(flows_arr.array.items[i]);
        }
        return .{
            .arena = arena,
            .value = .{
                .flows = flows,
            },
        };
    }

    pub fn clone(this: LoginFlows, gpa: std.mem.Allocator) !LoginFlows {
        return .{
            .flows = try gpa.dupe(Flow, this.flows),
        };
    }

    pub const Flow = struct {
        t: Type,
        get_login_token: bool = false,

        pub const Type = enum {
            password,
            recaptcha,
            sso,
            email,
            msisdn,
            dummy,
            terms,
            oauth,
            application_service,

            pub fn fromStr(str: []const u8) ?Type {
                if (std.mem.eql(u8, str, "m.login.password")) {
                    return .password;
                } else if (std.mem.eql(u8, str, "m.login.recaptcha")) {
                    return .recaptcha;
                } else if (std.mem.eql(u8, str, "m.login.sso")) {
                    return .sso;
                } else if (std.mem.eql(u8, str, "m.login.email.identity")) {
                    return .email;
                } else if (std.mem.eql(u8, str, "m.login.msisdn")) {
                    return .msisdn;
                } else if (std.mem.eql(u8, str, "m.login.dummy")) {
                    return .dummy;
                } else if (std.mem.eql(u8, str, "m.login.terms")) {
                    return .terms;
                } else if (std.mem.eql(u8, str, "m.oauth")) {
                    return .oauth;
                } else if (std.mem.eql(u8, str, "m.login.application_service")) {
                    return .application_service;
                }
                return null;
            }

            pub fn supported(this: Type) bool {
                return switch (this) {
                    .password => true,
                    else => false,
                };
            }
        };

        pub fn init(parsed: std.json.Value) !Flow {
            if (parsed != .object) return error.MissingRequiredField;
            const obj = parsed.object;
            const type_str = obj.get("type") orelse return error.MissingRequiredField;
            if (type_str != .string) return error.MissingRequiredField;
            const t = Type.fromStr(type_str.string) orelse return error.MissingRequiredField;
            const token_v = obj.get("get_login_token");
            const token = if (token_v != null and token_v.? == .bool) token_v.?.bool else false;
            return .{
                .t = t,
                .get_login_token = token,
            };
        }
    };
};

const SupportedVersions = struct {
    versions: []const MatrixVersion,
    unstable_features: ?[][]const u8,

    pub fn stringify(this: SupportedVersions, gpa: std.mem.Allocator) !Parsed(std.json.Value) {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        var value = std.json.Value{ .object = .empty };
        var versions = std.array_list.Managed(std.json.Value).init(alloc);
        for (this.versions) |version| {
            try versions.append(.{ .string = try version.toString(alloc) });
        }
        try value.object.put(alloc, "versions", .{ .array = versions });
        if (this.unstable_features) |unstable| {
            var map = std.array_hash_map.String(std.json.Value).empty;
            for (unstable) |feature| {
                try map.put(alloc, feature, .{ .bool = true });
            }
            try value.object.put(alloc, "unstable_features", .{ .object = map });
        }

        return .{
            .arena = arena,
            .value = value,
        };
    }
    // needed because of unstable_features
    pub fn parse(arena: *std.heap.ArenaAllocator, parsed: *std.json.Value) !Parsed(SupportedVersions) {
        if (parsed.* != .object) return error.MissingRequiredField;
        const obj = parsed.object;
        const versions = obj.get("versions") orelse return error.MissingRequiredField;
        if (versions != .array) return error.MissingRequiredField;
        const arr = try arena.allocator().alloc(MatrixVersion, versions.array.items.len);
        for (versions.array.items, 0..) |value, i| {
            if (value != .string) return error.MissingRequiredField;
            arr[i] = try .parse(value.string);
        }
        var unstable: ?[][]const u8 = undefined;
        if (obj.get("unstable_features")) |u| {
            if (u != .object) return error.MissingRequiredField;
            unstable = try arena.allocator().dupe([]const u8, u.object.keys());
            var iter = u.object.iterator();
            var i: usize = 0;
            while (iter.next()) |entry| : (i += 1) {
                if (entry.value_ptr.bool) {
                    unstable.?[i] = try arena.allocator().dupe(u8, entry.key_ptr.*);
                }
            }
        }

        return .{
            .arena = arena,
            .value = .{
                .versions = arr,
                .unstable_features = unstable,
            },
        };
    }

    pub fn clone(this: SupportedVersions, gpa: std.mem.Allocator) !SupportedVersions {
        const versions = try gpa.dupe(MatrixVersion, this.versions);
        var unstable: ?[][]const u8 = null;
        if (this.unstable_features) |features| {
            unstable = try gpa.alloc([]const u8, features.len);
            for (features, 0..) |feature, i| {
                unstable.?[i] = try gpa.dupe(u8, feature);
            }
        }

        return .{
            .versions = versions,
            .unstable_features = unstable,
        };
    }
};
const A = struct {
    server: []const u8,

    pub fn parse(arena: *std.heap.ArenaAllocator, parsed: *std.json.Value) !Parsed(A) {
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

// fn getVoidarcMatrixServer(gpa: std.mem.Allocator, io: std.Io) !HttpClient.Response(A) {
//     var client = HttpClient.init(gpa, io);
//     defer client.deinit();
//     const res = try client.requestJsonBodyless(A, .GET, try .parse("https://unredacted.org/.well-known/matrix/server"), true);
//     return res;
// }
// test "get voidarc well-known server" {
//     const res = try getVoidarcMatrixServer(std.testing.allocator, std.testing.io);
//     defer res.deinit();
//     try std.testing.expect(res == .success);
//     switch (res) {
//         .success => |a| {
//             std.log.debug("{s}", .{a.value.server});
//             try std.testing.expectEqualSlices(u8, "matrix.unredacted.org:8448", a.value.server);
//         },
//         .err => |err| {
//             std.log.debug("{s}", .{err.value.err});
//         },
//     }
// }

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    get: HttpClient.Response(A),
    login: LoginScreen.LoginEvent,
};

const Queue = @FieldType(vaxis.Loop(Event), "queue");

// fn addToQueue(q: *Queue, gpa: std.mem.Allocator, io: std.Io) !void {
//     const res = try getVoidarcMatrixServer(gpa, io);
//     errdefer res.deinit();
//     try q.push(.{ .get = res });
// }

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
        pub fn initFocused(widget: T) @This() {
            return .{
                .widget = widget,
                .focused = true,
            };
        }
    };
}

const Identifier = union(enum) {
    const user_str = "m.id.user";
    const thirdparty_str = "m.id.thirdparty";
    const phone_str = "m.id.phone";
    user: struct {
        user: []const u8,
    },
    thirdparty: struct {
        medium: []const u8,
        address: []const u8,
    },
    phone: struct {
        country: [2]u8,
        phone: []const u8,
    },

    pub fn stringify(this: Identifier, gpa: std.mem.Allocator) !Parsed(std.json.Value) {
        var arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        var value = std.json.Value{ .object = try .init(arena.allocator(), &.{}, &.{}) };
        switch (this) {
            .user => |u| {
                try value.object.put(arena.allocator(), "type", .{ .string = user_str });
                try value.object.put(arena.allocator(), "user", .{ .string = try arena.allocator().dupe(u8, u.user) });
            },
            .thirdparty => |t| {
                try value.object.put(arena.allocator(), "type", .{ .string = thirdparty_str });
                try value.object.put(arena.allocator(), "medium", .{ .string = try arena.allocator().dupe(u8, t.medium) });
                try value.object.put(arena.allocator(), "address", .{ .string = try arena.allocator().dupe(u8, t.address) });
            },
            .phone => |p| {
                try value.object.put(arena.allocator(), "type", .{ .string = phone_str });
                try value.object.put(arena.allocator(), "country", .{ .string = try arena.allocator().dupe(u8, &p.country) });
                try value.object.put(arena.allocator(), "phone", .{ .string = try arena.allocator().dupe(u8, p.phone) });
            },
        }
        return .{
            .arena = arena,
            .value = value,
        };
    }

    pub fn deinit(this: Identifier, gpa: std.mem.Allocator) void {
        switch (this) {
            .user => |u| gpa.free(u.user),
            .thirdparty => |t| {
                gpa.free(t.medium);
                gpa.free(t.address);
            },
            .phone => |p| {
                gpa.free(p.phone);
            },
        }
    }
};

const MatrixId = struct {
    username: []const u8,
    homeserver: std.Uri,
    // uris require their original string that was parsed to live as long as the uri lives >:(
    homeserver_string: []const u8,
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
            .homeserver_string = homeserver,
            .gpa = gpa,
        };
    }

    pub fn identifier(this: MatrixId, gpa: std.mem.Allocator) !Identifier {
        return .{ .user = .{
            .user = try gpa.dupe(u8, this.username),
        } };
    }

    pub fn stringify(this: MatrixId, gpa: std.mem.Allocator) !Parsed(std.json.Value) {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        errdefer arena.deinit();
        var writer = std.Io.Writer.Allocating.init(gpa);
        defer writer.deinit();
        try this.homeserver.host.?.formatRaw(&writer.writer);
        return .{
            .value = .{
                .string = try std.mem.concat(arena.allocator(), u8, &.{ this.username, ":", writer.written() }),
            },
            .arena = arena,
        };
    }

    pub fn deinit(this: MatrixId) void {
        this.gpa.free(this.username);
        this.gpa.free(this.homeserver_string);
    }

    pub fn dupe(this: MatrixId, gpa: std.mem.Allocator) !MatrixId {
        const homeserver_string = try gpa.dupe(u8, this.homeserver_string);
        return .{
            .username = try gpa.dupe(u8, this.username),
            .uri = try std.Uri.parse(homeserver_string),
            .homeserver_string = homeserver_string,
            .gpa = gpa,
        };
    }
};

const MatrixVersion = struct {
    major: u8,
    minor: u8,
    /// if patch is non-null, this version is legacy
    patch: ?u8 = null,

    pub fn isLegacy(this: MatrixVersion) bool {
        return this.patch != null;
    }
    const ParseError = error{ UnrecognizedScheme, InvalidVersion, InvalidInt, SliceTooSmall };
    /// Parses a version string, ignoring all content once enough values have been extracted.
    ///
    /// `MatrixVersion.parse("v1.1.1.1.1")` => `MatrixVersion{ .major = 1, .minor = 1 }`
    pub fn parse(str: []const u8) ParseError!MatrixVersion {
        if (str.len < 4) return ParseError.SliceTooSmall;
        const scheme = str[0];
        switch (scheme) {
            'v' => {
                var tokenized = std.mem.tokenizeScalar(u8, str[1..], '.');
                var i: u8 = 0;
                var arr: [2]u8 = [2]u8{ 0, 0 };
                while (tokenized.next()) |token| : (i += 1) {
                    if (i >= 2) break;
                    arr[i] = std.fmt.parseInt(u8, token, 10) catch return ParseError.InvalidInt;
                }
                if (i <= 1) return ParseError.InvalidVersion;
                return fromSlice(&arr, false);
            },
            'r' => {
                var tokenized = std.mem.tokenizeScalar(u8, str[1..], '.');
                var i: u8 = 0;
                var arr: [3]u8 = @splat(0);
                while (tokenized.next()) |token| : (i += 1) {
                    if (i >= 3) break;
                    arr[i] = std.fmt.parseInt(u8, token, 10) catch return ParseError.InvalidInt;
                }
                if (i <= 2) return ParseError.InvalidVersion;
                return fromSlice(&arr, true);
            },
            else => return ParseError.UnrecognizedScheme,
        }
    }

    pub fn fromSlice(arr: []const u8, legacy: bool) ParseError!MatrixVersion {
        if (legacy) {
            if (arr.len < 3) return ParseError.SliceTooSmall;
            return .{ .major = arr[0], .minor = arr[1], .patch = arr[2] };
        } else {
            if (arr.len < 2) return ParseError.SliceTooSmall;
            return .{ .major = arr[0], .minor = arr[1] };
        }
    }

    pub fn eql(this: MatrixVersion, other: MatrixVersion) bool {
        return this.major == other.major and this.minor == other.minor and this.patch == other.patch;
    }

    pub fn greater(this: MatrixVersion, other: MatrixVersion) bool {
        if (this.major < other.major) return false;
        if (this.major == other.major) {
            if (this.minor < other.minor) return false;
            if (this.minor == other.minor) {
                if (this.patch != null and other.patch != null) {
                    if (this.patch.? < other.patch.?) return false;
                    if (this.patch.? == other.patch.?) {
                        return false;
                    }
                }
            }
        }
        return true;
    }

    pub fn less(this: MatrixVersion, other: MatrixVersion) bool {
        if (this.major < other.major) return true;
        if (this.major > other.major) return false;
        if (this.minor < other.minor) return true;
        if (this.patch != null and other.patch != null) {
            if (this.minor > other.minor) return false;
            return this.patch.? < other.patch.?;
        } else {
            if (this.minor >= other.minor) return false;
        }
    }
    pub fn toString(this: MatrixVersion, gpa: std.mem.Allocator) ![]const u8 {
        var major_buf: [5]u8 = undefined;
        const major = major_buf[0..std.fmt.printInt(&major_buf, this.major, 10, .lower, .{})];
        var minor_buf: [5]u8 = undefined;
        const minor = minor_buf[0..std.fmt.printInt(&minor_buf, this.minor, 10, .lower, .{})];
        if (this.patch) |patch| {
            var patch_buf: [5]u8 = undefined;
            const p = patch_buf[0..std.fmt.printInt(&patch_buf, patch, 10, .lower, .{})];
            return try std.mem.concat(gpa, u8, &.{ "r", major, ".", minor, ".", p });
        } else {
            return try std.mem.concat(gpa, u8, &.{ "v", major, ".", minor });
        }
    }
};

const InfoCache = struct {
    arena: *std.heap.ArenaAllocator,
    id: MatrixId,
    versions: SupportedVersions,
    well_known: WellKnownClientInfo,
    auth: LoginResponse,

    pub fn deinit(this: InfoCache, gpa: std.mem.Allocator) void {
        this.arena.deinit();
        gpa.destroy(this.arena);
    }

    pub fn stringify(this: InfoCache, gpa: std.mem.Allocator) !Parsed(std.json.Value) {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        const alloc = arena.allocator();
        var value = std.json.Value{ .object = .empty };
        try value.object.put(alloc, "id", (try this.id.stringify(alloc)).value);
        try value.object.put(alloc, "versions", (try this.versions.stringify(alloc)).value);
        try value.object.put(alloc, "well_known", (try this.well_known.stringify(alloc)).value);
        try value.object.put(alloc, "auth", (try this.auth.stringify(alloc)).value);
        return .{
            .arena = arena,
            .value = value,
        };
    }

    pub fn parse(gpa: std.mem.Allocator, value: std.json.Value) !InfoCache {
        // idk why this needs to be allocated, but it doesnt properly deinit the allocations when it isnt
        // ig arenas cant be passed by value??
        var persistent = try gpa.create(std.heap.ArenaAllocator);
        persistent.* = .init(gpa);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const id = try MatrixId.parse(persistent.allocator(), (value.object.get("id") orelse return error.MissingId).string);
        var versions_v = value.object.get("versions") orelse return error.MissingVersions;
        const versions = try SupportedVersions.parse(&arena, &versions_v);
        var well_known_v = value.object.get("well_known") orelse return error.MissingWellKnown;
        const well_known = try WellKnownClientInfo.parse(&arena, &well_known_v);
        var auth_v = value.object.get("auth") orelse return error.MissingAuth;
        const auth = try LoginResponse.parse(&arena, &auth_v);
        return .{
            .arena = persistent,
            .id = id,
            .versions = try versions.value.clone(persistent.allocator()),
            .well_known = try well_known.value.clone(persistent.allocator()),
            .auth = try auth.value.clone(persistent.allocator()),
        };
    }

    pub fn read(gpa: std.mem.Allocator, io: std.Io) !InfoCache {
        const file = try std.Io.Dir.openFile(.cwd(), io, "cache", .{});
        defer file.close(io);
        var buf: [128]u8 = undefined;
        var reader = file.reader(io, &buf);
        const str = try reader.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(str);
        var source = std.json.Scanner.initCompleteInput(gpa, str);
        defer source.deinit();
        var arena = std.heap.ArenaAllocator.init(gpa);
        const value = try std.json.Value.jsonParse(arena.allocator(), &source, .{ .ignore_unknown_fields = true, .max_value_len = str.len });
        defer arena.deinit();
        return try InfoCache.parse(gpa, value) ;
    }
};

var cache: ?InfoCache = null;

const LegacyLoginScreen = struct {
    username: Focus(widgets.TextInput),
    password: Focus(widgets.TextInput),
    homeserver: []const u8,
    scheme: *const ColorScheme,
    io: std.Io,
    gpa: std.mem.Allocator,
    queue: *Queue,
    req: ?std.Io.Future(void) = null,
    status: Status = .awaiting_submission,
    locked: bool = false,

    pub const Status = union(enum) {
        awaiting_submission,
        parsing,
        requesting,
        checking_version,
        authenticating,
        done: InfoCache,
        // should always be used with @errorName so i dont have to do memory management
        err: struct { e: []const u8, trace: ?std.builtin.StackTrace },
        network_err: Error,

        const awaiting_text: []const u8 = "[s]ubmit";
        const parsing_text = "Parsing ID";
        const requesting_text = "Requesting client details";
        const checking_text = "Checking homeserver versions";
        const authenticating_text = "Authenticating";
        const done_text = "Done";
        pub fn text(this: Status) []const u8 {
            return switch (this) {
                .awaiting_submission => awaiting_text,
                .parsing => parsing_text,
                .requesting => requesting_text,
                .checking_version => checking_text,
                .authenticating => authenticating_text,
                .done => done_text,
                .err => |e| e.e,
                .network_err => |err| err.err,
            };
        }

        pub fn deinit(this: *Status, gpa: std.mem.Allocator) void {
            if (this.* == .network_err) {
                this.network_err.deinit(gpa);
            }
        }

        pub fn bad(this: Status) bool {
            return this == .err or this == .network_err;
        }
    };
    const star = "*";
    pub fn init(gpa: std.mem.Allocator, homeserver: []const u8, scheme: *const ColorScheme, io: std.Io, queue: *Queue) !LegacyLoginScreen {
        var password: Focus(widgets.TextInput) = .init(.init(gpa));
        password.widget.cell_mask = star;
        return .{
            .username = .initFocused(.init(gpa)),
            .password = password,
            .homeserver = homeserver,
            .gpa = gpa,
            .scheme = scheme,
            .io = io,
            .queue = queue,
        };
    }

    pub fn deinit(this: *LegacyLoginScreen) void {
        if (this.req) |*req| {
            req.cancel(this.io);
        }
        this.username.widget.deinit();
        this.password.widget.deinit();
        this.status.deinit(this.gpa);
    }

    pub fn focused(this: *const LegacyLoginScreen) bool {
        return this.username.focused or this.password.focused;
    }

    pub fn update(this: *LegacyLoginScreen, e: Event) !bool {
        switch (e) {
            .key_press => |key| {
                if (key.matchExact(vaxis.Key.escape, .{})) {
                    this.username.focused = false;
                    this.password.focused = false;
                }
                if (!this.locked) {
                    if (this.username.focused) {
                        try this.username.widget.update(.{ .key_press = key });
                        this.status.deinit(this.gpa);
                        this.status = .awaiting_submission;
                    } else if (this.password.focused) {
                        try this.password.widget.update(.{ .key_press = key });
                        this.status.deinit(this.gpa);
                        this.status = .awaiting_submission;
                    }
                }
                if (key.matchExact('q', .{}) and !this.focused()) {
                    return false;
                } else if (key.matchExact('u', .{}) and !this.focused()) {
                    this.username.focused = true;
                } else if (key.matchExact('p', .{}) and !this.focused()) {
                    this.password.focused = true;
                } else if (key.matchExact(vaxis.Key.enter, .{}) and !this.locked) {
                    if (this.username.focused) {
                        this.username.focused = false;
                        this.password.focused = true;
                    } else {
                        try this.doSubmit();
                    }
                } else if ((key.matchExact('s', .{}) and !this.focused()) or key.matchExact(vaxis.Key.enter, .{})) {
                    try this.doSubmit();
                }
            },
            .login => |login| {
                switch (login) {
                    .legacy => |status| {
                        this.status.deinit(this.gpa);
                        this.status = status;
                        if (status == .err or status == .network_err) {
                            this.locked = false;
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }

        return true;
    }
    fn doSubmit(this: *LegacyLoginScreen) !void {
        if (this.status != .awaiting_submission) return;
        this.username.focused = false;
        this.password.focused = false;
        if (this.req) |*req| {
            req.cancel(this.io);
        }
        this.locked = true;
        this.status = .parsing;
        this.req = this.io.async(submitWrapper, .{ this.queue, this.io, this.gpa, this.homeserver, try this.username.widget.toOwnedContents(this.gpa), try this.password.widget.toOwnedContents(this.gpa) });
    }

    inline fn trace() ?std.builtin.StackTrace {
        return if (@errorReturnTrace()) |t| t.* else null;
    }

    fn submitWrapper(q: *Queue, io: std.Io, gpa: std.mem.Allocator, homeserver: []const u8, username: []const u8, password: []const u8) void {
        submit(q, io, gpa, homeserver, username, password) catch |err| {
            // for errdefer
            if (err == error.Ignore) return;
            q.push(.{ .login = .{ .legacy = .{ .err = .{ .e = @errorName(err), .trace = if (@errorReturnTrace()) |t| t.* else null } } } }) catch return;
        };
    }
    fn submit(q: *Queue, io: std.Io, gpa: std.mem.Allocator, homeserver: []const u8, username: []const u8, password: []const u8) !void {
        defer {
            gpa.free(username);
            gpa.free(password);
        }
        const persistent_arena = try gpa.create(std.heap.ArenaAllocator);
        persistent_arena.* = .init(gpa);
        errdefer persistent_arena.deinit();
        const persist = persistent_arena.allocator();

        const str = try std.mem.concat(gpa, u8, &.{ username, ":", homeserver });
        defer gpa.free(str);
        const parsed = try MatrixId.parse(persist, str);

        try io.checkCancel();
        q.push(.{ .login = .{ .legacy = .requesting } }) catch return;

        var client_arena = std.heap.ArenaAllocator.init(gpa);
        var client = try HttpClient.init(client_arena.allocator(), io);
        defer client_arena.deinit();

        const well_known_uri = try std.fmt.allocPrint(client_arena.allocator(), "{f}.well-known/matrix/client", .{parsed.homeserver});
        const client_info = try client.requestJsonBodyless(WellKnownClientInfo, .GET, try std.Uri.parse(well_known_uri));
        if (client_info == .err) {
            // clone with gpa because the allocated memory will be freed with the HttpClient, and the event handler will deinit the error
            try q.push(.{ .login = .{ .legacy = .{ .network_err = try client_info.err.value.clone(gpa) } } });
            return error.Ignore;
        }
        const info = try client_info.success.value.clone(persist);

        try io.checkCancel();
        try q.push(.{ .login = .{ .legacy = .checking_version } });

        const version_uri = try std.fmt.allocPrint(client_arena.allocator(), "{s}/_matrix/client/versions", .{info.homeserver});

        const version_res = try client.requestJsonBodyless(SupportedVersions, .GET, try std.Uri.parse(version_uri));
        if (version_res == .err) {
            try q.push(.{ .login = .{ .legacy = .{ .network_err = try version_res.err.value.clone(gpa) } } });
            return error.Ignore;
        }
        const versions = try version_res.success.value.clone(persist);

        try io.checkCancel();
        try q.push(.{ .login = .{ .legacy = .authenticating } });
        const login_uri = try std.fmt.allocPrint(client_arena.allocator(), "{s}/_matrix/client/v3/login", .{info.homeserver});
        const flows_res = try client.requestJsonBodyless(LoginFlows, .GET, try std.Uri.parse(login_uri));
        if (flows_res == .err) {
            try q.push(.{ .login = .{ .legacy = .{ .network_err = try flows_res.err.value.clone(gpa) } } });
            return error.Ignore;
        }
        const flows = flows_res.success;
        var choice: ?*LoginFlows.Flow = null;
        for (flows.value.flows) |*flow| {
            if (flow.t.supported()) {
                choice = flow;
            }
        }
        if (choice == null) {
            return error.NoSupportedFlow;
        }
        const flow = choice.?;
        // redundant but i dont care
        if (flow.t != .password) return error.NoSupportedFlow;

        const id = try parsed.identifier(client_arena.allocator());

        var auth_data: ?LoginResponse = null;
        if (flow.get_login_token) {} else {
            const auth = BasicPasswordLogin{
                .password = password,
                .identifier = id,
                .initial_device = "test",
            };

            const value = try auth.stringify(client_arena.allocator());
            const auth_res = try client.requestJson(LoginResponse, .POST, try std.Uri.parse(login_uri), value.value);
            if (auth_res == .err) {
                try q.push(.{ .login = .{ .legacy = .{ .network_err = try auth_res.err.value.clone(gpa) } } });
                return error.Ignore;
            }
            std.debug.print("{s}", .{auth_res.success.value.token});
            auth_data = try auth_res.success.value.clone(persist);
        }

        if (auth_data == null) return error.NoAuthData;
        try q.push(.{ .login = .{ .legacy = .{ .done = .{
            .arena = persistent_arena,
            .id = parsed,
            .versions = versions,
            .well_known = info,
            .auth = auth_data.?,
        } } } });
    }

    pub fn draw(this: *LegacyLoginScreen, _: std.mem.Allocator, win: vaxis.Window) !void {
        if (win.height < 7) return error.WindowTooSmall;
        const spacing = @divFloor((win.height - 6), 3);
        var user_win = LabelledWindow.init(
            "[u]sername",
            if (this.username.focused) this.scheme.cyan else this.scheme.fg,
            win,
            .{
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
            },
        );
        const pass_win = LabelledWindow.init(
            "[p]assword",
            if (this.password.focused) this.scheme.cyan else this.scheme.fg,
            win,
            .{
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
            },
        );

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
                .style = .{ .fg = if (!this.status.bad()) this.scheme.green else this.scheme.red },
            },
            .{},
        );
    }
};

const LoginResponse = struct {
    token: []const u8,
    device_id: []const u8,
    expires_in: ?i64,
    refresh_token: ?[]const u8,

    pub fn stringify(this: LoginResponse, gpa: std.mem.Allocator) !Parsed(std.json.Value) {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        var value = std.json.Value{ .object = .empty };
        try value.object.put(alloc, "access_token", .{ .string = try alloc.dupe(u8, this.token) });
        try value.object.put(alloc, "device_id", .{ .string = try alloc.dupe(u8, this.device_id) });
        if (this.expires_in) |e| {
            try value.object.put(alloc, "expires_in", .{ .integer = e });
        }
        if (this.refresh_token) |r| {
            try value.object.put(alloc, "refresh_token", .{ .string = try alloc.dupe(u8, r) });
        }
        return .{
            .arena = arena,
            .value = value,
        };
    }

    pub fn parse(arena: *std.heap.ArenaAllocator, parsed: *std.json.Value) !Parsed(LoginResponse) {
        if (parsed.* != .object) return error.MissingRequiredField;
        const obj = parsed.object;

        const token_v = obj.get("access_token") orelse return error.MissingRequiredField;
        if (token_v != .string) return error.MissingRequiredField;
        const token = token_v.string;

        const device_v = obj.get("device_id") orelse return error.MissingRequiredField;
        if (device_v != .string) return error.MissingRequiredField;
        const device_id = device_v.string;

        const expires_v = obj.get("expires_in");
        var expires_in: ?i64 = null;
        if (expires_v) |e| {
            if (e != .integer) return error.MissingRequiredField;
            expires_in = e.integer;
        }

        const refresh_v = obj.get("refresh_token");
        var refresh_token: ?[]const u8 = null;
        if (refresh_v) |r| {
            if (r != .string) return error.MissingRequiredField;
            refresh_token = r.string;
        }

        return .{
            .arena = arena,
            .value = .{
                .token = token,
                .device_id = device_id,
                .expires_in = expires_in,
                .refresh_token = refresh_token,
            },
        };
    }

    pub fn clone(this: LoginResponse, gpa: std.mem.Allocator) !LoginResponse {
        return .{
            .token = try gpa.dupe(u8, this.token),
            .device_id = try gpa.dupe(u8, this.device_id),
            .expires_in = this.expires_in,
            .refresh_token = if (this.refresh_token) |r| try gpa.dupe(u8, r) else null,
        };
    }
};

const BasicPasswordLogin = struct {
    identifier: Identifier,
    password: []const u8,
    initial_device: ?[]const u8,

    pub fn stringify(this: BasicPasswordLogin, gpa: std.mem.Allocator) !Parsed(std.json.Value) {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);

        var value = std.json.Value{ .object = try .init(arena.allocator(), &.{}, &.{}) };
        try value.object.put(arena.allocator(), "type", .{ .string = try arena.allocator().dupe(u8, "m.login.password") });
        try value.object.put(arena.allocator(), "identifier", (try this.identifier.stringify(arena.allocator())).value);
        try value.object.put(arena.allocator(), "password", .{ .string = try arena.allocator().dupe(u8, this.password) });
        try value.object.put(arena.allocator(), "refresh_token", .{ .bool = true });
        if (this.initial_device) |name| {
            try value.object.put(arena.allocator(), "initial_device_display_name", .{ .string = try arena.allocator().dupe(u8, name) });
        }

        return .{
            .arena = arena,
            .value = value,
        };
    }
};

const PasswordFlow = struct {
    identifier: Identifier,
    password: []const u8,
    session_id: ?[]const u8,

    pub fn stringify(this: PasswordFlow, gpa: std.mem.Allocator) !Parsed(std.json.Value) {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);

        var value = std.json.Value{ .object = try .init(arena.allocator(), &.{}, &.{}) };
        try value.object.put(arena.allocator(), "type", .{ .string = try arena.allocator().dupe(u8, "m.login.password") });
        try value.object.put(arena.allocator(), "identifier", (try this.identifier.stringify(arena.allocator())).value);
        try value.object.put(arena.allocator(), "password", .{ .string = try arena.allocator().dupe(u8, this.password) });
    }
};

const HomeserverScreen = struct {
    homeserver: Focus(widgets.TextInput),
    scheme: *const ColorScheme,
    io: std.Io,
    gpa: std.mem.Allocator,
    queue: *Queue,
    req: ?std.Io.Future(void) = null,
    status: Status = .awaiting_submission,
    locked: bool = false,

    pub const Status = union(enum) {
        awaiting_submission,
        checking_capabilities,
        done: struct { oauth: bool, legacy: bool },
        // should always be used with @errorName so i dont have to do memory management
        err: []const u8,
        network_err: Error,

        const awaiting_text: []const u8 = "[s]ubmit";
        const capability_text = "Checking capabilities";
        const done_text = "Done";
        pub fn text(this: Status) []const u8 {
            return switch (this) {
                .awaiting_submission => awaiting_text,
                .checking_capabilities => capability_text,
                .done => done_text,
                .err => |str| str,
                .network_err => |err| err.err,
            };
        }

        pub fn deinit(this: *Status, gpa: std.mem.Allocator) void {
            if (this.* == .network_err) {
                this.network_err.deinit(gpa);
            }
        }
        pub fn bad(this: Status) bool {
            return this == .err or this == .network_err;
        }
    };

    pub fn init(gpa: std.mem.Allocator, scheme: *const ColorScheme, io: std.Io, queue: *Queue) !HomeserverScreen {
        return .{
            .homeserver = .initFocused(.init(gpa)),
            .gpa = gpa,
            .scheme = scheme,
            .io = io,
            .queue = queue,
        };
    }

    pub fn deinit(this: *HomeserverScreen) void {
        if (this.req) |*req| {
            req.cancel(this.io);
        }
        this.homeserver.widget.deinit();
        this.status.deinit(this.gpa);
    }

    pub fn focused(this: *const HomeserverScreen) bool {
        return this.homeserver.focused;
    }

    pub fn update(this: *HomeserverScreen, e: Event) !bool {
        switch (e) {
            .key_press => |key| {
                if (key.matchExact(vaxis.Key.escape, .{})) {
                    this.homeserver.focused = false;
                }
                if (!this.locked) {
                    if (this.homeserver.focused) {
                        try this.homeserver.widget.update(.{ .key_press = key });
                        this.status.deinit(this.gpa);
                        this.status = .awaiting_submission;
                    }
                }
                if (key.matchExact('q', .{}) and !this.focused()) {
                    return false;
                } else if (key.matchExact('h', .{})) {
                    this.homeserver.focused = true;
                } else if (((key.matchExact('s', .{}) and !this.homeserver.focused) or key.matchExact(vaxis.Key.enter, .{})) and this.status == .awaiting_submission) {
                    this.homeserver.focused = false;
                    if (this.req) |*req| {
                        req.cancel(this.io);
                    }
                    this.locked = true;
                    this.status.deinit(this.gpa);
                    this.status = .checking_capabilities;
                    this.req = this.io.async(homeserverSubmitWrapper, .{ this.queue, this.io, this.gpa, try this.homeserver.widget.toOwnedContents(this.gpa) });
                }
            },
            .login => |login| {
                switch (login) {
                    .homeserver => |status| {
                        this.status.deinit(this.gpa);
                        this.status = status;
                        if (status == .err or status == .network_err) {
                            this.locked = false;
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }

        return true;
    }

    fn homeserverSubmitWrapper(q: *Queue, io: std.Io, gpa: std.mem.Allocator, homeserver: []const u8) void {
        homeserverSubmit(q, io, gpa, homeserver) catch |err| {
            if (err == error.Ignore) return;
            q.push(.{ .login = .{ .homeserver = .{ .err = @errorName(err) } } }) catch return;
        };
    }

    fn homeserverSubmit(q: *Queue, io: std.Io, gpa: std.mem.Allocator, homeserver: []const u8) !void {
        _ = io;
        defer gpa.free(homeserver);

        // TODO: actually check whether to use oauth or legacy
        try q.push(.{ .login = .{ .homeserver = .{ .done = .{ .oauth = false, .legacy = true } } } });
    }

    pub fn draw(this: *HomeserverScreen, _: std.mem.Allocator, win: vaxis.Window) !void {
        if (win.height < 7) return error.WindowTooSmall;
        const spacing = @divFloor((win.height - 6), 3);
        const hs_win = LabelledWindow.init("[h]omeserver", if (this.homeserver.focused) this.scheme.cyan else this.scheme.fg, win, .{
            .x_off = 1,
            .y_off = spacing,
            .width = win.width - 2,
            .height = 3,
            .border = .{
                .where = .all,
                .style = .{
                    .fg = if (this.homeserver.focused) this.scheme.cyan else this.scheme.grey,
                },
            },
        });
        this.homeserver.widget.draw(hs_win);
        if (!this.homeserver.focused) {
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
                .style = .{ .fg = if (!this.status.bad()) this.scheme.green else this.scheme.red },
            },
            .{},
        );
    }
};

const LoginScreen = struct {
    homeserver_screen: ?HomeserverScreen,
    legacy: ?LegacyLoginScreen = null,
    homeserver: ?[]const u8 = null,

    scheme: *const ColorScheme,
    io: std.Io,
    gpa: std.mem.Allocator,
    queue: *Queue,

    logging: bool = false,

    pub const LoginEvent = union(enum) {
        legacy: LegacyLoginScreen.Status,
        homeserver: HomeserverScreen.Status,
    };

    pub fn init(gpa: std.mem.Allocator, scheme: *const ColorScheme, io: std.Io, queue: *Queue) !LoginScreen {
        return .{
            .homeserver_screen = try .init(gpa, scheme, io, queue),
            .scheme = scheme,
            .io = io,
            .gpa = gpa,
            .queue = queue,
        };
    }
    pub fn deinit(this: *LoginScreen) void {
        if (this.homeserver) |hs| {
            this.gpa.free(hs);
        }
        if (this.homeserver_screen) |*hs| {
            hs.deinit();
        }
        if (this.legacy) |*l| {
            l.deinit();
        }
    }

    pub fn focused(this: *const LoginScreen) bool {
        return (if (this.homeserver_screen) |h| h.focused() else false) or (if (this.legacy) |l| l.focused() else false);
    }

    pub fn update(this: *LoginScreen, e: Event) !bool {
        switch (e) {
            .key_press => |key| {
                if (key.matchExact('q', .{}) and !this.focused()) {
                    return false;
                }
            },
            .login => |login| {
                switch (login) {
                    .legacy => |status| {
                        if (this.logging) {
                            std.log.debug("legacy recieved: {any}", .{status});
                        }
                        if (status == .done) {
                            cache = status.done;
                        }
                    },
                    .homeserver => |status| {
                        if (this.logging) {
                            std.log.debug("homeserver recieved: {any}", .{status});
                        }
                        if (status == .done) {
                            if (this.homeserver) |hs| {
                                this.gpa.free(hs);
                            }
                            this.homeserver = try this.homeserver_screen.?.homeserver.widget.toOwnedContents(this.gpa);
                            this.homeserver_screen.?.deinit();
                            this.homeserver_screen = null;
                            this.legacy = try .init(this.gpa, this.homeserver.?, this.scheme, this.io, this.queue);
                            return true;
                        }
                    },
                }
            },
            else => {},
        }
        if (this.homeserver_screen) |*h| {
            _ = try h.update(e);
        } else if (this.legacy) |*l| {
            _ = try l.update(e);
        }

        return true;
    }

    pub fn draw(this: *LoginScreen, alloc: std.mem.Allocator, win: vaxis.Window) !void {
        if (win.height < 11) return error.WindowTooSmall;
        const child = LabelledWindow.init("Login", this.scheme.fg, win, .{
            .height = @min(win.height, 11),
            .width = @min(win.width, 60),
            .x_off = (win.width / 2) - (@min(win.width, 60) / 2),
            .y_off = (win.height / 2) - (@min(win.height, 11) / 2),
            .border = .{ .where = .all },
        });

        if (this.homeserver_screen) |*h| {
            try h.draw(alloc, child);
        } else if (this.legacy) |*l| {
            try l.draw(alloc, child);
        }
    }
};

test "unredacted" {
    const testing = std.testing;
    var client = try HttpClient.init(testing.allocator, testing.io);
    defer client.deinit();

    const res = try client.requestJsonBodyless(WellKnownClientInfo, .GET, try std.Uri.parse("https://unredacted.org/.well-known/matrix/client"));
    defer res.deinit();
    try testing.expect(res != .err);
}

test "submit" {
    std.testing.allocator_instance.stack_trace_size = 15;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const homeserver = "unredacted.org";
    const username = "flyingpig525";
    const password = "my_totally_real_password";

    var q = Queue.init(io);
    const colors = ColorScheme{};
    var screen = try LoginScreen.init(gpa, &colors, io, &q);
    defer screen.deinit();
    screen.logging = true;

    try q.push(.{ .key_press = .{ .codepoint = 'h' } });
    try q.push(.{ .key_press = .{ .text = homeserver, .codepoint = '0' } });
    try q.push(.{ .key_press = .{ .codepoint = vaxis.Key.escape } });
    try q.push(.{ .key_press = .{ .codepoint = 's' } });

    var done = false;
    var e: Event = .focus_in;
    while (!done and (e != .login or e.login != .homeserver or e.login.homeserver != .done)) {
        // if .done is never sent, this will hang forever :( im too lazy to make it time out
        e = try q.pop();
        _ = try screen.update(e);
    }
    try q.push(.{ .key_press = .{ .codepoint = 'u' } });
    try q.push(.{ .key_press = .{ .text = username, .codepoint = '0' } });

    try q.push(.{ .key_press = .{ .codepoint = vaxis.Key.escape } });

    try q.push(.{ .key_press = .{ .codepoint = 'p' } });
    try q.push(.{ .key_press = .{ .text = password, .codepoint = '0' } });

    try q.push(.{ .key_press = .{ .codepoint = vaxis.Key.escape } });
    try q.push(.{ .key_press = .{ .codepoint = 's' } });
    while (!done) {
        // if .done is never sent, this will hang forever :( im too lazy to make it time out
        e = try q.pop();
        _ = try screen.update(e);
        if (screen.logging) {
            std.debug.print("{any}\n", .{e});
        }
        if (e == .login) blk: {
            if (e.login != .legacy) break :blk;
            if (e.login.legacy == .done) {
                done = true;
            }
            if (e.login.legacy == .err) {
                if (screen.logging) {
                    if (e.login.legacy.err.trace) |t| {
                        std.debug.dumpErrorReturnTrace(&t);
                    }
                }
                return error.A;
            } else if (e.login.legacy == .network_err) {
                if (screen.logging) {
                    std.debug.print("network error\n", .{});
                    std.debug.print("{s}\n", .{e.login.legacy.network_err.err});
                }
            }
            try std.testing.expect(e.login.legacy != .err);
            if (e.login.legacy == .network_err) {
                try std.testing.expect(e.login.legacy.network_err.err_code == .forbidden);
            }
        }
    }
}

const Global = struct {
    gpa: std.mem.Allocator,
    scheme: *ColorScheme,
    io: std.Io,
    queue: *Queue,
    login: ?LoginScreen = null,

    pub fn goToLogin(this: *Global) !void {
        if (this.login != null) return;

        this.login = try .init(this.gpa, this.scheme, this.io, this.queue);
    }

    /// Whether any widgets on the screen are capturing input
    ///
    /// probably shouldnt be named focused :P
    pub fn focused(this: Global) bool {
        var f = false;
        if (this.login) |login| {
            f = f or login.focused();
        }
        return f;
    }

    pub fn update(this: *Global, e: Event) !bool {
        if (this.login) |*login| {
            _ = try login.update(e);
        }
        switch (e) {
            .key_press => |key| {
                if (key.matchExact('q', .{}) and !this.focused()) {
                    return true;
                }
            },
            else => {},
        }
        return false;
    }

    pub fn draw(this: *Global, gpa: std.mem.Allocator, win: vaxis.Window) !void {
        if (this.login) |*login| {
            try login.draw(gpa, win);
        }
    }

    pub fn deinit(this: *Global) void {
        if (this.login) |*login| {
            login.deinit();
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    defer if (cache) |c| blk: {
        defer c.deinit(gpa);
        const file = std.Io.Dir.createFile(.cwd(), init.io, "cache", .{}) catch break :blk;
        defer file.close(io);
        var buf: [128]u8 = undefined;
        var writer = file.writer(io, &buf);
        var value = c.stringify(gpa) catch break :blk;
        defer value.deinit();
        std.json.Stringify.value(value.value, .{}, &writer.interface) catch break :blk;
        writer.end() catch break :blk;
    };
    cache = InfoCache.read(gpa, io) catch |err| blk: {
        std.debug.dumpErrorReturnTrace(@errorReturnTrace() orelse break :blk null);
        std.debug.print("err: {any}\n", .{ err });
        break :blk null;
    };
    defer std.debug.print("{any}", .{ cache });

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

    var scheme: ColorScheme = .{};

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // var fut = io.async(addToQueue, .{ &loop.queue, gpa, io });
    // defer fut.cancel(io) catch {};

    var global = Global{
        .gpa = gpa,
        .queue = &loop.queue,
        .scheme = &scheme,
        .io = io,
    };
    defer global.deinit();
    try global.goToLogin();

    while (true) {
        const e = try loop.nextEvent();
        _ = arena.reset(.free_all);
        if (e == .winsize) {
            try vx.resize(gpa, tty.writer(), e.winsize);
        }

        const win = vx.window();
        win.clear();

        if (try global.update(e)) break;
        try global.draw(arena.allocator(), win);

        try vx.render(tty.writer());
    }
}
