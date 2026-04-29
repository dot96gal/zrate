const rate = @import("rate.zig");

pub const Limit = rate.Limit;
pub const INF = rate.INF;
pub const every = rate.every;
pub const Reservation = rate.Reservation;
pub const WaitError = rate.WaitError;
pub const Limiter = rate.Limiter;

test {
    _ = @import("rate.zig");
}
