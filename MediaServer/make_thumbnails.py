import os
import sqlite3
from pathlib import Path
from dotenv import load_dotenv
from PIL import Image, ImageOps
from pillow_heif import register_heif_opener
import rawpy
import cv2
import hashlib

# HEICサポートを有効化
register_heif_opener()

# .envを読み込む
load_dotenv()

# DBパスとサムネイル保存先の設定
default_db_path = os.path.join(Path.home(), "Documents", "media_viewer.db")
DB_PATH = os.getenv("DB_PATH", default_db_path)

# サムネイルは「ドキュメント」フォルダ内の「.media_thumbnails」というフォルダに保存する
THUMBNAIL_DIR = os.path.join(Path.home(), "Documents", ".media_thumbnails")
os.makedirs(THUMBNAIL_DIR, exist_ok=True)

# サムネイルの最大サイズ
THUMB_SIZE = (300, 300)

def generate_raw_thumbnail(original_path, dest_path):
    """RAW画像のサムネイルを作る"""
    try:
        with rawpy.imread(original_path) as raw:
            rgb = raw.postprocess()
        img = Image.fromarray(rgb)

        # Exifの回転情報を取得して補正
        try:
            exif = img.getexif()
            orientation = exif.get(0x0112)  # Orientationタグ
            rotation_map = {3: 180, 6: 270, 8: 90}
            if orientation in rotation_map:
                img = img.rotate(rotation_map[orientation], expand=True)
        except Exception:
            pass

        img.thumbnail(THUMB_SIZE)
        img.save(dest_path, "JPEG", quality=70)
        return True
    except Exception as e:
        print(f"RAWエラー ({original_path}): {e}")
        return False

def generate_image_thumbnail(original_path, dest_path):
    """画像のサムネイルを作る"""
    ext = os.path.splitext(original_path)[1].lower()
    if ext in ('.raw', '.dng', '.cr2', '.nef', '.arw'):
        return generate_raw_thumbnail(original_path, dest_path)
    try:
        with Image.open(original_path) as img:
            # EXIF回転情報を自動適用
            img = ImageOps.exif_transpose(img)
            img.thumbnail(THUMB_SIZE)
            # RGBモードに変換（HEICやPNGの透明背景対策）
            if img.mode in ("RGBA", "P"):
                img = img.convert("RGB")
            img.save(dest_path, "JPEG", quality=70)
        return True
    except Exception as e:
        print(f"画像エラー ({original_path}): {e}")
        return False

def generate_video_thumbnail(original_path, dest_path):
    """動画のサムネイルを作る（最初のフレームを切り抜く）"""
    try:
        cap = cv2.VideoCapture(original_path)
        ret, frame = cap.read()
        cap.release()
        
        if ret:
            # OpenCVはBGR形式なのでRGBに直す
            frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            img = Image.fromarray(frame_rgb)
            img.thumbnail(THUMB_SIZE)
            img.save(dest_path, "JPEG", quality=70)
            return True
        return False
    except Exception as e:
        print(f"動画エラー ({original_path}): {e}")
        return False

def main():
    if not os.path.exists(DB_PATH):
        print(f"エラー: DBが見つかりません -> {DB_PATH}")
        return

    print("サムネイルの生成を開始します...")
    
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("SELECT path, type FROM media_items")
    items = cursor.fetchall()
    conn.close()

    total = len(items)
    created = 0
    skipped = 0

    for i, (original_path, media_type) in enumerate(items):
        # 修正：hash() の代わりに hashlib を使う（常に同じファイル名になる）
        file_hash = hashlib.md5(original_path.lower().encode('utf-8')).hexdigest()
        safe_filename = file_hash + ".jpg"
        dest_path = os.path.join(THUMBNAIL_DIR, safe_filename)
        
        # 1件ごとに進捗を表示（安心感のため）
        print(f"[{i+1}/{total}] 処理中: {os.path.basename(original_path)}")
        
        # 既にサムネイルが存在するか、元のファイルが消えていたらスキップ
        if os.path.exists(dest_path):
            skipped += 1
            continue
        if not os.path.exists(original_path):
            skipped += 1
            continue

        # サムネイル生成
        if media_type == 'image':
            success = generate_image_thumbnail(original_path, dest_path)
        else:
            success = generate_video_thumbnail(original_path, dest_path)

        if success:
            created += 1

        # 進行状況を表示（100件ごと）
        if (i + 1) % 100 == 0:
            print(f"進捗: {i + 1} / {total} (新規作成: {created}, スキップ: {skipped})")

    print(f"\n完了！ 新規作成: {created}件, スキップ(作成済み等): {skipped}件")
    print(f"サムネイル保存先: {THUMBNAIL_DIR}")

if __name__ == "__main__":
    main()