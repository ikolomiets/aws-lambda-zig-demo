const std = @import("std");
const lambda = @import("aws-lambda");

pub fn main(init: std.process.Init) void {
    lambda.handle(init, handler, .{});
}

fn handler(ctx: lambda.Context, _: []const u8) ![]const u8 {
    return lambda.url.encodeResponse(ctx.arena, .{
        .content_type = "text/plain; charset=utf-8",
        .body = .{ .textual = "Hello, world!" },
    });
}
