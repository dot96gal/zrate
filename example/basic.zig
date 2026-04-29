const std = @import("std");
const zrate = @import("zrate");

pub fn main(env: std.process.Init) !void {
    const io = env.io;

    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const stdout = &fw.interface;
    var limiter = zrate.Limiter.init(5.0, 3);

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        if (limiter.allow(io)) {
            try stdout.print("event {d}: allowed\n", .{i});
        } else {
            try stdout.print("event {d}: dropped\n", .{i});
        }
    }

    try stdout.flush();
}
