# Media Viewer

Windows向けのローカルメディアビューアです。  
写真・動画をフォルダ単位で管理し、サムネイル付きのギャラリー表示ができます。

## 機能

- 画像・動画のギャラリー表示（グリッドレイアウト）
- フォルダスキャンによるメディア自動登録
- サムネイル生成・キャッシュ
- ダークモード / ライトモード切替
- Exif情報の表示（撮影日時・カメラ機種・F値など）
- 動画再生（音量調整・フルスクリーン対応）

## 動作環境

- Windows 10 / 11
- Python 3.10 以上（サーバー動作に必要）

---

## インストール方法（一般ユーザー向け）

### 1. リリースページからダウンロード

[Releases](https://github.com/Nakki714/MediaViewer/releases) ページから最新版の `MediaViewer_vX.X.zip` をダウンロードして解凍します。

解凍後のフォルダ構成：

```
MediaViewer/
├── MediaViewer.exe          ← アプリ本体
└── MediaServer/
    ├── server.exe           ← サーバー（EXE版）
    ├── setup.bat            ← 初回セットアップ用
    └── start_server.bat     ← サーバー起動用
```

> **EXE版を使う場合（推奨）：** Pythonのインストールは不要です。`server.exe` を直接起動できます。

### 2. 初回セットアップ

1. `MediaServer` フォルダを開く
2. `setup.bat` をダブルクリックして実行
   - Pythonが未インストールの場合、自動でインストールを案内します
   - 必要なライブラリが自動でインストールされます

### 3. 起動手順

アプリを使うたびに以下の順番で起動します：

1. `MediaServer/start_server.bat` を起動（バックグラウンドで動くサーバー）
2. `MediaViewer.exe` を起動

> サーバーが起動していないとアプリにメディアが表示されません。  
> 使い終わったら `start_server.bat` のウィンドウを閉じてサーバーを停止してください。

---

## 開発者向け セットアップ

### 必要なもの

- [Flutter SDK](https://docs.flutter.dev/get-started/install/windows) 3.x 以上
- [Python](https://www.python.org/downloads/) 3.10 以上
- Windows 向け Flutter 開発環境（Visual Studio Build Tools）

### セットアップ手順

```bash
# リポジトリのクローン
git clone https://github.com/Nakki714/MediaViewer.git
cd MediaViewer

# Flutter依存関係のインストール
flutter pub get

# Pythonサーバーのセットアップ
cd MediaServer
pip install -r requirements.txt

# .envファイルの作成（必要であれば）
copy .env.example .env
```

### 起動

**サーバーを起動（ターミナル1）**
```bash
cd MediaServer
python server.py
```

**Flutterアプリを起動（ターミナル2）**
```bash
cd MediaViewer
flutter run -d windows
```

### ビルド（配布用EXEの作成）

```bash
# Flutterアプリのビルド
flutter build windows

# Pythonサーバーのexe化（MediaServerフォルダ内で実行）
cd MediaServer
build_exe.bat
```

---

## フォルダ構成

```
MediaViewer/
├── lib/
│   └── main.dart              # Flutterアプリ本体
├── pubspec.yaml               # Flutter依存関係
└── MediaServer/
    ├── server.py              # FastAPIサーバー（メディアスキャン・API提供）
    ├── make_thumbnails.py     # サムネイル生成スクリプト
    ├── requirements.txt       # Python依存ライブラリ
    ├── .env.example           # 環境変数設定のサンプル
    ├── setup.bat              # 初回セットアップ用バッチ
    ├── start_server.bat       # サーバー起動用バッチ
    └── build_exe.bat          # 配布用exeビルド用バッチ
```

## 技術スタック

| 役割 | 技術 |
|------|------|
| UIアプリ | Flutter (Dart) |
| バックエンドサーバー | Python / FastAPI |
| データベース | SQLite |
| 画像処理 | Pillow |
| 動画処理 | OpenCV |
| 動画再生 | media_kit |

---

## ライセンス

MIT License