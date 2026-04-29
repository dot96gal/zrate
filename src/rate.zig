const std = @import("std");
const zctx = @import("zctx");
const Io = std.Io;

/// 1秒あたりのイベント数を表す型。レートリミットに利用する。
pub const Limit = f64;

/// レート無制限を示す定数。Limiter 初期化時に利用する。
pub const INF: Limit = std.math.inf(f64);

/// インターバルから Limit を生成する関数。毎 N 秒 1 イベントのレートを設定するのに利用する。
/// interval <= 0 の場合は INF を返す。
pub fn every(interval: Io.Duration) Limit {
    if (interval.nanoseconds <= 0) return INF;
    return 1e9 / @as(f64, @floatFromInt(interval.nanoseconds));
}

/// トークン予約を表す型。Reserve 系メソッドの戻り値として利用する。
/// ポインタを保持しない値型。フィールドを直接変更してはいけない。delay() / cancel() を使う。
pub const Reservation = struct {
    // 直接参照不可。消費予約済みトークン数。
    _tokens: usize,
    // 直接参照不可。トークンが利用可能になる時刻。
    _timeToAct: Io.Timestamp,
    // 直接参照不可。作成時のレート（キャンセル時の返還計算用）。
    _limit: Limit,

    /// 予約実行までの待機時間を返す関数。遅延実行パターンに利用する。
    /// 即時実行可能な場合は 0 を返す。
    pub fn delay(r: Reservation, io: Io) Io.Duration {
        const now = Io.Clock.Timestamp.now(io, .awake).raw;
        const diff = r._timeToAct.nanoseconds - now.nanoseconds;
        if (diff <= 0) return .{ .nanoseconds = 0 };
        return .{ .nanoseconds = diff };
    }

    /// 予約をキャンセルする関数。waitN がキャンセルされた際のトークン返還に利用する。
    /// 複数回呼び出しても安全（2回目以降は何もしない）。
    /// 取得元の Limiter を渡すこと。異なる Limiter を渡した場合の動作は未定義。
    pub fn cancel(r: *Reservation, io: Io, limiter: *Limiter) void {
        limiter._mu.lockUncancelable(io);
        defer limiter._mu.unlock(io);

        if (r._tokens == 0) return;
        defer r._tokens = 0;

        if (limiter._limit == INF) return;

        const now = Io.Clock.Timestamp.now(io, .awake).raw;

        const elapsedNs = limiter._lastEvent.nanoseconds - r._timeToAct.nanoseconds;
        const restoreTokens = @as(f64, @floatFromInt(r._tokens)) - (@as(f64, @floatFromInt(elapsedNs)) / 1e9 * r._limit);

        if (restoreTokens <= 0) return;

        limiter._tokens = @min(
            limiter._tokens + restoreTokens,
            @as(f64, @floatFromInt(limiter._burst)),
        );

        if (r._timeToAct.nanoseconds == limiter._lastEvent.nanoseconds) {
            const waitNs: i96 = @trunc(@as(f64, @floatFromInt(r._tokens)) / r._limit * 1e9);
            const prevNs = r._timeToAct.nanoseconds - waitNs;
            if (prevNs >= now.nanoseconds) {
                limiter._lastEvent = .{ .nanoseconds = prevNs };
            }
        }
    }
};

/// wait / waitN が返すエラーの型。エラーハンドリングに利用する。
pub const WaitError = error{
    /// コンテキストがキャンセルされた。
    Canceled,
    /// コンテキストのデッドラインを超過した。
    DeadlineExceeded,
    /// 要求トークン数がバースト容量を超えており、永遠に実行不能。
    ExceedsLimit,
};

