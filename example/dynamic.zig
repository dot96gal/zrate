const std = @import("std");
const zrate = @import("zrate");

pub fn main(env: std.process.Init) !void {
    const io = env.io;

    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const stdout = &fw.interface;
    var limiter = zrate.Limiter.init(10.0, 5);

    try stdout.print("initial: limit={d}, burst={d}\n", .{
        limiter.limit(io),
        limiter.burst(io),
    });

    limiter.setLimit(io, 2.0);
    limiter.setBurst(io, 2);
    try stdout.print("throttled: limit={d}, burst={d}\n", .{
        limiter.limit(io),
        limiter.burst(io),
    });

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        if (limiter.allow(io)) {
            try stdout.print("event {d}: allowed (tokens≈{d:.2})\n", .{
                i,
                limiter.tokens(io),
            });
        } else {
            try stdout.print("event {d}: dropped\n", .{i});
        }
    }

    limiter.setLimit(io, zrate.INF);
    try stdout.print("unlimited: all following events allowed\n", .{});

    while (i < 8) : (i += 1) {
        _ = limiter.allow(io);
        try stdout.print("event {d}: allowed\n", .{i});
    }

    try stdout.flush();
}
