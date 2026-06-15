# HAILO YOLO Web Demo

AM67A + HAILO-8L + LXC 仮想インスタンス機能のデモ用 Web アプリです。

JPEG または MP4 をブラウザからアップロードし、HAILO-8L 上の YOLOv11s で物体検出を行い、bbox / label を重ねた結果を表示します。MP4 入力では、HW decoder / HAILO / overlay / HW encoder を使って、bbox / label 付き MP4 を生成します。

このアプリは汎用 Web サービスではなく、弊社機器上で以下の要素を組み合わせて見せるためのデモアプライアンスです。

- AM67A SoC HW video decoder / encoder
- HAILO-8L
- Alpine Linux + OpenRC
- LXC 仮想インスタンス機能
- nginx 前段 upload
- Nim 製 media / HAILO / thread pipeline ライブラリ群

## 主な機能

### JPEG 入力

JPEG 画像をアップロードすると、以下の流れで bbox / label 付き JPEG を生成します。

1. TurboJPEG で JPEG decode
2. YOLOv11s 入力用に 640x640 RGB letterbox 変換
3. HAILO-8L で推論
4. Pixie で bbox / label overlay
5. JPEG encode
6. 結果画像をブラウザに表示

### MP4 入力

MP4 動画をアップロードすると、以下の流れで bbox / label 付き MP4 を生成します。

1. libav / FFmpeg で MP4 decode
2. AM67A wave5 `h264_v4l2m2m` HW decoder を使用
3. decoded frame から YOLO 入力を生成
4. HAILO 推論を先行投入
5. full-size RGBX frame を作成
6. HAILO 結果と frame 番号を突き合わせ
7. bbox / label overlay
8. AM67A wave5 `h264_v4l2m2m` HW encoder で H.264 encode
9. MP4 として出力
10. ブラウザで再生 / ダウンロード

MP4 処理中は、途中の overlay 済み frame を 1 枚だけ `preview.jpg` として保存し、wait 画面に表示します。これにより、動画生成完了前でも処理が進んでいることを確認できます。

## 技術的なポイント

### HAILO 待ち時間の隠蔽

MP4 処理では、HAILO の結果読み出し待ちをそのまま待つと処理全体が遅くなります。

このアプリでは、HAILO 推論を先に投入し、その間に次の処理を進めることで待ち時間を隠蔽しています。

大まかな pipeline は以下です。

```text
Decode / Preprocess thread:
  MP4 decode
  I420 -> YOLO RGB 640x640
  HAILO submit
  I420 -> RGBX
  RGBX frame を queue へ move

Overlay / Encode thread:
  RGBX frame を receive
  対応する HAILO result を wait
  bbox / label overlay
  RGBX -> NV12
  H.264 encode
  MP4 mux
```

HAILO の read 待ちは内部的には残っていますが、他の処理と重ねることで、アプリ全体の待ち時間としてはほぼ隠れます。

### threadtools Pool

full-size RGBX frame は数 MiB 単位の大きな buffer です。MP4 処理では `threadtools` の Pool を使い、RGBX frame buffer を thread 間で move しながら再利用します。

これにより、frame ごとの大きな allocation / copy を避けています。

### overlay 表示量の制限

雑踏動画のように検出数が多い映像では、すべての bbox / label を描画すると、見た目が読みにくくなり、Pixie の文字描画も重くなります。

そのため、MP4 出力ではデフォルトで bbox / label を制限しています。

デフォルト値:

```text
boxes:
  score 順に最大 12 個
  score >= 0.25

labels:
  最大 6 個
  score >= 0.50
  height >= 96 px
  area >= 8000 px^2
```

この設定により、雑踏動画でも見た目と処理速度のバランスを取ります。

## 実行構成

本番想定では、nginx を前段に置き、アプリ本体は localhost で待ち受けます。

```text
browser
  ↓
nginx :80
  ↓ upload body を /var/tmp/hailo-demo/upload に保存
  ↓ X-FILE header でアプリへファイルパスを渡す
hailo_yolo_webdemo :127.0.0.1:18080
```

nginx を前段に置く理由は、大きな MP4 upload を Mummy で直接受けないためです。nginx に upload body を spool させ、アプリ側にはファイルパスだけを渡します。