/// トークンバケット方式のレートリミッタの型。イベント頻度の制御に利用する。
/// フィールドを直接変更してはいけない。状態変更には setLimit / setBurst を使う。
pub const Limiter = struct {
    // 直接参照不可。並行アクセス制御用ミューテックス。
    _mu: Io.Mutex,
    // 直接参照不可。現在のレート（1秒あたりの最大イベント数）。
    _limit: Limit,
    // 直接参照不可。バースト容量（同時消費可能な最大トークン数）。
    _burst: usize,
    // 直接参照不可。現在のトークン残量。
    _tokens: f64,
    // 直接参照不可。トークン補充計算の基準となる最終更新時刻。
    _last: Io.Timestamp,
    // 直接参照不可。最終予約実行時刻（キャンセル時の返還計算用）。
    _lastEvent: Io.Timestamp,

    /// 新しい Limiter を初期化する関数。レートとバースト容量を指定するのに利用する。
    /// 初期トークン数は float(burstSize)（バースト満杯の状態）。最初の burstSize 個のイベントは即時実行される。
    pub fn init(rate: Limit, burstSize: usize) Limiter {
        return .{
            ._mu = .init,
            ._limit = rate,
            ._burst = burstSize,
            ._tokens = @floatFromInt(burstSize),
            ._last = .{ .nanoseconds = 0 },
            ._lastEvent = .{ .nanoseconds = 0 },
        };
    }

    /// 1トークンを即座に消費できるか確認する関数。イベントのドロップ判定に利用する。
    pub fn allow(limiter: *Limiter, io: Io) bool {
        const now = Io.Clock.Timestamp.now(io, .awake).raw;
        return limiter.allowAt(io, now, 1);
    }

    /// 1トークンを予約する関数。遅延実行パターンに利用する。
    /// null は _burst == 0 または _limit == 0 で予約不可の場合。
    pub fn reserve(limiter: *Limiter, io: Io) ?Reservation {
        const now = Io.Clock.Timestamp.now(io, .awake).raw;
        return limiter.reserveAt(io, now, 1, Io.Duration.max);
    }

    /// 1トークンが利用可能になるまで待機する関数。コンテキスト付きブロッキング処理に利用する。
    pub fn wait(limiter: *Limiter, io: Io, ctx: zctx.Context) WaitError!void {
        return limiter.waitN(io, ctx, 1);
    }

    /// n トークンが利用可能になるまで待機する関数。コンテキスト付きブロッキング処理に利用する。
    /// n > _burst の場合は error.ExceedsLimit を返す。
    /// ctx のデッドラインを超える場合は error.DeadlineExceeded を返す。
    pub fn waitN(limiter: *Limiter, io: Io, ctx: zctx.Context, n: usize) WaitError!void {
        if (n > limiter._burst) return error.ExceedsLimit;

        if (ctx.err(io)) |err| return err;

        const now = Io.Clock.Timestamp.now(io, .awake);

        const maxFutureReserve: Io.Duration = if (ctx.deadline()) |dl| blk: {
            const remaining = dl.raw.nanoseconds - now.raw.nanoseconds;
            if (remaining <= 0) return error.DeadlineExceeded;
            break :blk .{ .nanoseconds = remaining };
        } else Io.Duration.max;

        var r = limiter.reserveAt(io, now.raw, n, maxFutureReserve) orelse {
            return ctx.err(io) orelse error.DeadlineExceeded;
        };

        const d = r.delay(io);
        if (d.nanoseconds <= 0) return;

        const delayNs = std.math.cast(u64, d.nanoseconds) orelse std.math.maxInt(u64);
        const cancelled = ctx.done().waitTimeout(io, delayNs);
        if (cancelled) {
            r.cancel(io, limiter);
            return ctx.err(io) orelse error.Canceled;
        }
    }

    /// レート値を更新する関数。実行中のレート変更に利用する。
    pub fn setLimit(limiter: *Limiter, io: Io, newLimit: Limit) void {
        const now = Io.Clock.Timestamp.now(io, .awake).raw;
        limiter.setLimitAt(io, now, newLimit);
    }

    /// バースト容量を更新する関数。実行中のバースト変更に利用する。
    pub fn setBurst(limiter: *Limiter, io: Io, newBurst: usize) void {
        const now = Io.Clock.Timestamp.now(io, .awake).raw;
        limiter.setBurstAt(io, now, newBurst);
    }

    /// 現在のレート値を返す関数。設定値の確認に利用する。
    pub fn limit(limiter: *Limiter, io: Io) Limit {
        limiter._mu.lockUncancelable(io);
        defer limiter._mu.unlock(io);
        return limiter._limit;
    }

    /// 現在のバースト容量を返す関数。設定値の確認に利用する。
    pub fn burst(limiter: *Limiter, io: Io) usize {
        limiter._mu.lockUncancelable(io);
        defer limiter._mu.unlock(io);
        return limiter._burst;
    }

    /// 現在のトークン数を返す関数。利用可能トークンの確認に利用する。
    pub fn tokens(limiter: *Limiter, io: Io) f64 {
        limiter._mu.lockUncancelable(io);
        defer limiter._mu.unlock(io);
        const now = Io.Clock.Timestamp.now(io, .awake).raw;
        return limiter.tokensAt(now);
    }

    fn allowAt(limiter: *Limiter, io: Io, t: Io.Timestamp, n: usize) bool {
        const r = limiter.reserveAt(io, t, n, .{ .nanoseconds = 0 });
        return r != null;
    }

    fn reserveAt(
        limiter: *Limiter,
        io: Io,
        t: Io.Timestamp,
        n: usize,
        maxFutureReserve: Io.Duration,
    ) ?Reservation {
        limiter._mu.lockUncancelable(io);
        defer limiter._mu.unlock(io);

        if (limiter._limit == INF) {
            return Reservation{
                ._tokens = n,
                ._timeToAct = t,
                ._limit = limiter._limit,
            };
        }

        if (limiter._limit == 0) return null;

        var currentTokens = limiter.tokensAt(t);
        currentTokens -= @as(f64, @floatFromInt(n));

        var waitDurationNs: i96 = 0;
        if (currentTokens < 0) {
            waitDurationNs = @trunc(-currentTokens / limiter._limit * 1e9);
        }

        const ok = (n <= limiter._burst) and (waitDurationNs <= maxFutureReserve.nanoseconds);
        const timeToAct = Io.Timestamp{ .nanoseconds = t.nanoseconds + waitDurationNs };

        if (!ok) return null;

        limiter._tokens = currentTokens;
        limiter._last = t;
        limiter._lastEvent = timeToAct;

        return Reservation{
            ._tokens = n,
            ._timeToAct = timeToAct,
            ._limit = limiter._limit,
        };
    }

    fn setLimitAt(limiter: *Limiter, io: Io, t: Io.Timestamp, newLimit: Limit) void {
        limiter._mu.lockUncancelable(io);
        defer limiter._mu.unlock(io);
        limiter._tokens = limiter.tokensAt(t);
        limiter._last = t;
        limiter._limit = newLimit;
    }

    fn setBurstAt(limiter: *Limiter, io: Io, t: Io.Timestamp, newBurst: usize) void {
        limiter._mu.lockUncancelable(io);
        defer limiter._mu.unlock(io);
        limiter._tokens = limiter.tokensAt(t);
        limiter._last = t;
        limiter._burst = newBurst;
    }

    fn tokensAt(limiter: *Limiter, t: Io.Timestamp) f64 {
        if (limiter._limit == INF) return @floatFromInt(limiter._burst);
        const elapsedNs = t.nanoseconds - limiter._last.nanoseconds;
        const delta = @as(f64, @floatFromInt(elapsedNs)) / 1e9 * limiter._limit;
        return @min(limiter._tokens + delta, @as(f64, @floatFromInt(limiter._burst)));
    }
};

