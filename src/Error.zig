const std = @import("std");

err_code_str: []const u8,
err: []const u8,
err_code: ?Code,
extra: ?std.array_hash_map.String([]const u8) = null,

pub const InitError = error{MissingRequiredField} || std.mem.Allocator.Error;
pub fn init(arena: *std.heap.ArenaAllocator, parsed: *std.json.Value) InitError!std.json.Parsed(@This()) {
    // TODO: implement err_code
    const value = &parsed.object;
    const err_code_str = (value.get("errcode") orelse return error.MissingRequiredField).string;
    const err = (value.get("error") orelse return error.MissingRequiredField).string;
    if (value.entries.len == 2) return .{ .arena = arena, .value = .{
        .err_code_str = err_code_str,
        .err_code = Code.fromStr(err_code_str),
        .err = err,
    } };

    var iter = value.iterator();
    var map = std.array_hash_map.String([]const u8).empty;
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "errcode") or std.mem.eql(u8, entry.key_ptr.*, "error")) continue;
        try map.put(arena.allocator(), try arena.allocator().dupe(u8, entry.key_ptr.*), try arena.allocator().dupe(u8, entry.value_ptr.string));
    }
        return .{
        .arena = arena,
        .value = .{
            .err_code_str = err_code_str,
            .err_code = Code.fromStr(err_code_str),
            .err = err,
            .extra = map,
        },
    };
}

pub fn deinit(this: *@This(), gpa: std.mem.Allocator) void {
    gpa.free(this.err_code_str);
    gpa.free(this.err);
    if (this.extra) |*e| {
        var iter = e.iterator();
        while (iter.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        e.deinit(gpa);
    }
}

pub fn clone(this: @This(), gpa: std.mem.Allocator) !@This() {
    var map: ?std.array_hash_map.String([]const u8) = null;
    if (this.extra) |extra| {
        map = std.array_hash_map.String([]const u8).empty;
        var iter = extra.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "errcode") or std.mem.eql(u8, entry.key_ptr.*, "error")) continue;
            try map.?.put(gpa, try gpa.dupe(u8, entry.key_ptr.*), try gpa.dupe(u8, entry.value_ptr.*));
        }
    }

    return .{
        .err = try gpa.dupe(u8, this.err),
        .extra = map,
        .err_code_str = try gpa.dupe(u8, this.err_code_str),
        .err_code = this.err_code,
    };

}

