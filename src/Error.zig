const std = @import("std");

err_code_str: []const u8,
err: []const u8,
err_code: ?Code = null,
extra: ?std.array_hash_map.String([]const u8) = null,

pub const InitError = error{MissingRequiredField} || std.mem.Allocator.Error;
pub fn init(arena: *std.heap.ArenaAllocator, parsed: *std.json.Value) InitError!std.json.Parsed(@This()) {
    // TODO: implement err_code
    const value = &parsed.object;
    const err_code_str = (value.get("errcode") orelse return error.MissingRequiredField).string;
    const err = (value.get("error") orelse return error.MissingRequiredField).string;
    if (value.entries.len == 2) return .{ .arena = arena, .value = .{
        .err_code_str = err_code_str,
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
    forbidden,
    limit_exceeded,
    missing_token,
    not_found,
    not_json,
    resource_limit_exceeded,
    unknown,
    unknown_device,
    unknown_token,
    unrecognized,
    user_limit_exceeded,
    user_locked,
    user_suspended,
    bad_state,
    cannot_leave_server_notice_room,
    captcha_invalid,
    captcha_needed,
    exclusive,
    guest_access_forbidden,
    incompatible_room_version,
    invalid_param,
    invalid_room_state,
    invalid_username,
    missing_param,
    room_in_use,
    server_not_trusted,
    threepid_auth_failed,
    threepid_denied,
    threepid_in_use,
    threepid_medium_not_supported,
    threepid_not_found,
    too_large,
    unauthorized,
    unsupported_room_version,
    user_deactivated,
    user_in_use,
};