// --- テスト ---

test "every: interval=0 returns INF" {
    try std.testing.expect(every(.{ .nanoseconds = 0 }) == INF);
}

test "every: 100ms interval = 10 events/sec" {
    const rate = every(.{ .nanoseconds = 100 * std.time.ns_per_ms });
    try std.testing.expectApproxEqAbs(10.0, rate, 0.001);
}

test "allow: burst within is true, exceeded is false" {
    const io = std.testing.io;
    var limiter = Limiter.init(5.0, 3);
    try std.testing.expect(limiter.allow(io));
    try std.testing.expect(limiter.allow(io));
    try std.testing.expect(limiter.allow(io));
    try std.testing.expect(!limiter.allow(io));
}

test "allowAt: token replenishment over time" {
    const io = std.testing.io;
    var limiter = Limiter.init(1.0, 1);
    const t0 = Io.Timestamp{ .nanoseconds = 0 };
    const t1 = Io.Timestamp{ .nanoseconds = std.time.ns_per_s };

    try std.testing.expect(limiter.allowAt(io, t0, 1));
    try std.testing.expect(!limiter.allowAt(io, t0, 1));
    try std.testing.expect(limiter.allowAt(io, t1, 1));
}

test "reserve: returns Reservation" {
    const io = std.testing.io;
    var limiter = Limiter.init(1.0, 1);
    const r = limiter.reserve(io);
    try std.testing.expect(r != null);
}

test "reserve: burst=0 returns null" {
    const io = std.testing.io;
    var limiter = Limiter.init(1.0, 0);
    const r = limiter.reserve(io);
    try std.testing.expect(r == null);
}

test "reservation cancel: idempotent" {
    const io = std.testing.io;
    var limiter = Limiter.init(1.0, 1);
    var r = limiter.reserve(io) orelse return error.TestUnexpectedNull;
    r.cancel(io, &limiter);
    r.cancel(io, &limiter);
}

test "waitN: ExceedsLimit when n > burst" {
    const io = std.testing.io;
    var limiter = Limiter.init(1.0, 3);
    try std.testing.expectError(error.ExceedsLimit, limiter.waitN(io, zctx.BACKGROUND, 4));
}

test "waitN: Canceled immediately" {
    const io = std.testing.io;
    var limiter = Limiter.init(0.001, 1);
    try std.testing.expectError(error.Canceled, limiter.waitN(io, zctx.CANCELED, 1));
}