pub const Code = enum {
    bad_json,
    bad_state,
    cannot_leave_server_notice_room,
    captcha_invalid,
    captcha_needed,
    exclusive,
    forbidden,
    limit_exceeded,
    missing_token,
    missing_param,
    not_found,
    not_json,
    resource_limit_exceeded,
    room_in_use,
    unknown,
    unknown_device,
    unknown_token,
    unrecognized,
    user_limit_exceeded,
    user_locked,
    user_suspended,
    unauthorized,
    unsupported_room_version,
    user_deactivated,
    user_in_use,
    guest_access_forbidden,
    incompatible_room_version,
    invalid_param,
    invalid_room_state,
    invalid_username,
    server_not_trusted,
    threepid_auth_failed,
    threepid_denied,
    threepid_in_use,
    threepid_medium_not_supported,
    threepid_not_found,
    too_large,

    pub fn fromStr(str: []const u8) ?Code {
        if (!std.mem.startsWith(u8, str, "M_")) {
            return null;
        }

        const sub = str[2..];
        // stupid unreadable optimization fuckery
        if (std.mem.startsWith(u8, sub, "BAD")) {
            if (std.mem.endsWith(u8, sub, "JSON")) return .bad_json;
            if (std.mem.endsWith(u8, sub, "STATE")) return .bad_state;
        }
        if (std.mem.eql(u8, sub, "CANNOT_LEAVE_SERVER_NOTICE_ROOM")) return .cannot_leave_server_notice_room;
        if (std.mem.startsWith(u8, sub, "CAPTCHA")) {
            if (std.mem.endsWith(u8, sub, "INVALID")) return .captcha_invalid;
            if (std.mem.endsWith(u8, sub, "NEEDED")) return .captcha_needed;
        }
        if (std.mem.eql(u8, sub, "EXCLUSIVE")) return .exclusive;
        if (std.mem.eql(u8, sub, "FORBIDDEN")) return .forbidden;
        if (std.mem.eql(u8, sub, "LIMIT_EXCEEDED")) return .limit_exceeded;
        if (std.mem.startsWith(u8, sub, "MISSING")) {
            if (std.mem.endsWith(u8, sub, "TOKEN")) return .missing_token;
            if (std.mem.endsWith(u8, sub, "PARAM")) return .missing_param;
        }
        if (std.mem.startsWith(u8, sub, "NOT")) {
            if (std.mem.endsWith(u8, sub, "FOUND")) return .not_found;
            if (std.mem.endsWith(u8, sub, "JSON")) return .not_json;
        }
        if (std.mem.eql(u8, sub, "RESOURCE_LIMIT_EXCEEDED")) return .resource_limit_exceeded;
        if (std.mem.eql(u8, sub, "ROOM_IN_USE")) return .room_in_use;
        if (std.mem.startsWith(u8, sub, "UNKNOWN")) {
            if (sub.len == ("UNKNOWN").len) return .unknown;
            if (std.mem.endsWith(u8, sub, "DEVICE")) return .unknown_device;
            if (std.mem.endsWith(u8, sub, "TOKEN")) return .unknown_token;
        }
        if (std.mem.eql(u8, sub, "UNRECOGNIZED")) return .unrecognized;
        if (std.mem.startsWith(u8, sub, "USER")) {
            if (std.mem.endsWith(u8, sub, "LIMIT_EXCEEDED")) return .user_limit_exceeded;
            if (std.mem.endsWith(u8, sub, "LOCKED")) return .user_locked;
            if (std.mem.endsWith(u8, sub, "SUSPENDED")) return .user_suspended;
            if (std.mem.endsWith(u8, sub, "DEACTIVATED")) return .user_deactivated;
            if (std.mem.endsWith(u8, sub, "IN_USE")) return .user_in_use;
        }
        if (std.mem.eql(u8, sub, "UNAUTHORIZED")) return .unauthorized;
        if (std.mem.eql(u8, sub, "UNSUPPORTED_ROOM_VERSION")) return .unsupported_room_version;
        if (std.mem.eql(u8, sub, "GUEST_ACCESS_FORBIDDEN")) return .guest_access_forbidden;
        if (std.mem.eql(u8, sub, "INCOMPATIBLE_ROOM_VERISON")) return .incompatible_room_version;
        if (std.mem.startsWith(u8, sub, "INVALID")) {
            if (std.mem.endsWith(u8, sub, "PARAM")) return .invalid_param;
            if (std.mem.endsWith(u8, sub, "ROOM_STATE")) return .invalid_room_state;
            if (std.mem.endsWith(u8, sub, "USERNAME")) return .invalid_username;
        }
        if (std.mem.eql(u8, sub, "SERVER_NOT_TRUSTED")) return .server_not_trusted;
        if (std.mem.startsWith(u8, sub, "THREEPID")) {
            if (std.mem.endsWith(u8, sub, "DENIED")) return .threepid_denied;
            if (std.mem.endsWith(u8, sub, "MEDIUM_NOT_SUPPORTED")) return .threepid_medium_not_supported;
            if (std.mem.endsWith(u8, sub, "AUTH_FAILED")) return .threepid_auth_failed;
            if (std.mem.endsWith(u8, sub, "IN_USE")) return .threepid_in_use;
            if (std.mem.endsWith(u8, sub, "NOT_FOUND")) return .threepid_not_found;
        }
        if (std.mem.eql(u8, sub, "TOO_LARGE")) return .too_large;
        return null;
    }

    test fromStr {
        const expect = std.testing.expect;
        try expect(Code.fromStr("M_FORBIDDEN") == .forbidden);
        try expect(Code.fromStr("M_USER_DEACTIVATED") == .user_deactivated);
        try expect(Code.fromStr("M_UNKNOWN") == .unknown);
        try expect(Code.fromStr("M_NOT_JSON") == .not_json);
        try expect(Code.fromStr("M_NOT_REAL") == null);
        try expect(Code.fromStr("NO_M") == null);
    }
};