## 必要な実行環境

想定環境:

- Alpine Linux 3.23
- OpenRC
- nginx
- AM67A
- HAILO-8L
- HailoRT runtime
- wave5 V4L2 M2M decoder / encoder
- `h264_v4l2m2m` 対応 FFmpeg / libav runtime
- YOLOv11s HEF
- `DejaVuSans.ttf`

フォントは overlay label 描画に使います。アプリが直接 font path を読むため、fontconfig / `fc-cache` は不要です。

必要なフォントファイル:

```text
/usr/share/fonts/dejavu/DejaVuSans.ttf
```

DejaVu フォント一式を入れる必要はありません。パッケージサイズを抑える場合は、この 1 ファイルだけを同梱すれば十分です。

## ビルド

Alpine runtime では FFmpeg 8 系の soname を使うため、`-d:ffmpeg8` を指定します。

例:

```sh
nimble build -d:musl_cross -d:ffmpeg8 -d:release --stackTrace:off --lineTrace:off
```

開発中は stack trace / line trace を有効にした方が調査しやすいですが、MP4 処理性能には影響が大きいため、デモ用パッケージでは無効化することを推奨します。

## 主要な環境変数

OpenRC の `/etc/conf.d/hailo-yolo-webdemo` から設定します。

### Listen

```sh
export HAILO_DEMO_LISTEN_HOST="127.0.0.1"
```

nginx 前段構成では、アプリ本体は localhost のみに bind します。

### MP4 decoder / encoder

```sh
export HAILO_DEMO_MP4_DECODER="h264_v4l2m2m"
export HAILO_DEMO_MP4_ENCODER="h264_v4l2m2m"
export HAILO_DEMO_MP4_FPS="30"
export HAILO_DEMO_MP4_BITRATE="2000000"
```

### 処理フレーム数

```sh
export HAILO_DEMO_MP4_VIDEO_MAX_FRAMES="0"
```

`0` は全 frame 処理です。Bring-up 時に短く試す場合は `90` などにします。

### thread pipeline

```sh
export HAILO_DEMO_MP4_THREAD_PIPELINE="1"
export HAILO_DEMO_MP4_INFLIGHT="2"
export HAILO_DEMO_MP4_FRAME_POOL="4"
```

### overlay 表示量

```sh
export HAILO_DEMO_VIDEO_MAX_BOXES="12"
export HAILO_DEMO_VIDEO_MAX_LABELS="6"
export HAILO_DEMO_VIDEO_MIN_BOX_SCORE="0.25"
export HAILO_DEMO_VIDEO_MIN_LABEL_SCORE="0.50"
export HAILO_DEMO_VIDEO_MIN_LABEL_BOX_HEIGHT="96"
export HAILO_DEMO_VIDEO_MIN_LABEL_BOX_AREA="8000"
```

### 処理中 preview frame

```sh
export HAILO_DEMO_VIDEO_PREVIEW_FRAME="10"
```

MP4 処理中に表示する preview frame の番号です。デフォルトでは 10 frame 目を保存します。

## OpenRC 自動起動

想定配置:

```text
/usr/local/bin/hailo_yolo_webdemo
/usr/local/share/hailo-demo/yolov11s.hef
/etc/init.d/hailo-yolo-webdemo
/etc/conf.d/hailo-yolo-webdemo
/etc/nginx/http.d/hailo-yolo-webdemo.conf
```

サービス登録:

```sh
rc-update add hailo-yolo-webdemo default
rc-update add nginx default
```

手動起動:

```sh
rc-service hailo-yolo-webdemo start
rc-service nginx start
```

状態確認:

```sh
rc-status
rc-service hailo-yolo-webdemo status
rc-service nginx status
tail -f /var/log/hailo-yolo-webdemo.log
```

## nginx 設定

nginx は upload body を一時ファイルとして保存し、`X-FILE` header でアプリに渡します。

重要な設定:

```nginx
client_max_body_size 512M;
client_body_temp_path /var/tmp/hailo-demo/upload;
client_body_in_file_only clean;

location /upload {
    proxy_pass http://127.0.0.1:18080;

    proxy_request_buffering on;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-FILE $request_body_file;
}
```

## 作業ディレクトリ

