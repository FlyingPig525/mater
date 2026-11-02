const std = @import("std");
const Error = @import("Error.zig");

const HttpClient = @This();

const redirect_buf_size = 8000;

client: std.http.Client,
gpa: std.mem.Allocator,

pub fn init(gpa: std.mem.Allocator, io: std.Io) HttpClient {
    return .{
        .client = .{
            .allocator = gpa,
            .io = io,
        },
        .gpa = gpa,
    };
}

pub fn deinit(this: *HttpClient) void {
    this.client.deinit();
}

pub fn Response(comptime T: type) type {
    return union(enum) {
        success: std.json.Parsed(T),
        err: std.json.Parsed(Error),

        pub fn deinit(this: @This()) void {
            switch (this) {
                inline else => |r| {
                    r.deinit();
                }
            }
        }
    };
}

pub fn requestJsonBodyless(this: *HttpClient, comptime T: type, method: std.http.Method, uri: std.Uri, call_init: bool) !Response(T) {
    var req = try this.client.request(method, uri, .{});
    defer req.deinit();
    try req.sendBodiless();
    var redir_buf: [redirect_buf_size]u8 = undefined;
    var res = try req.receiveHead(&redir_buf);
    var decomp: std.http.Decompress = undefined;
    const decomp_buf = try this.gpa.alloc(u8, res.head.content_encoding.minBufferCapacity());
    defer this.gpa.free(decomp_buf);
    // why does allocRemaining need a buffer???
    var pointless_buf: [64]u8 = undefined;
    const reader = res.readerDecompressing(&pointless_buf, &decomp, decomp_buf);
    const body = try reader.allocRemaining(this.gpa, .unlimited);
    defer this.gpa.free(body);
    const class = res.head.status.class();

    const arena = try this.gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(this.gpa);
    if (class == .server_error or class == .client_error) {
        var source = std.json.Scanner.initCompleteInput(this.gpa, body);
        defer source.deinit();
        var value = try std.json.Value.jsonParse(arena.allocator(), &source, .{ .max_value_len = body.len });
        return .{ .err = try Error.init(arena, &value) };
    }
    if (call_init) {
        var source = std.json.Scanner.initCompleteInput(this.gpa, body);
        defer source.deinit();
        var value = try std.json.Value.jsonParse(arena.allocator(), &source, .{ .max_value_len = body.len });
        return .{ .success = try T.init(arena, &value) };
    } else {
        arena.deinit();
        this.gpa.destroy(arena);
        return .{ .success = try std.json.parseFromSlice(T, this.gpa, body, .{}) };
    }
}
