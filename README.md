# Media Viewer

写真・動画をネットワーク越しに閲覧できるメディアビューアです。
ネットワーク接続には [Tailscale](https://tailscale.com/) を使用することを想定しています。

## 機能

- 画像・動画のギャラリー表示（グリッドレイアウト）
- フォルダスキャンによるメディア自動登録
- サムネイル生成・キャッシュ（JPEG・HEIC・DNG・RAW対応）
- ダークモード / ライトモード切替
- Exif情報の表示（撮影日時・カメラ機種・F値など）
- 動画再生（音量調整・フルスクリーン対応）

## 対応拡張子

| 種別 | 拡張子 |
|------|--------|
| 画像 | `.jpg` `.jpeg` `.png` `.gif` `.bmp` `.webp` `.heic` `.tiff` `.dng` |
| 動画 | `.mp4` `.mkv` `.avi` `.mov` `.flv` `.wmv` `.webm` |

## 動作環境

- Windows 10 / 11 (64bit)
- Tailscale

---

## 一般ユーザー向け

[Releases](https://github.com/Nakki714/MediaViewer/releases) ページから以下の2つをダウンロードします。

| ファイル | 説明 |
|--------|------|
| `MediaViewer_Setup.exe` | アプリのインストーラー |
| `MediaServer.zip` | サーバー一式 |

### クライアント側
`MediaViewer_Setup.exe` を実行してインストールし、設定からサーバーのIPアドレスを入力します。

### サーバー側
`MediaServer.zip` を解凍して `server.exe` を起動します。

---

## 開発者向け

### 必要なもの

- [Flutter SDK](https://docs.flutter.dev/get-started/install/windows) 3.x 以上
- [Python](https://www.python.org/downloads/) 3.10 以上
- Windows 向け Flutter 開発環境（Visual Studio Build Tools）

### セットアップ

```bash
# リポジトリのクローン
git clone https://github.com/Nakki714/MediaViewer.git
cd MediaViewer

# Flutter依存関係のインストール
flutter pub get

# Pythonサーバーのセットアップ
cd MediaServer
pip install -r requirements.txt
```

### 起動

**サーバー（ターミナル1）**
```bash
cd MediaServer
python server.py
```

**アプリ（ターミナル2）**
```bash
flutter run -d windows
```

### ビルド

**Flutterアプリ**
```bash
flutter build windows
```

**Pythonサーバーのexe化**
```bash
cd MediaServer
pyinstaller --onefile --name make_thumbnails make_thumbnails.py

pyinstaller --onefile --name server ^
  --hidden-import uvicorn.logging ^
  --hidden-import uvicorn.loops ^
  --hidden-import uvicorn.loops.auto ^
  --hidden-import uvicorn.protocols ^
  --hidden-import uvicorn.protocols.http ^
  --hidden-import uvicorn.protocols.http.auto ^
  --hidden-import uvicorn.lifespan ^
  --hidden-import uvicorn.lifespan.on ^
  server.py
```

---

## フォルダ構成

```
MediaViewer/
├── lib/
│   └── main.dart              # Flutterアプリ本体
├── pubspec.yaml               # Flutter依存関係
└── MediaServer/
    ├── server.py              # FastAPIサーバー
    ├── make_thumbnails.py     # サムネイル生成
    └── requirements.txt       # Python依存ライブラリ
```

## 技術スタック

| 役割 | 技術 |
|------|------|
| UIアプリ | Flutter (Dart) |
| バックエンドサーバー | Python / FastAPI |
| データベース | SQLite |
| 画像処理 | Pillow / pillow-heif / rawpy |
| 動画処理 | OpenCV |
| 動画再生 | media_kit |

---

## ライセンス

MIT License