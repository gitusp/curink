# curink

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

画面共有や録画でマウスカーソルの軌跡を見せるための macOS 用ユーティリティ。修飾キーを押している間だけカーソル位置に **発光するインクの軌跡** を描き、離すとフェードアウトする。デフォルトはターコイズブルー + 白のグロー。

常駐 daemon にホットキーから `curink start` / `curink stop` を叩く構成。spawn コストを排して押下からの遅延を最小化する。daemon が居なければ初回の `curink start` が自分自身を fork して立ち上げる (= 初回だけ cold)。zero-lag にしたければ launchd でログイン時に立ち上げておく。

## 構成

- `curink.swift` — daemon 兼クライアントのソース。`curink` で daemon、`curink start` / `curink stop` でメッセージ送信
- `Makefile` — ビルド／インストール
- `LICENSE` — MIT

## 動作要件

- macOS（Cocoa / QuartzCore が動けば動く範囲。Apple Silicon / Intel ともに想定）
- Swift コンパイラ (`swiftc`)。Xcode または Command Line Tools (`xcode-select --install`) を入れておく
- ホットキー連携用に [Karabiner-Elements](https://karabiner-elements.pqrs.org/) など任意のランチャー

## ビルドとインストール

```bash
make install   # ~/.local/bin/curink にインストール
```

`PREFIX` でインストール先を変えられる（例: `make install PREFIX=/usr/local`）。

## 使い方

```bash
~/.local/bin/curink start                    # 描画開始 (daemon が居なければ自動で立ち上げる)
~/.local/bin/curink stop                     # フェードアウト
~/.local/bin/curink &                        # daemon を明示的に常駐 (任意; 初回 cold を消したい時)
~/.local/bin/curink --color "#ff3366" &      # 色を変えて daemon 起動
~/.local/bin/curink --help
```

`curink` (引数なし) は idle daemon として動作する。socket 経由で `start` を受け取ると window を表示してカーソルポーリングを開始、`stop` でフェードアウトして再び idle に戻る。daemon が既に動いていれば二重起動はせず黙って exit する。

`curink start` は daemon が見つからなければ自分自身を fork して daemon 化し、socket が立ち上がるのを待ってから `start` を送る。初回だけ Cocoa 初期化のコスト (~500ms) が乗るが、以降は socket 一往復で ms 以下。常時 zero-lag にしたい場合は launchd で先に立ち上げておく (後述)。

## プロセスのライフサイクル

- 起動時に `$TMPDIR/curink.sock` を `bind+listen`。既に live daemon があれば exit。stale socket file は unlink して再 bind。
- daemon は `IDLE → DRAWING → FADING → IDLE` の状態機械。idle 中は Timer 停止、window 非表示で CPU ほぼ 0。
- `start`: window を表示、`NSEvent.mouseLocation` を 120Hz でポーリングし `CAShapeLayer` のパスに継ぎ足し。フェードアウト中なら animation を取り消して再開。
- `stop`: 0.4 秒の opacity フェードを掛け、完了後に window を `orderOut` してパスを破棄。
- アクセシビリティ権限は不要 (`mouseLocation` ポーリングのみ、global event tap は使わない)。

## コマンドラインオプション

daemon 起動時に渡す:

| オプション | デフォルト | 意味 |
| --- | --- | --- |
| `--color <hex>` | `#40E0D0` | インクのストローク色。`#RRGGBB` または `#RRGGBBAA`。グローは白固定 |
| `--width <pt>` | `4` | 線幅 (pt) |
| `--glow <pt>` | `width * 2` | 線周囲のグローのブラー半径 (pt)。`0` でグロー無効 |
| `-h`, `--help` | — | ヘルプを表示して終了 |

サブコマンド:

| サブコマンド | 意味 |
| --- | --- |
| `start` | daemon に描画開始を依頼 |
| `stop` | daemon にフェードアウトを依頼 |

## ログイン時の自動起動 (launchd, 任意)

bootstrap で十分なら不要。初回押下の ~500ms も気になる場合や、常に daemon を生かしておきたい場合に。

`~/Library/LaunchAgents/local.curink.plist` を作成:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.curink</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/YOUR_NAME/.local/bin/curink</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/local.curink.plist
```

## ホットキー設定（Karabiner-Elements）

down で `curink start`、up で `curink stop` を叩くだけ。daemon が常駐している前提なので spawn コストはかからず、押した瞬間に描画が始まる。

`right_control` を押している間だけ軌跡を出す例:

```json
{
  "title": "curink",
  "rules": [
    {
      "description": "right_control held -> curink ink trail",
      "manipulators": [
        {
          "type": "basic",
          "from": {
            "key_code": "right_control",
            "modifiers": { "optional": ["any"] }
          },
          "to": [
            { "shell_command": "$HOME/.local/bin/curink start" }
          ],
          "to_after_key_up": [
            { "shell_command": "$HOME/.local/bin/curink stop" }
          ]
        }
      ]
    }
  ]
}
```

ポイント:

- `right_control` を奪うので、本来の右 Ctrl の機能を使っているなら `right_command` や `fn` など別のキーに割り当てる。
- `shell_command` の `curink` は **絶対パス** で書く。Karabiner-Elements の起動環境は `PATH` が最小。
- daemon が居なければ `curink start` が自動で立ち上げる。初回押下が ~500ms cold になるのが嫌なら launchd で先に起こしておく。

Hammerspoon、Raycast、skhd など他のランチャーでも、down で `curink start`、up で `curink stop` を叩く構成にすれば同じ要領で動く。

## カスタマイズ

CLI で渡せない項目は `curink.swift` 冒頭の定数を変更してリビルド (`make install`) する。

| 識別子 | デフォルト | 意味 |
| --- | --- | --- |
| ポーリング間隔 | `1.0 / 120.0` | `tick()` を呼ぶ Timer の interval (秒)。`startDrawing` 内 |
| フェードアウト時間 | `0.4` 秒 | `stopDrawing` 内の `anim.duration` |
| `socketPath` | `$TMPDIR/curink.sock` | 制御ソケットの位置 |

## 既知の制約

- Zoom / Google Meet / Teams で **特定ウィンドウのみ共有** している場合、オーバーレイは別ウィンドウなので相手側には映らない。**画面全体共有** を使うこと。
- 初回実行時に macOS のセキュリティダイアログが出る場合がある。
- Karabiner-Elements の `shell_command` は環境変数が最小なので、バイナリは絶対パスで指定する。
- daemon は起動時のディスプレイ構成で全画面の union を計算する。あとからモニタを抜き差しすると window のカバレッジがズレる。再起動するか、いったん `kill` してから再 launch する。
- 制御ソケットの `.sock` ファイルは daemon 終了時に消さない（次回起動の `bind` 前に検知して unlink する）。複数ユーザーで `$TMPDIR` を共有する環境では衝突に注意。

## 動作確認

```bash
make run         # その場でビルドして daemon 起動
# 別ターミナルから
./curink start   # 描画開始
./curink stop    # フェードアウト
```

## ライセンス

[MIT License](./LICENSE) © 2026 usp
