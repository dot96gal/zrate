const std = @import("std");
const zrate = @import("zrate");

pub fn main(env: std.process.Init) !void {
    const io = env.io;

    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const stdout = &fw.interface;
    var limiter = zrate.Limiter.init(zrate.every(.{ .nanoseconds = 200 * std.time.ns_per_ms }), 1);

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const r = limiter.reserve(io) orelse {
            try stdout.print("event {d}: reservation failed\n", .{i});
            continue;
        };

        const d = r.delay(io);
        if (d.nanoseconds > 0) {
            try stdout.print("event {d}: waiting {d}ms...\n", .{
                i,
                @divTrunc(d.nanoseconds, std.time.ns_per_ms),
            });
            try std.Io.sleep(io, d, .awake);
        }

        try stdout.print("event {d}: executed\n", .{i});
    }

    try stdout.flush();
}
