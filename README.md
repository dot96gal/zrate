# zrate

[![API Docs](https://img.shields.io/badge/API%20Docs-GitHub%20Pages-blue)](https://dot96gal.github.io/zrate/)
[![CI](https://github.com/dot96gal/zrate/actions/workflows/ci.yml/badge.svg)](https://github.com/dot96gal/zrate/actions/workflows/ci.yml)
[![Release](https://github.com/dot96gal/zrate/actions/workflows/release.yml/badge.svg)](https://github.com/dot96gal/zrate/actions/workflows/release.yml)

Zig のレートリミットのライブラリ。

> **注意:** このリポジトリは個人的な興味・学習を目的としたホビーライブラリです。設計上の判断はすべて作者が個人で行っており、事前の告知なく破壊的変更が加わることがあります。安定した API を前提としたい場合は、任意のコミットやタグ時点でフォークし、独自に管理されることをおすすめします。

---

## 要件

- Zig 0.16.0 以上

---

## 利用者向け

### インストール

#### 1. `build.zig.zon` に zrate を追加する

最新のタグは [GitHub Releases](https://github.com/dot96gal/zrate/releases) で確認できる。

以下のコマンドを実行すると、`build.zig.zon` の `.dependencies` に自動的に追加される。

```sh
zig fetch --save https://github.com/dot96gal/zrate/archive/refs/tags/<version>.tar.gz
```

```zig
// build.zig.zon（自動追加される内容の例）
.dependencies = .{
    .zrate = .{
        .url = "https://github.com/dot96gal/zrate/archive/refs/tags/<version>.tar.gz",
        .hash = "<hash>",
    },
},
```

#### 2. `build.zig` で zrate モジュールをインポートする

```zig
const zrate_dep = b.dependency("zrate", .{
    .target = target,
    .optimize = optimize,
});
const zrate_mod = zrate_dep.module("zrate");
exe.root_module.addImport("zrate", zrate_mod);
```

#### 3. （オプション）`zctx` を追加する

`wait()` / `waitN()` でタイムアウト・キャンセルを使う場合は [zctx](https://github.com/dot96gal/zctx) も必要。

最新のタグは [zctx の GitHub Releases](https://github.com/dot96gal/zctx/releases) で確認できる。

```sh
zig fetch --save https://github.com/dot96gal/zctx/archive/refs/tags/<version>.tar.gz
```

```zig
// build.zig
const zctx_dep = b.dependency("zctx", .{});
const zctx_mod = zctx_dep.module("zctx");
exe.root_module.addImport("zctx", zctx_mod);
```

### 使い方

#### パターン 1: `allow()` — シンプルな許可/ドロップ

イベントを即時に許可するかどうかだけを判断したい場合に使う。待機しない。

```zig
const std = @import("std");
const zrate = @import("zrate");

pub fn main(env: std.process.Init) !void {
    const io = env.io;

    // 5 events/sec、バースト最大 3
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

#### パターン 2: `reserve()` — 予約してから待機

待機してでも実行したい場合に使う。`delay()` が返す時間だけスリープしてから処理を行う。

```zig
const std = @import("std");
const zrate = @import("zrate");

pub fn main(env: std.process.Init) !void {
    const io = env.io;

    // 200ms ごとに 1 イベント（= 5 events/sec）
    var limiter = zrate.Limiter.init(zrate.every(.{ .nanoseconds = 200 * std.time.ns_per_ms }), 1);

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const r = limiter.reserve(io) orelse {
            std.debug.print("event {d}: reservation failed\n", .{i});
            continue;
        };

        const d = r.delay(io);
        if (d.nanoseconds > 0) {
            try std.Io.sleep(io, d, .awake);
        }

        std.debug.print("event {d}: executed\n", .{i});
    }
}
```

#### パターン 3: `waitN()` — コンテキスト付きブロッキング待機

タイムアウトやキャンセルを組み合わせて待機したい場合に使う。`zctx` コンテキストによる中断に対応している。

```zig
const std = @import("std");
const zrate = @import("zrate");
const zctx = @import("zctx");

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.arena.allocator();

    // 1 event/sec、バースト最大 1
    var limiter = zrate.Limiter.init(1.0, 1);

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        // 500ms タイムアウト付きコンテキスト
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
            error.ExceedsLimit => unreachable,
        };

        std.debug.print("event {d}: executed\n", .{i});
    }
}
```

#### レートの動的変更

実行中にレートやバーストサイズを変更できる。`zrate.INF` を指定すると無制限になる。

```zig
var limiter = zrate.Limiter.init(10.0, 5);

limiter.setLimit(io, 2.0);   // レートを 2 events/sec に変更
limiter.setBurst(io, 2);     // バーストを 2 に変更

limiter.setLimit(io, zrate.INF); // 無制限に変更
```

### API リファレンス

| シンボル | 説明 |
|---------|------|
| `Limit` | レート（イベント/秒）の型エイリアス（`f64`） |
| `INF` | 無制限レートを表す定数 |
| `every(interval: Io.Duration) Limit` | 周期からレートを計算するヘルパー |
| `Reservation` | `reserve()` の予約結果。`delay()` で待機時間取得、`cancel()` でキャンセル |
| `WaitError` | `wait`/`waitN` が返すエラー集合（`Canceled`, `DeadlineExceeded`, `ExceedsLimit`） |
| `Limiter.init(rate, burst)` | レートリミッターを初期化 |
| `Limiter.allow(io)` | 1 イベントを即時消費。許可なら `true`、不可なら `false` |
| `Limiter.reserve(io)` | 1 イベントを予約。バースト超過時は `null` |
| `Limiter.wait(io, ctx)` | 1 イベントの実行が可能になるまでブロック |
| `Limiter.waitN(io, ctx, n)` | n イベントの実行が可能になるまでブロック |
| `Limiter.setLimit(io, newLimit)` | レートを動的に変更 |
| `Limiter.setBurst(io, newBurst)` | バーストサイズを動的に変更 |
| `Limiter.limit(io)` | 現在のレートを返す |
| `Limiter.burst(io)` | 現在のバーストサイズを返す |
| `Limiter.tokens(io)` | 現在のトークン残量を返す |

詳細なシグネチャ・型情報は [API ドキュメント](https://dot96gal.github.io/zrate/) を参照。

---

## 開発者向け

### 必要なツール

| ツール | 説明 |
|-------|------|
| [mise](https://mise.jdx.dev/) | ツールバージョン管理（Zig・zls を自動インストール） |
| `zig-lint` | Zig 簡易リントスクリプト（`~/.local/bin/` にインストール済み） |
| `zig-release` | バージョン更新・タグ付けスクリプト（`~/.local/bin/` にインストール済み） |

### セットアップ

```sh
git clone https://github.com/dot96gal/zrate
cd zrate
mise install
```

### タスク一覧

| コマンド | 説明 |
|---------|------|
| `mise run fmt` | フォーマット |
| `mise run fmt-check` | フォーマットチェック |
| `mise run lint` | リント |
| `mise run build` | ビルド |
| `mise run test` | テスト |
| `mise run build-docs` | API ドキュメント生成（`zig-out/docs/` に出力） |
| `mise run serve-docs` | API ドキュメントをローカルサーバーで配信 |
| `mise run release X.Y.Z` | バージョン更新・コミット・タグ・プッシュを一括実行 |
| `mise run example:basic` | `allow()` による許可/ドロップの基本デモ |
| `mise run example:reserve` | `reserve()` + `delay()` による待機デモ |
| `mise run example:wait` | `waitN()` + タイムアウトコンテキストデモ |
| `mise run example:cancel` | `waitN()` + キャンセルコンテキストデモ |
| `mise run example:dynamic` | `setLimit`/`setBurst` による動的変更デモ |

### ファイル構成

```
build.zig           # ビルドスクリプト
build.zig.zon       # パッケージメタデータ・依存関係定義
src/
  root.zig          # 公開 API の再エクスポート
  rate.zig          # コア実装（Limiter, Reservation, WaitError）
example/
  basic.zig         # allow() による許可/ドロップの基本デモ
  reserve.zig       # reserve() + delay() による待機デモ
  wait.zig          # waitN() + タイムアウトコンテキストデモ
  cancel.zig        # waitN() + キャンセルコンテキストデモ
  dynamic.zig       # setLimit/setBurst による動的変更デモ
```

### 設計方針

- **トークンバケット方式**: Go の `golang.org/x/time/rate` を移植した実装。トークンを時間経過とともに補充し、消費することでレートを制御する。
- **遅延評価**: `tokensAt()` によりトークン量を純粋関数で計算。実際のスリープに頼らず、必要なときだけ現在値を算出する。
- **スレッドセーフ**: `std.Io.Mutex` によるクリティカルセクション保護。複数スレッドからの同時アクセスに対応している。
- **コンテキスト対応**: `zctx.Context` を介したキャンセル・タイムアウトをサポート。`waitN()` はデッドラインを超えた待機を自動的に拒否する。
- **最小依存**: `zctx` のみを外部依存とし、それ以外は Zig 標準ライブラリのみを使用。

### テスト

テストはコアライブラリ（[src/rate.zig](src/rate.zig)）内に 21 件記述されている。時間依存のテストは `allowAt`/`reserveAt` の明示タイムスタンプ引数を使用し、実時間スリープなしで検証している。

```sh
mise run test
# Build Summary: 3/3 steps succeeded; 21/21 tests passed
```

---

## ライセンス

[MIT](LICENSE)
