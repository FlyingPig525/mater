const std = @import("std");
const Error = @import("Error.zig");

const HttpClient = @This();

const redirect_buf_size = 8000;

client: std.http.Client,
gpa: std.mem.Allocator,

const localhost = "localhost";
pub fn init(gpa: std.mem.Allocator, io: std.Io) !HttpClient {
    return .{
        .client = .{
            .io = io,
            .allocator = gpa,
        },
        .gpa = gpa,
    };
}

pub fn deinit(this: *HttpClient) void {
    this.client.deinit();
}

const Parsed = std.json.Parsed;

pub fn Response(comptime T: type) type {
    return union(enum) {
        success: Parsed(T),
        err: Parsed(Error),

        pub fn deinit(this: @This()) void {
            switch (this) {
                inline else => |r| {
                    r.deinit();
                },
            }
        }
    };
}

pub fn requestJsonBodyless(
    this: *HttpClient,
    comptime T: type,
    method: std.http.Method,
    uri: std.Uri,
) !Response(T) {
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
    var source = std.json.Scanner.initCompleteInput(this.gpa, body);
    defer source.deinit();
    var value = try std.json.Value.jsonParse(arena.allocator(), &source, .{ .max_value_len = body.len });
    return .{ .success = try T.parse(arena, &value) };
}

pub fn requestJson(
    this: *HttpClient,
    comptime T: type,
    method: std.http.Method,
    uri: std.Uri,
    req_body: std.json.Value,
) !Response(T) {
    var req = try this.client.request(method, uri, .{});
    defer req.deinit();
    var allocating = std.Io.Writer.Allocating.init(this.gpa);
    defer allocating.deinit();
    try std.json.Stringify.value(req_body, .{}, &allocating.writer);
    try req.sendBodyComplete(allocating.written());
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
    var source = std.json.Scanner.initCompleteInput(this.gpa, body);
    defer source.deinit();
    var value = try std.json.Value.jsonParse(arena.allocator(), &source, .{ .max_value_len = body.len });
    return .{ .success = try T.parse(arena, &value) };
}
