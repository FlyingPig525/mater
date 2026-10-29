const std = @import("std");

err_code_str: []const u8,
err: []const u8,
err_code: ?Code = null,
extra: ?std.array_hash_map.String(std.json.Value) = null,

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

    var dupe = try value.clone(arena.allocator());
    value.deinit(arena.allocator());
    _ = dupe.swapRemove("errcode");
    _ = dupe.swapRemove("error");
    return .{
        .arena = arena,
        .value = .{
            .err_code_str = err_code_str,
            .err = err,
            .extra = dupe,
        },
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
