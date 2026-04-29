const std = @import("std");
const zrate = @import("zrate");
const zctx = @import("zctx");

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.arena.allocator();

    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const stdout = &fw.interface;
    var limiter = zrate.Limiter.init(1.0, 1);

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const timeoutCtx = try zctx.withTimeout(
            io,
            zctx.BACKGROUND,
            500 * std.time.ns_per_ms,
            allocator,
        );
        defer timeoutCtx.deinit(io);

        limiter.waitN(io, timeoutCtx.context, 1) catch |err| switch (err) {
            error.DeadlineExceeded => {
                try stdout.print("event {d}: timeout\n", .{i});
                continue;
            },
            error.Canceled => {
                try stdout.print("event {d}: canceled\n", .{i});
                continue;
            },
            error.ExceedsLimit => unreachable,
        };

        try stdout.print("event {d}: executed\n", .{i});
    }

    try stdout.flush();
}