test "waitN: DeadlineExceeded with past deadline" {
    const io = std.testing.io;
    var limiter = Limiter.init(0.001, 1);
    const pastDeadline = Io.Clock.Timestamp{
        .raw = .{ .nanoseconds = 0 },
        .clock = .awake,
    };
    const ctx = try zctx.withDeadline(io, zctx.BACKGROUND, pastDeadline, std.testing.allocator);
    defer ctx.deinit(io);
    try std.testing.expectError(error.DeadlineExceeded, limiter.waitN(io, ctx.context, 1));
}

test "waitN: immediate when tokens available" {
    const io = std.testing.io;
    var limiter = Limiter.init(10.0, 5);
    try limiter.waitN(io, zctx.BACKGROUND, 1);
}

test "setLimit: updates rate" {
    const io = std.testing.io;
    var limiter = Limiter.init(10.0, 5);
    try std.testing.expectEqual(@as(Limit, 10.0), limiter.limit(io));
    limiter.setLimit(io, 2.0);
    try std.testing.expectEqual(@as(Limit, 2.0), limiter.limit(io));
}

test "setBurst: updates burst" {
    const io = std.testing.io;
    var limiter = Limiter.init(10.0, 5);
    try std.testing.expectEqual(@as(usize, 5), limiter.burst(io));
    limiter.setBurst(io, 2);
    try std.testing.expectEqual(@as(usize, 2), limiter.burst(io));
}

test "tokens: returns current token count" {
    const io = std.testing.io;
    var limiter = Limiter.init(10.0, 5);
    try std.testing.expectApproxEqAbs(5.0, limiter.tokens(io), 0.01);
    _ = limiter.allow(io);
    try std.testing.expectApproxEqAbs(4.0, limiter.tokens(io), 0.01);
}

test "INF rate: always allows" {
    const io = std.testing.io;
    var limiter = Limiter.init(INF, 1);
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try std.testing.expect(limiter.allow(io));
    }
}

test "waitN: delays when tokens insufficient" {
    const io = std.testing.io;
    // 1ns あたり 1 トークン補充。バースト消費後の次トークンは ~1ns 待ち
    var limiter = Limiter.init(every(.{ .nanoseconds = 1 }), 1);
    _ = limiter.allow(io);
    try limiter.waitN(io, zctx.BACKGROUND, 1);
}

test "waitN: DeadlineExceeded via maxFutureReserve calculation" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    // レート 0.001/sec → バースト消費後の待機 ~1000 秒
    var limiter = Limiter.init(0.001, 1);
    _ = limiter.allow(io);
    // デッドライン 1ms: waitDurationNs(~1000s) >> maxFutureReserve(1ms) → reserveAt が null を返す
    const ctx = try zctx.withTimeout(io, zctx.BACKGROUND, std.time.ns_per_ms, allocator);
    defer ctx.deinit(io);
    try std.testing.expectError(error.DeadlineExceeded, limiter.waitN(io, ctx.context, 1));
}

test "reservation cancel: restores tokens" {
    const io = std.testing.io;
    var limiter = Limiter.init(1.0, 3);
    const t0 = Io.Timestamp{ .nanoseconds = 0 };

    // t0 で 2 トークン消費 → tokens = 1.0
    _ = limiter.allowAt(io, t0, 1);
    _ = limiter.allowAt(io, t0, 1);

    // t0 で 1 トークン予約 → tokens = 0.0
    var r = limiter.reserveAt(io, t0, 1, Io.Duration.max) orelse return error.TestUnexpectedNull;

    // キャンセルで 1 トークン返還 → tokens = 1.0
    r.cancel(io, &limiter);
    try std.testing.expectApproxEqAbs(1.0, limiter.tokensAt(t0), 0.001);
}

test "thread safety: concurrent allow" {
    const io = std.testing.io;
    var limiter = Limiter.init(1000.0, 1000);

    const threadCount = 8;
    var threads: [threadCount]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(lim: *Limiter, tio: std.Io) void {
                var j: usize = 0;
                while (j < 100) : (j += 1) _ = lim.allow(tio);
            }
        }.run, .{ &limiter, io });
    }
    for (&threads) |t| t.join();
}

test "thread safety: concurrent setLimit and allow" {
    const io = std.testing.io;
    var limiter = Limiter.init(10.0, 10);

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(lim: *Limiter, tio: std.Io) void {
            var j: usize = 0;
            while (j < 100) : (j += 1) {
                lim.setLimit(tio, 20.0);
                lim.setBurst(tio, 20);
            }
        }
    }.run, .{ &limiter, io });

    var i: usize = 0;
    while (i < 100) : (i += 1) _ = limiter.allow(io);
    thread.join();
}
