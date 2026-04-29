# zrate 実装計画

作成日: 2026-04-29

## 概要

Go の [`golang.org/x/time/rate`](https://pkg.go.dev/golang.org/x/time/rate) を Zig 0.16.0 に移植するレートリミットライブラリ。  
**トークンバケット**アルゴリズムを基盤とし、イベント頻度の制御とバースト処理に対応する。

---

## 実現性評価

### 利用可能な Zig 0.16.0 標準ライブラリ機能

| Go の機能 | Zig 0.16.0 の対応 | 備考 |
|-----------|------------------|------|
| `sync.Mutex` | `std.Io.Mutex` | `io: Io` パラメータが必要 |
| `time.Time` | `std.Io.Timestamp` (i96 ナノ秒) | `Io.Clock.Timestamp` でクロック情報付き |
| `time.Duration` | `std.Io.Duration` (i96 ナノ秒) | |
| `time.Sleep` | `std.Io.sleep(io, duration, clock)` | `Cancelable!void` — キャンセル可能 |
| `context.Context` | `std.Io.Cancelable` / `zctx.Context` | `io` のみ: `error.Canceled` のみ。zctx 採用時は `deadline()` も取得可能 |
| `float64` | `f64` | トークン数計算に使用 |

### 主な差異・制約

1. **Mutex のキャンセル可能性**  
   Go の `sync.Mutex.Lock()` は失敗しないが、`std.Io.Mutex.lock(io)` は `Cancelable!void`。  
   → 内部クリティカルセクションでは `lockUncancelable` を使用し、確実にロックを取得する。

2. **コンテキストのデッドライン取得**  
   Go の `WaitN` は `ctx.Deadline()` で待機上限を事前計算するが、Zig の `io` には直接デッドライン取得 API がない。  
   → `io` のみの場合: `waitN` に `max_wait: ?Io.Duration` パラメータで代替。  
   → **zctx 採用時**: `ctx.deadline()` が `?Io.Clock.Timestamp` を返すため Go と同等の実装が可能。

3. **非同期モデル**  
   Zig 0.16.0 の `Io` インタフェースは vtable ベースで、スレッドブロッキングと非同期ランタイムの両方をサポートする。  
   → ライブラリ側では `Io` を受け取るだけでよく、実行モデルは呼び出し元が制御する。

**結論: 完全実装は実現可能。** コア API（Allow/Reserve/Wait）はすべて Zig 0.16.0 で実装できる。

---

## ファイル構成

```
src/
  root.zig          ← ライブラリエントリポイント（public API 再エクスポート）
  rate.zig          ← Limiter・Reservation・Limit の実装
example/
  basic.zig         ← allow() によるイベントドロップパターン
  reserve.zig       ← reserve() による遅延実行パターン
  wait.zig          ← waitN() + withTimeout によるブロッキング待機パターン
  cancel.zig        ← waitN() + withCancel による手動キャンセルパターン
  dynamic.zig       ← setLimit/setBurst による動的設定変更パターン
```

---

## サンプルコード計画

各サンプルは `zig build run-example-<name>` で実行できるよう `mise.toml` にタスクを追加する。

---

### example/basic.zig — allow() パターン

**目的**: `allow()` を使ったイベントドロップの最小構成。レート超過時にイベントを捨てるユースケース（ログ出力・モニタリングなど）。

```zig
const std = @import("std");
const zrate = @import("zrate");

pub fn main(env: std.process.Init) !void {
    const io = env.io;

    // 5 events/sec、バースト 3
    var limiter = zrate.Limiter.init(5.0, 3);

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        if (limiter.allow(io)) {
            std.debug.print("event {d}: allowed\n", .{i});
        } else {
            std.debug.print("event {d}: dropped\n", .{i});
        }
    }
}
```

**期待される出力例**:
```
event 0: allowed   ← バースト消費
event 1: allowed   ← バースト消費
event 2: allowed   ← バースト消費
event 3: dropped   ← バースト枯渇
event 4: dropped
...
```

---

### example/reserve.zig — reserve() パターン

**目的**: `reserve()` による遅延実行パターン。キャンセル不可・遅延許容のワークロード（バッチ処理・API 呼び出しなど）に使用。

```zig
const std = @import("std");
const zrate = @import("zrate");

pub fn main(env: std.process.Init) !void {
    const io = env.io;

    // every(200ms) = 5 events/sec、バースト 1
    var limiter = zrate.Limiter.init(zrate.every(.{ .nanoseconds = 200 * std.time.ns_per_ms }), 1);

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const r = limiter.reserve(io) orelse {
            std.debug.print("event {d}: reservation failed\n", .{i});
            continue;
        };

        const d = r.delay(io);
        if (d.nanoseconds > 0) {
            std.debug.print("event {d}: waiting {d}ms...\n", .{
                i,
                @divTrunc(d.nanoseconds, std.time.ns_per_ms),
            });
            try std.Io.sleep(io, d, .awake);
        }

        std.debug.print("event {d}: executed\n", .{i});
    }
}
```

**期待される出力例**:
```
event 0: executed              ← 即時実行（バースト）
event 1: waiting 200ms...
event 1: executed
event 2: waiting 200ms...
event 2: executed
...
```

---

### example/wait.zig — waitN() + withTimeout パターン

**目的**: `waitN()` と `zctx.withTimeout` を組み合わせた、タイムアウト付きブロッキング待機。HTTP サーバーのリクエストハンドラなど、応答時間に上限が必要なユースケース。

```zig
const std = @import("std");
const zrate = @import("zrate");
const zctx = @import("zctx");

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.arena.allocator();

    // 1 event/sec、バースト 1
    var limiter = zrate.Limiter.init(1.0, 1);

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        // 500ms のタイムアウト付きコンテキスト
        const timeoutCtx = try zctx.withTimeout(
            io,
            zctx.BACKGROUND,
            500 * std.time.ns_per_ms,
            allocator,
        );
        defer timeoutCtx.deinit(io);

        limiter.waitN(io, timeoutCtx.context, 1) catch |err| switch (err) {
            error.DeadlineExceeded => {
                std.debug.print("event {d}: timeout\n", .{i});
                continue;
            },
            error.Canceled => {
                std.debug.print("event {d}: canceled\n", .{i});
                continue;
            },
            error.ExceedsLimit => unreachable, // 1 <= burst=1 なので起こりえない
        };

        std.debug.print("event {d}: executed\n", .{i});
    }
}
```

**期待される出力例**:
```
event 0: executed              ← 即時（バースト）
event 1: executed              ← 約 1s 待機後
event 2: timeout               ← 500ms 以内に許可が来なかった
event 3: timeout
event 4: timeout
```

---

### example/cancel.zig — waitN() + withCancel パターン

**目的**: `waitN()` と `zctx.withCancel` を組み合わせた手動キャンセル。シグナルハンドラや別タスクからの停止指示に対応するユースケース。

```zig
const std = @import("std");
const zrate = @import("zrate");
const zctx = @import("zctx");

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;

    // 1 event/sec、バースト 1
    var limiter = zrate.Limiter.init(1.0, 1);

    // キャンセル可能なコンテキストを作成
    const cancelCtx = try zctx.withCancel(io, zctx.BACKGROUND, allocator);
    defer cancelCtx.deinit(io);

    // 300ms 後に別スレッドからキャンセルを発火
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(ctx: zctx.OwnedContext, thread_io: std.Io) void {
            std.Io.sleep(thread_io, std.Io.Duration{ .nanoseconds = 300 * std.time.ns_per_ms }, .awake) catch |err| {
                std.debug.print("sleep interrupted: {}\n", .{err});
                return;
            };
            ctx.cancel(thread_io);
        }
    }.run, .{ cancelCtx, io });
    defer thread.join();

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        limiter.waitN(io, cancelCtx.context, 1) catch |err| switch (err) {
            error.Canceled => {
                std.debug.print("event {d}: canceled by external signal\n", .{i});
                return;
            },
            error.DeadlineExceeded => unreachable,
            error.ExceedsLimit => unreachable, // 1 <= burst=1 なので起こりえない
        };
        std.debug.print("event {d}: executed\n", .{i});
    }
}
```

**期待される出力例**:
```
event 0: executed              ← 即時（バースト）
event 1: canceled by external signal  ← 300ms 後にキャンセル発火
```

---

### example/dynamic.zig — setLimit/setBurst パターン

**目的**: `setLimit`・`setBurst` による動的レート変更。負荷に応じてスロットルを絞る・緩めるアダプティブレートリミット。

```zig
const std = @import("std");
const zrate = @import("zrate");

pub fn main(env: std.process.Init) !void {
    const io = env.io;

    // 初期設定: 10 events/sec、バースト 5
    var limiter = zrate.Limiter.init(10.0, 5);

    std.debug.print("initial: limit={d}, burst={d}\n", .{
        limiter.limit(io),
        limiter.burst(io),
    });

    // 高負荷時：レートを絞る
    limiter.setLimit(io, 2.0);
    limiter.setBurst(io, 2);
    std.debug.print("throttled: limit={d}, burst={d}\n", .{
        limiter.limit(io),
        limiter.burst(io),
    });

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        if (limiter.allow(io)) {
            std.debug.print("event {d}: allowed (tokens≈{d:.2})\n", .{
                i,
                limiter.tokens(io),
            });
        } else {
            std.debug.print("event {d}: dropped\n", .{i});
        }
    }

    // 負荷低下時：レートを戻す
    limiter.setLimit(io, zrate.INF);
    std.debug.print("unlimited: all following events allowed\n", .{});

    while (i < 8) : (i += 1) {
        _ = limiter.allow(io);
        std.debug.print("event {d}: allowed\n", .{i});
    }
}
```

**期待される出力例**:
```
initial: limit=10, burst=5
throttled: limit=2, burst=2
event 0: allowed (tokens≈1.00)
event 1: allowed (tokens≈0.00)
event 2: dropped
event 3: dropped
event 4: dropped
unlimited: all following events allowed
event 5: allowed
event 6: allowed
event 7: allowed
```

---

## API 設計

### `Limit` 型

```zig
/// 1秒あたりのイベント数を表す型。レートリミットに利用する。
pub const Limit = f64;

/// レート無制限を示す定数。Limiter 初期化時に利用する。
pub const INF: Limit = std.math.inf(f64);

/// インターバルから Limit を生成する関数。毎 N 秒 1 イベントのレートを設定するのに利用する。
/// interval == 0 の場合は INF を返す。
pub fn every(interval: Io.Duration) Limit
```

### `Reservation` 型

```zig
/// トークン予約を表す型。Reserve 系メソッドの戻り値として利用する。
/// ポインタを保持しない値型。フィールドを直接変更してはいけない。delay() / cancel() を使う。
pub const Reservation = struct {
    _tokens: usize,           // 内部実装。0 はキャンセル済みのセンチネル値（cancel 後にゼロクリアされる）
    _timeToAct: Io.Timestamp, // 内部実装
    _limit: Limit,            // 内部実装

    /// 予約実行までの待機時間を返す関数。遅延実行パターンに利用する。
    /// 即時実行可能な場合は 0 を返す。
    pub fn delay(r: Reservation, io: Io) Io.Duration

    /// 予約をキャンセルする関数。waitN がキャンセルされた際のトークン返還に利用する。
    /// 複数回呼び出しても安全（2回目以降は何もしない）。
    /// 取得元の Limiter を渡すこと。異なる Limiter を渡した場合の動作は未定義。
    pub fn cancel(r: *Reservation, io: Io, limiter: *Limiter) void
};
```

### `Reservation.cancel()` のアルゴリズム

**何をする関数か**: 予約済みトークンを Limiter に返還する。  
単純に `_tokens += n` するのではなく、**後続予約がすでに待機時間を前提としている場合は返還量を減らす**。  
これにより後続予約の待機キューが崩れるのを防ぐ（Go の `CancelAt` と同等）。

```
cancel(io, limiter):
  limiter._mu.lockUncancelable(io)
  defer limiter._mu.unlock(io)

  if _tokens == 0:
    return              ← 2回目以降の呼び出しは何もしない（冪等性。n >= 1 が前提なのでゼロ = キャンセル済み）
  defer { _tokens = 0; }  ← 関数終了時にゼロクリア（以降の cancel 呼び出しを無効化）

  if limiter._limit == INF:
    return              ← 無制限レートなら返還不要（defer でゼロクリアされる）

  now = Io.Timestamp.now(io, .awake)   ← 現在時刻を取得（_lastEvent 巻き戻し判定に使用）

  // 返還可能トークン数を計算
  // 後続予約が waiting している分（_timeToAct 〜 _lastEvent 間）は
  // すでに「消費済み」として計上されているため、その分を差し引く
  //
  //   restoreTokens = float(_tokens)
  //                   - tokensFromDuration(limiter._lastEvent - r._timeToAct)
  //   tokensFromDuration(d) = d.nanoseconds_as_sec * _limit
  //
  elapsed_ns = limiter._lastEvent.nanoseconds - _timeToAct.nanoseconds
               ← _timeToAct 〜 _lastEvent 間のナノ秒差（i96）
  restore_tokens = @as(f64, @floatFromInt(_tokens))
                   - (@as(f64, @floatFromInt(elapsed_ns)) / 1e9 * _limit)
                   ← _limit は r._limit（予約時のレート）を使用
  if restore_tokens <= 0:
    return              ← 後続予約が先行しているため返還不要

  limiter._tokens = @min(limiter._tokens + restore_tokens, @floatFromInt(limiter._burst))

  // _lastEvent を巻き戻す（キャンセルによって後続予約の待機時間が短くなる）
  if _timeToAct.nanoseconds == limiter._lastEvent.nanoseconds:
    // キャンセルされた予約が「最後の予約」だった場合のみ巻き戻す
    prev_ns = _timeToAct.nanoseconds
              - @as(i96, @intFromFloat(@as(f64, @floatFromInt(_tokens)) / _limit * 1e9))
    if prev_ns >= now.nanoseconds:
      limiter._lastEvent = .{ .nanoseconds = prev_ns }
```

**`_lastEvent` の役割のまとめ**:
- `reserveAt` で予約成功時に `_lastEvent = _timeToAct` と更新される（「最後に予約したイベントの実行時刻」）
- `cancel` では「自分の予約が _lastEvent だった場合のみ」_lastEvent を巻き戻す
- 予約の途中に別の予約が入った場合は `_lastEvent` が更新されているため巻き戻しは起きない（後続予約を守る）

---

### `WaitError` 型

```zig
/// wait / waitN の返すエラーの型。
pub const WaitError = error{
    /// コンテキストがキャンセルされた。
    Canceled,
    /// コンテキストのデッドラインを超過した。
    DeadlineExceeded,
    /// 要求トークン数がバースト容量を超えており、永遠に実行不能。
    ExceedsLimit,
};
```

---

### `Limiter` 型

```zig
/// トークンバケット方式のレートリミッタの型。イベント頻度の制御に利用する。
/// フィールドを直接変更してはいけない。状態変更には setLimit / setBurst を使う。
pub const Limiter = struct {
    _mu: Io.Mutex = Io.Mutex.init, // 内部実装。直接アクセス禁止（Io.Mutex.init がゼロ値）
    _limit: Limit,            // 内部実装。limit() / setLimit() を使う
    _burst: usize,            // 内部実装。burst() / setBurst() を使う
    _tokens: f64,             // 内部実装。tokens() を使う
    _last: Io.Timestamp,      // 内部実装
    _lastEvent: Io.Timestamp, // 内部実装

    /// 新しい Limiter を初期化する関数。レートとバースト容量を指定するのに利用する。
    /// 初期トークン数は float(burst)（バースト満杯の状態）。最初の burst 個のイベントは即時実行される。
    /// `_mu` は Io.Mutex.init（ゼロ値）で初期化する。`_last`・`_lastEvent` は Io.Timestamp.zero。
    pub fn init(rate: Limit, burst: usize) Limiter

    // --- 公開 API: ノンブロッキング ---

    /// 1トークンを即座に消費できるか確認する関数。イベントのドロップ判定に利用する。
    pub fn allow(limiter: *Limiter, io: Io) bool

    // --- 公開 API: 予約型 ---

    /// 1トークンを予約する関数。遅延実行パターンに利用する。
    /// null は _burst == 0 で予約不可の場合、または _limit == 0 の場合。
    /// 注意: _limit == 0 はバースト残量に関わらず常に null を返す。
    /// これは Go の参照実装（limit==0 でもバースト消費は可能）と異なる意図的な設計差異。
    pub fn reserve(limiter: *Limiter, io: Io) ?Reservation

    // --- 公開 API: ブロッキング（コンテキスト対応）---

    /// 1トークンが利用可能になるまで待機する関数。コンテキスト付きブロッキング処理に利用する。
    pub fn wait(limiter: *Limiter, io: Io, ctx: zctx.Context) WaitError!void

    /// n トークンが利用可能になるまで待機する関数。コンテキスト付きブロッキング処理に利用する。
    /// n > _burst の場合は error.ExceedsLimit を返す。
    /// ctx のデッドラインを超える場合は error.DeadlineExceeded を返す。
    pub fn waitN(limiter: *Limiter, io: Io, ctx: zctx.Context, n: usize) WaitError!void

    // --- 公開 API: 動的設定変更 ---

    /// レート値を更新する関数。実行中のレート変更に利用する。
    pub fn setLimit(limiter: *Limiter, io: Io, new_limit: Limit) void
    /// バースト容量を更新する関数。実行中のバースト変更に利用する。
    pub fn setBurst(limiter: *Limiter, io: Io, new_burst: usize) void

    // --- 公開 API: 状態参照 ---

    /// 現在のレート値を返す関数。設定値の確認に利用する。
    pub fn limit(limiter: *Limiter, io: Io) Limit
    /// 現在のバースト容量を返す関数。設定値の確認に利用する。
    pub fn burst(limiter: *Limiter, io: Io) usize
    /// 現在のトークン数を返す関数。利用可能トークンの確認に利用する。
    pub fn tokens(limiter: *Limiter, io: Io) f64

    // --- 内部ヘルパー（pub なし。同一ファイルのテストからアクセス可）---

    // t: Io.Timestamp を受け取る以下の関数は時刻注入用の内部実装。
    // 公開 API は now() を内部で取得してこれらに委譲する。

    // allow(io) から呼ばれる。n トークンの即時消費チェック。
    fn allowAt(limiter: *Limiter, io: Io, t: Io.Timestamp, n: usize) bool

    // reserve(io) / waitN(io, ctx, n) から呼ばれる。n トークンの予約。
    fn reserveAt(
        limiter: *Limiter,
        io: Io,
        t: Io.Timestamp,
        n: usize,
        maxFutureReserve: Io.Duration,
    ) ?Reservation

    // setLimit(io, new_limit) から呼ばれる。指定時刻基準でのレート更新。
    fn setLimitAt(limiter: *Limiter, io: Io, t: Io.Timestamp, new_limit: Limit) void

    // setBurst(io, new_burst) から呼ばれる。指定時刻基準でのバースト更新。
    fn setBurstAt(limiter: *Limiter, io: Io, t: Io.Timestamp, new_burst: usize) void

    // tokens(io) から呼ばれる。指定時刻のトークン数計算。io は不要（純粋関数）。
    fn tokensAt(limiter: *Limiter, t: Io.Timestamp) f64
};
```

---

## アルゴリズム詳細

### トークンバケットとは

レートリミットの核心となる考え方。「バケツにトークン（許可証）を貯めておき、イベントが来るたびに消費する」という仕組み。

```
[トークンバケット イメージ]

時間 →  0秒    1秒    2秒    3秒
        ↓      ↓      ↓      ↓
補充:  +limit +limit +limit +limit  （毎秒 _limit 個ずつ追加）
        ___________
バケツ |● ● ●|  ← _burst=3 が上限（それ以上は溢れる）
       |_______|

イベント発生 → トークンを 1 個消費
トークン不足 → 拒否 or 補充されるまで待機
```

**2つの主要パラメータ**:
- `_limit`: 1秒あたりに補充されるトークン数（= 許可レート）
- `_burst`: バケツの容量（= 瞬間的に許可できる最大イベント数）

**ポイント**: バケツが満杯の状態からスタートすれば、最初の `_burst` 個のイベントは待ち時間なしで処理できる（バースト処理）。

---

### トークンバケット更新（`advance` 相当）

**何をする関数か**: 「時刻 `t` の時点でトークンは何個あるか」を計算する。  
実際にリアルタイムでトークンを足し続けるのではなく、「前回更新からの経過時間 × レート」で遅延計算する（ **遅延評価** ）。

```
tokensAt(t):
  if _limit == INF:
    return float(_burst)         ← 無制限レートなら常にバケツ満杯
  elapsed = t - _last            ← 前回更新時刻からの経過時間（ナノ秒）
  delta = elapsed_sec * _limit   ← その間に補充されたトークン数
  return min(_tokens + delta, float(_burst))
                                 ← 補充後もバケツ容量を超えない
                                 ← 副作用なし（_last を更新しない）。Go の advance と同等の純粋計算
                                 ← _last の更新は呼び出し元の reserveAt が成功時のみ行う
```

**具体例** (`_limit=2.0`、`_burst=5`、前回更新から 1.5 秒経過):
```
delta = 1.5秒 × 2.0個/秒 = 3.0個
_tokens = min(現在 2.0 + 3.0, 5.0) = 5.0  ← 上限でクランプ
```

---

### reserveAt の内部処理

**何をする関数か**: 「今から `n` 個のトークンを予約したい。最大 `maxFutureReserve` 時間まで待てる」という要求を処理する。  
トークンが足りなくても **将来の時刻に予約を確保**し、何秒後に実行できるかを返す（先取り予約）。

```
reserveAt(t, n, maxFutureReserve):
  lockUncancelable()       ← 複数スレッドが同時に予約しないようロック
  defer unlock()

  if _limit == INF:
    return Reservation{ _tokens=n, _timeToAct=t, _limit=_limit }
                           ← 無制限なら即OK

  if _limit == 0:
    return null            ← 設計注意事項「Limit = 0 はすべてのイベントを拒否」に基づく
                           ← _tokens < 0 時に -_tokens / _limit の計算でゼロ除算が起きるのを防ぐ

  _tokens = tokensAt(t)    ← 現時点のトークン数を計算（遅延評価）
  _tokens -= float(n)      ← n 個を「仮消費」

  waitDuration_ns: i96 = 0          ← 単位: ナノ秒（i96）、maxFutureReserve と同単位
  if _tokens < 0:          ← トークンが足りない（マイナスになった）
    waitDuration_ns = @as(i96, @intFromFloat(-_tokens / _limit * 1e9))
                           ← 不足分が補充されるまでの待機時間をナノ秒で計算
                           ← 例: 2.0個 ÷ 2.0個/秒 × 1e9 = 1_000_000_000 ns（1秒後）

  ok = (n <= _burst) && (waitDuration_ns <= maxFutureReserve.nanoseconds)
       ↑ バースト容量を超えていない  ↑ 待機時間（ns）が許容範囲内（同単位で比較）
  _timeToAct = Io.Timestamp{ .nanoseconds = t.nanoseconds + waitDuration_ns }
               ← 実行可能になる時刻

  if !ok:
    _tokens += float(n)            ← 予約失敗なら仮消費をロールバック
    return null

  _last = t
  _lastEvent = _timeToAct          ← 次の予約計算の基準として記録
  return Reservation{ _timeToAct, _tokens=n, _limit }
```

**具体例** (`_limit=2.0`、`_burst=5`、現在トークン数 1.0、3個予約):
```
_tokens = 1.0 - 3 = -2.0  ← 2個不足
waitDuration_ns = 2.0 / 2.0 * 1e9 = 1_000_000_000 ns（1秒後）
ok = (3 <= 5) && (1_000_000_000 <= maxFutureReserve.nanoseconds)
_timeToAct = Io.Timestamp{ .nanoseconds = now.nanoseconds + 1_000_000_000 }
```

**「仮消費」の意味**: 複数のスレッドが同時に予約しても、それぞれが異なる `_timeToAct` を受け取るよう、先に予約した分はトークンを先食いしておく。これにより「予約の順番待ち行列」が成立する。

---

### setLimitAt / setBurstAt の内部処理

**何をする関数か**: 現時点のトークン数を確定させてから（遅延評価の確定）、`_limit` または `_burst` を更新する。  
`tokensAt` が副作用なしの純粋関数になったため、これらの関数が自分で `_tokens` と `_last` を更新する必要がある（Go の `SetLimitAt`・`SetBurstAt` と同等）。

```
setLimitAt(t, new_limit):
  lockUncancelable()
  defer unlock()
  _tokens = tokensAt(t)   ← 現時点のトークン数を計算（純粋関数）
  _last = t               ← tokensAt が副作用を持たないため、ここで明示的に更新する
  _limit = new_limit

setBurstAt(t, new_burst):
  lockUncancelable()
  defer unlock()
  _tokens = tokensAt(t)
  _last = t
  _burst = new_burst
```

**なぜ `_last = t` が必要か**: `tokensAt` はかつて `_last = t` を副作用として持っていたが、純粋関数化した際に除去した。  
`setLimitAt`/`setBurstAt` は「この時刻を起点として以降の計算をする」という意味で `_last` を更新しなければならない。  
これを省略すると、次の `tokensAt` 呼び出しで `elapsed = t - _last` が旧時刻から計算され、トークン数が二重計上される。

---

### waitN の内部処理（zctx 採用版）

**何をする関数か**: `reserveAt` で予約を取ってから、実行可能時刻まで **スリープして待機** する。  
途中でコンテキストがキャンセルされたり、デッドラインを超えたりした場合は予約を返却してエラーを返す。

```
waitN(io, ctx, n):
  // ① 事前チェック
  if n > _burst:
    return error.ExceedsLimit      ← バースト容量を超える要求は永遠に通らない

  if ctx.err(io) |err| return err  ← 呼び出し前にすでにキャンセル済みなら即エラー

  now = Io.Clock.Timestamp.now(io, .awake)   // Io.Clock.Timestamp (.raw: Io.Timestamp)

  // ② 待機の上限時間を決める（コンテキストのデッドラインから自動計算）
  maxFutureReserve =
    if ctx.deadline() |dl|:        ← コンテキストにデッドラインがある場合
      remaining = dl.raw.nanoseconds - now.raw.nanoseconds  ← 残り時間（ナノ秒）
      if remaining <= 0:
        return error.DeadlineExceeded  ← すでに期限切れ
      Io.Duration{ .nanoseconds = remaining }  ← 残り時間を上限とする
    else:
      Io.Duration.max                            ← デッドラインなし → 事実上無制限（Io.Duration.max = math.maxInt(i96) ns）

  // ③ 予約を取得（now.raw で Io.Timestamp を渡す）
  r = reserveAt(io, now.raw, n, maxFutureReserve) orelse {
    return ctx.err(io) orelse error.DeadlineExceeded
                               ← n <= _burst は保証済みなので、null = 待機がデッドラインを超える
                               ← ctx がすでにキャンセル済みなら ctx.err(io) でキャンセル種別を取得
                               ← ctx が未キャンセルでも待機超過なら DeadlineExceeded を返す
  }

  // ④ 待機時間が 0 以下なら即実行
  delay = r.delay(io)
  if delay.nanoseconds <= 0:
    return                         ← トークンが十分あったので即時実行

  // ⑤ 「スリープ完了」と「キャンセル発火」を競争させる
  //
  //   Go での等価コード:
  //   select {
  //   case <-time.After(delay):  // スリープ完了
  //   case <-ctx.Done():         // キャンセル発火
  //   }
  //
  delayNs = cast(u64, delay.nanoseconds)  ← i96 → u64 安全変換
  cancelled = ctx.done().waitTimeout(io, delayNs)
                    ↑ delayNs 経過するか ctx がキャンセルされるまでブロック
                      キャンセルされた場合 true を返す

  if cancelled:
    r.cancel(io, limiter)              ← 予約を返却（取得したトークンを戻す）
    return ctx.err(io) orelse error.Canceled
  // スリープ完了（正常に待機できた）→ 呼び出し元に制御を返す
```

**フロー図**:
```
waitN(n)
  │
  ├─ n > _burst?  → error.ExceedsLimit（永遠に通らない）
  │
  ├─ ctx 既キャンセル? → error.Canceled / error.DeadlineExceeded
  │
  ├─ reserveAt で予約
  │    └─ 予約失敗（待ちすぎ）? → ctx.err(io) orelse error.DeadlineExceeded
  │
  ├─ 待機時間 0? → 即リターン（成功）
  │
  └─ waitTimeout(delayNs) で競争待機
       ├─ スリープ完了 → リターン（成功）
       └─ キャンセル発火 → r.cancel(io, limiter) → error.Canceled / error.DeadlineExceeded
```

---

## 実装フェーズ

### Phase 1: コア（必須）

- [ ] `Limit` 型と `every()` 関数
- [ ] `Limiter.init(rate, burst)`
- [ ] `Limiter.allow`（公開）/ `allowAt`（内部ヘルパー）
- [ ] `Limiter.reserve`（公開）/ `reserveAt`（内部ヘルパー）
- [ ] `Reservation.delay / cancel`
- [ ] スレッドセーフ（`Io.Mutex.lockUncancelable`）
- [ ] 基本テスト
- [ ] `example/basic.zig`（allow パターン）
- [ ] `example/reserve.zig`（reserve パターン）

### Phase 2: ブロッキング Wait（必須）

- [ ] `WaitError` エラーセットの定義
- [ ] `Limiter.wait / waitN`（`zctx.Context` 対応）
- [ ] `ctx.deadline()` による `maxFutureReserve` 自動計算
- [ ] `Signal.waitTimeout` によるキャンセル競争
- [ ] `error.ExceedsLimit` / `error.Canceled` / `error.DeadlineExceeded` の伝播と予約キャンセル
- [ ] zctx の `build.zig.zon` への追加
- [ ] タイムアウト・デッドライン付きテスト
- [ ] `example/wait.zig`（waitN + withTimeout パターン）
- [ ] `example/cancel.zig`（waitN + withCancel パターン）

### Phase 3: 動的設定変更（重要）

- [ ] `setLimit`（公開）/ `setLimitAt`（内部ヘルパー）
- [ ] `setBurst`（公開）/ `setBurstAt`（内部ヘルパー）
- [ ] `tokens`（公開）/ `tokensAt`（内部ヘルパー）
- [ ] 設定変更中のスレッドセーフテスト
- [ ] `example/dynamic.zig`（setLimit/setBurst パターン）

---

## テスト計画

| テストケース | 確認内容 |
|-------------|---------|
| 基本 allow | バースト内は true、超過後は false |
| レート計算 | `every(100ms)` → 10 events/sec |
| トークン補充 | 時間経過でトークンが回復する |
| waitN 即時 | トークン十分なら即座に返る |
| waitN 遅延 | 不足時にスリープして待機 |
| waitN バースト超過 | n > burst で error.ExceedsLimit |
| waitN キャンセル | ctx キャンセルで error.Canceled |
| waitN デッドライン超過 | ctx のデッドライン超過で error.DeadlineExceeded |
| waitN デッドライン事前計算 | deadline - now が maxFutureReserve として使われる |
| 予約キャンセル | cancel() でトークン返還 |
| setLimit 変更 | 変更後のレートが正しく反映 |
| setBurst 変更 | バースト変更が正しく反映 |
| Inf レート | burst 無視で常に許可 |
| スレッド競合 | 複数スレッドからの同時アクセスで壊れない |

### テスト戦略

#### `std.testing.io` — テストブロック内の Io インスタンス

Zig 0.16.0 の `std.testing` には以下が定義されている（`testing.zig:35`）:

```zig
pub const io = if (builtin.is_test) io_instance.io() else @compileError("not testing");
```

テストブロック内では `std.testing.io` を `Io` インスタンスとして利用できる。

```zig
test "allow" {
    const io = std.testing.io;
    var limiter = Limiter.init(5.0, 3);
    try std.testing.expect(limiter.allow(io));
}
```

#### 時刻注入 — `allow` / `reserve` の時刻制御

`allow(io)` は内部で `allowAt(io, now, 1)` に委譲し、`reserve(io)` は `reserveAt(io, now, 1, Io.Duration.max)` に委譲する。  
テストで時刻を制御したい場合は、At 変形に明示的な `Io.Timestamp` を渡す。

```zig
test "allowAt with explicit timestamp" {
    const io = std.testing.io;
    var limiter = Limiter.init(1.0, 1);
    const t0 = Io.Timestamp.zero;                                 // .{ .nanoseconds = 0 } と等価
    const t1 = Io.Timestamp.fromNanoseconds(std.time.ns_per_s);  // 1秒後

    try std.testing.expect(limiter.allowAt(io, t0, 1));   // バースト消費
    try std.testing.expect(!limiter.allowAt(io, t0, 1));  // 枯渇
    try std.testing.expect(limiter.allowAt(io, t1, 1));   // 1秒後に回復
}
```

> **API 確認済み（Zig 0.16.0 `lib/std/Io.zig`）**
> - `Io.Timestamp.zero` = `Io.Timestamp{ .nanoseconds = 0 }` として定義済み（`pub const zero: Timestamp = .{ .nanoseconds = 0 }`）
> - `Io.Timestamp.fromNanoseconds(x: i96) Timestamp` が利用可能
> - `Io.Duration.zero`・`Io.Duration.max`（= `math.maxInt(i96)` ナノ秒）が定義済み
> - `Io.Mutex.init` が初期値（`pub const init: Mutex = .{ .state = .init(.unlocked) }`）

#### waitN のスリープ回避

`waitN` は内部でスリープを伴うため、実際の待機が発生しないようにテストを設計する。

**即時キャンセル（`error.Canceled` を検証）**  
`zctx.CANCELED` は常にキャンセル済みのコンテキスト。スリープなしで即座に `error.Canceled` が返る。

```zig
test "waitN canceled immediately" {
    const io = std.testing.io;
    var limiter = Limiter.init(0.001, 1);  // 極低レートで必ず遅延が発生する設定
    const err = limiter.waitN(io, zctx.CANCELED, 1);
    try std.testing.expectError(error.Canceled, err);
}
```

**バースト超過（`error.ExceedsLimit` を検証）**  
`n > _burst` の場合は ctx を参照する前に即座に `error.ExceedsLimit` を返す。

```zig
test "waitN burst exceeded" {
    const io = std.testing.io;
    var limiter = Limiter.init(1.0, 3);
    const err = limiter.waitN(io, zctx.BACKGROUND, 4);  // 4 > burst=3
    try std.testing.expectError(error.ExceedsLimit, err);
}
```

**デッドライン超過（`error.DeadlineExceeded` を検証）**  
過去の時刻をデッドラインとした Context を渡すことで、スリープなしで `error.DeadlineExceeded` が返る。

```zig
test "waitN deadline exceeded" {
    const io = std.testing.io;
    var limiter = Limiter.init(0.001, 1);
    const allocator = std.testing.allocator;

    // 過去のデッドライン（epoch = 0、モノトニッククロック基準）
    const pastDeadline = Io.Clock.Timestamp{ .raw = Io.Timestamp.zero, .clock = .awake };
    const ctx = try zctx.withDeadline(io, zctx.BACKGROUND, pastDeadline, allocator);
    defer ctx.deinit(io);

    const err = limiter.waitN(io, ctx.context, 1);
    try std.testing.expectError(error.DeadlineExceeded, err);
}
```

#### `Reservation.cancel()` の呼び出し

`Reservation` はポインタを持たない値型のため、ライフタイム制約はない。  
`cancel()` に `*Limiter` を明示的に渡すことで、どの Limiter にトークンを返却するかが呼び出し側に可視化される。

```zig
test "reservation cancel" {
    const io = std.testing.io;
    var limiter = Limiter.init(1.0, 1);
    var r = limiter.reserve(io) orelse return error.TestUnexpectedNull;
    defer r.cancel(io, &limiter);
}
```

---

## 注意事項

- `Io.Mutex.lockUncancelable` を使用すること（短いクリティカルセクションで失敗しないため）
- `Io.Duration` の `nanoseconds` フィールドは `i96` 型であることに注意
- `Io.Clock.awake`（モノトニッククロック）を使用してシステム時刻の巻き戻しに対応
- `Limit = 0` の場合はすべてのイベントを拒否（`INF` と逆）
- トークン数は `f64`、リクエスト数は `usize` とする

---

## zctx 活用案

### zctx とは

https://github.com/dot96gal/zctx — Go の `context` パッケージを Zig 0.16.0 に移植した同作者のライブラリ。  
外部依存なし（Zig 標準ライブラリのみ）、`minimum_zig_version = "0.16.0"`。

提供する主要 API:

| zctx API | Go の対応 |
|---------|---------|
| `Context.deadline() ?Io.Clock.Timestamp` | `ctx.Deadline()` |
| `Context.err(io) ?ContextError` | `ctx.Err()` |
| `Context.done() Signal` | `ctx.Done()` |
| `Signal.waitTimeout(io, ns) bool` | `select { case <-ctx.Done(): case <-timer.C: }` |
| `withCancel / withTimeout / withDeadline` | `context.WithCancel/Timeout/Deadline` |
| `ContextError = error{Canceled, DeadlineExceeded}` | `context.Canceled / context.DeadlineExceeded` |

### 現行設計の課題

CLAUDE.md の「外部ライブラリ禁止」ルールのもとで `io` のみを使う場合の制約:

| 課題 | 現行（io のみ） | zctx 利用時 |
|-----|--------------|-----------|
| デッドライン取得 | 不可。`max_wait` を手動指定 | `ctx.deadline()` で自動計算 |
| キャンセルの種別 | `error.Canceled` のみ | `Canceled` / `DeadlineExceeded` を区別 |
| 待機 vs キャンセルの競争 | `Io.sleep` に依存（io ランタイム任せ） | `Signal.waitTimeout` で明示的に競争 |
| API の忠実度 | `waitN(io, n)` — Go と乖離 | `waitN(io, ctx, n)` — Go の `WaitN(ctx, n)` に忠実 |

### zctx を使った改善設計

#### `waitN` のシグネチャ変更

```zig
// 変更前（採用前の案。現在の設計は「変更後」を参照）
pub fn wait(limiter: *Limiter, io: Io) Io.Cancelable!void
pub fn waitN(limiter: *Limiter, io: Io, n: usize) Io.Cancelable!void

// 変更後（zctx 利用）← 現在の設計
pub fn wait(limiter: *Limiter, io: Io, ctx: zctx.Context) WaitError!void
pub fn waitN(limiter: *Limiter, io: Io, ctx: zctx.Context, n: usize) WaitError!void
```

#### `waitN` のアルゴリズム（改善後）

```
waitN(io, ctx, n):
  if n > _burst:
    return error.ExceedsLimit       // 永遠に満たせない

  if ctx.err(io) |err| return err   // 事前キャンセルチェック

  now = Io.Clock.Timestamp.now(io, .awake)   // Io.Clock.Timestamp (.raw: Io.Timestamp)

  // ctx.deadline() から maxFutureReserve を自動計算（Go の WaitN と同等）
  maxFutureReserve =
    if ctx.deadline() |dl|:
      const remaining = dl.raw.nanoseconds - now.raw.nanoseconds
      if remaining <= 0: return error.DeadlineExceeded
      Io.Duration{ .nanoseconds = remaining }
    else:
      Io.Duration.max  // 無制限（= math.maxInt(i96) ns）

  const r = reserveAt(io, now.raw, n, maxFutureReserve) orelse {  // now.raw で Io.Timestamp を渡す
    return ctx.err(io) orelse error.DeadlineExceeded  // n <= _burst は保証済み → null = デッドライン超過
  }

  delay = r.delay(io)
  if delay.nanoseconds <= 0:
    return                          // 即時実行

  // Signal.waitTimeout で「スリープ vs キャンセル」を競争させる
  // Go の: select { case <-timer.C: case <-ctx.Done(): }
  // i96 → u64 の安全なキャスト（オーバーフロー時は u64 最大値でクランプ）
  const delayNs = std.math.cast(u64, delay.nanoseconds) orelse std.math.maxInt(u64)
  const cancelled = ctx.done().waitTimeout(io, delayNs)
  if cancelled:
    r.cancel(io, limiter)
    return ctx.err(io) orelse error.Canceled
  // タイムアウト到達（正常にスリープ完了）→ 処理続行
```

#### `ctx.deadline()` による `maxFutureReserve` の自動計算

Go の `WaitN` は内部で以下を行っている:

```go
// Go の実装
now := time.Now()
waitLimit := InfDuration
if deadline, ok := ctx.Deadline(); ok {
    waitLimit = deadline.Sub(now)
}
r := limiter.reserveN(now, n, waitLimit)
```

zctx の `ctx.deadline()` を使えばこれと同等の処理を Zig でも実現できる。

### 依存関係の追加（確定）

CLAUDE.md で zctx が許可された外部ライブラリとして追加済み。

**zctx の追加方法:**

```zig
// build.zig.zon に追加
.dependencies = .{
    .zctx = .{
        .url = "https://github.com/dot96gal/zctx/archive/refs/tags/v0.2.0.tar.gz",
        .hash = "...",  // zig fetch で取得
    },
},
```

```zig
// build.zig に追加
const zctx_dep = b.dependency("zctx", .{});
lib.root_module.addImport("zctx", zctx_dep.module("zctx"));
```

### 採用判断: **zctx 採用（確定）**

CLAUDE.md の更新により zctx の利用が許可された。  
`ctx.deadline()` による `maxFutureReserve` 自動計算と `Signal.waitTimeout` によるキャンセル競争を採用し、Go の `WaitN` と同等の動作を実現する。

---

## 実装振り返り（2026-04-29）

### 計画との差異

#### API シグネチャの変更

| 箇所 | 計画 | 実装 | 理由 |
|------|------|------|------|
| `Limiter.init` 第2引数 | `burst: usize` | `burstSize: usize` | `burst()` メソッドとのシャドーイング警告（ZLS）を回避するため |
| `Limiter._mu` フィールド | `_mu: Io.Mutex = Io.Mutex.init` | `_mu: Io.Mutex`（デフォルト値なし） | Zig 0.16 でフィールドデフォルト値として `Io.Mutex.init` が comptime 評価できなかったため。`init()` 内で `.init` を設定することで同等の動作を保証 |
| 内部パラメータ名 | `new_limit`, `new_burst` など snake_case | `newLimit`, `newBurst` など camelCase | Zig スタイルガイド（camelCase）に準拠。呼び出し側への影響なし |

#### Zig 0.16 の仕様差異による変更

| 箇所 | 計画 | 実装 | 理由 |
|------|------|------|------|
| `src/root.zig` の re-export | `pub usingnamespace @import("rate.zig")` | 各シンボルを明示的に `pub const` で再エクスポート | `pub usingnamespace` が Zig 0.16 で廃止されたため |
| `@intFromFloat` の使用 | `@intFromFloat(...)` | `@trunc(...)` | `@intFromFloat` が Zig 0.16 で廃止。`@trunc` が整数型を直接返すよう変更された |

#### ファイル構成の変更

| 変更 | 理由 |
|------|------|
| `src/main.zig` を削除 | ライブラリプロジェクトに実行ファイルのエントリポイントは不要。ユーザー提案により削除 |
| `build.zig` を全面刷新 | 実行ファイル定義を除去し、ライブラリ・docs・example ステップに整理 |

#### テスト計画の後追い実装

計画のテスト計画のうち、初期実装では省略された以下の5件を整合性チェック後に追加実装した。

| テスト | 実装方針 |
|--------|----------|
| `waitN: delays when tokens insufficient` | `every(1ns)` で待機時間を 1ns に抑えスリープ実質ゼロ |
| `waitN: DeadlineExceeded via maxFutureReserve calculation` | rate=0.001/s × timeout=1ms で `reserveAt` を即座に null にし、スリープなしで経路検証 |
| `reservation cancel: restores tokens` | 明示タイムスタンプ（t0）と `tokensAt(t0)` で返還量を数値検証 |
| `thread safety: concurrent allow` | 8 スレッド × 100 呼び出しで破壊なしを確認 |
| `thread safety: concurrent setLimit and allow` | 動的設定変更と `allow` の並行実行で破壊なしを確認 |

### 計画通りに実装できた箇所

- 公開 API 全体（`allow` / `reserve` / `wait` / `waitN` / `setLimit` / `setBurst` / `limit` / `burst` / `tokens`）のシグネチャと動作
- 内部ヘルパー（`allowAt` / `reserveAt` / `setLimitAt` / `setBurstAt` / `tokensAt`）のアルゴリズム
- `Reservation.cancel()` のトークン返還ロジック（`_lastEvent` 巻き戻しを含む）
- `waitN` の `ctx.deadline()` → `maxFutureReserve` 自動計算と `Signal.waitTimeout` によるキャンセル競争
- zctx の依存追加と `build.zig` への組み込み
- 全 5 example（basic / reserve / wait / cancel / dynamic）の動作確認
