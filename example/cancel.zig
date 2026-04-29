const std = @import("std");
const zrate = @import("zrate");
const zctx = @import("zctx");

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;

    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const stdout = &fw.interface;
    var limiter = zrate.Limiter.init(1.0, 1);

    const cancelCtx = try zctx.withCancel(io, zctx.BACKGROUND, allocator);
    defer cancelCtx.deinit(io);

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(ctx: zctx.OwnedContext, threadIo: std.Io) void {
            std.Io.sleep(threadIo, .{ .nanoseconds = 300 * std.time.ns_per_ms }, .awake) catch return;
            ctx.cancel(threadIo);
        }
    }.run, .{ cancelCtx, io });
    defer thread.join();

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        limiter.waitN(io, cancelCtx.context, 1) catch |err| switch (err) {
            error.Canceled => {
                try stdout.print("event {d}: canceled by external signal\n", .{i});
                try stdout.flush();
                return;
            },
            error.DeadlineExceeded => unreachable,
            error.ExceedsLimit => unreachable,
        };
        try stdout.print("event {d}: executed\n", .{i});
    }

    try stdout.flush();
}