```text
/var/tmp/hailo-demo
/var/tmp/hailo-demo/upload
/var/tmp/hailo-demo/jobs
```

これらは一時領域です。仮想インスタンスでは tmpfs / volatile rootfs と相性が良いです。

## LXC 仮想インスタンスパッケージ

このデモは LXC 仮想インスタンス機能のアプライアンス例として使う想定です。

推奨 rootfs mode:

```text
volatile
```

理由:

- upload / job / output は一時データ
- 再起動で消えてよい
- eMMC / SD への書き込みを抑えられる
- デモ環境を壊しにくい

`.lxcpkg` 化する場合は、OpenRC 自動起動設定、nginx 設定、HEF、アプリ本体、最小 runtime library を含めます。

## パッケージサイズ削減のメモ

- DejaVu フォントは `DejaVuSans.ttf` だけ残せばよい
- `fc-cache` は不要
- `stackTrace` / `lineTrace` は release package では off 推奨
- upload / jobs は volatile 領域でよい
- 不要な FFmpeg CLI 機能や codec は削る
- HEF が大きいため、他の rootfs 追加物はできるだけ小さくする

## 画面表示

### Upload

JPEG / MP4 を選択して upload します。

### Wait

処理中の progress と status を表示します。MP4 処理では、途中で 1 枚だけ preview frame が表示されます。

### Result

結果画面には以下を表示します。

- summary
- MP4 の場合は video player
- preview frame
- technical timing details
- download link

summary 例:

```text
MP4 complete: 350 frames in 9.00s (38.9fps); detections=6187, boxes=4141, labels=2058, output=2.78MiB
```

## トラブルシュート

### アプリが起動しない

```sh
tail -f /var/log/hailo-yolo-webdemo.log
rc-service hailo-yolo-webdemo status
```

確認点:

- `/usr/local/bin/hailo_yolo_webdemo` が存在し、実行可能か
- `/usr/local/share/hailo-demo/yolov11s.hef` が存在するか
- HAILO device node が LXC インスタンスに見えているか
- HailoRT runtime library が見えているか

### upload で失敗する

確認点:

- nginx が起動しているか
- `/var/tmp/hailo-demo/upload` が存在するか
- `client_max_body_size` が十分大きいか
- nginx 設定で `X-FILE` header を渡しているか

### MP4 decode / encode に失敗する

確認点:

- wave5 decoder / encoder device が LXC インスタンスに見えているか
- `h264_v4l2m2m` が使える FFmpeg runtime になっているか
- 入力 MP4 が H.264 か
- `HAILO_DEMO_MP4_DECODER` / `HAILO_DEMO_MP4_ENCODER` の設定

### overlay の文字が出ない

確認点:

- `/usr/share/fonts/dejavu/DejaVuSans.ttf` が存在するか

`fc-cache` は不要です。

### 処理が遅い

確認点:

- release build で `stackTrace` / `lineTrace` を off にしているか
- `HAILO_DEMO_MP4_THREAD_PIPELINE=1` になっているか
- `HAILO_DEMO_MP4_INFLIGHT=2` になっているか
- overlay の box / label 数が多すぎないか

雑踏動画では、label 数を減らすとかなり効きます。

例:

```sh
export HAILO_DEMO_VIDEO_MAX_BOXES="8"
export HAILO_DEMO_VIDEO_MAX_LABELS="3"
export HAILO_DEMO_VIDEO_MIN_LABEL_SCORE="0.60"
```

## 今後の候補

### MotionJPEG preview

MP4 ファイルを生成する代わりに、overlay 済み JPEG を継続的に配信する MotionJPEG preview も候補です。

まずは `mjpg-streamer` などを使い、tmpfs 上の `latest.jpg` を更新して配信する方式が簡単そうです。

### overlay preset

Web 画面から以下のような preset を選べるようにすると、デモ向けには分かりやすくなります。

- Rich
- Balanced
- Light
- Boxes only

内部的には box / label 数と score 閾値を変えるだけです。

## ライセンス / 配布メモ

この README はアプリの使い方とパッケージ化方針の説明です。

実際に配布する場合は、同梱する以下のライセンスを別途確認してください。

- HailoRT
- YOLOv11s HEF / model
- FFmpeg / libav
- DejaVu Font
- nginx
- Alpine Linux packages
