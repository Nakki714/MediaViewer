import os
from pathlib import Path
from fastapi import FastAPI, Request
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from dotenv import load_dotenv
import sqlite3
import hashlib
import socket

load_dotenv()
app = FastAPI()

# サーバー自身のIPを取得
def get_server_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "localhost"

SERVER_IP = get_server_ip()

default_db_path = os.path.join(Path.home(), "Documents", "media_viewer.db")
DB_PATH = os.getenv("DB_PATH", default_db_path)

# 起動時にDBとテーブルを自動作成
def init_db():
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS media_items (
            path TEXT PRIMARY KEY,
            date_millis INTEGER NOT NULL,
            type TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            orientation INTEGER NOT NULL DEFAULT 0
        )
    ''')
    # 既存DBへのマイグレーション（orientation列がない場合に追加）
    try:
        cursor.execute('ALTER TABLE media_items ADD COLUMN orientation INTEGER NOT NULL DEFAULT 0')
    except Exception:
        pass
    conn.commit()
    conn.close()

init_db()

# サムネイル保存先（起動時に自動作成）
THUMBNAIL_DIR = os.path.join(Path.home(), "Documents", ".media_thumbnails")
os.makedirs(THUMBNAIL_DIR, exist_ok=True)
app.mount("/thumbs", StaticFiles(directory=THUMBNAIL_DIR), name="thumbs")

RAW_EXTENSIONS = {'.dng', '.raw', '.cr2', '.nef', '.arw'}

def get_orientation(file_path: str) -> int:
    """DNGなどのRAWファイルからEXIF回転情報をquarterTurns形式で取得する"""
    ext = os.path.splitext(file_path)[1].lower()
    if ext not in RAW_EXTENSIONS:
        return 0
    try:
        from PIL import Image
        with Image.open(file_path) as img:
            exif = img.getexif()
            orientation = exif.get(0x0112, 1)
            return {1: 0, 3: 2, 6: 1, 8: 3}.get(orientation, 0)
    except Exception:
        return 0
SUPPORTED_IMAGE_EXTENSIONS = {'.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.heic', '.raw', '.tiff', '.dng', '.cr2', '.nef', '.arw'}
SUPPORTED_VIDEO_EXTENSIONS = {'.mp4', '.mkv', '.avi', '.mov', '.flv', '.wmv', '.webm', '.m4v', '.ts', '.m2ts', '.mts'}

@app.get("/api/media")
def get_all_media(request: Request, folder: str = None):
    """Flutterアプリに全データとサムネイルのURLを返す
    
    Args:
        folder: フィルタリング対象のフォルダパス（指定時はそのフォルダ配下のみを返す）
    """
    if not os.path.exists(DB_PATH):
        return {"error": "DB not found"}
    
    try:
        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row # 列名で取得できるようにする
        cursor = conn.cursor()
        
        # 最初にDBから全メディアを取得
        cursor.execute("SELECT * FROM media_items ORDER BY date_millis DESC")
        all_rows = cursor.fetchall()
        
        # 存在しないファイルを検出して削除
        deleted_count = 0
        rows_to_remove = []
        for row in all_rows:
            if not os.path.exists(row['path']):
                # ファイルが存在しないので、DBから削除
                cursor.execute("DELETE FROM media_items WHERE path = ?", (row['path'],))
                deleted_count += 1
                rows_to_remove.append(row)
        
        if deleted_count > 0:
            conn.commit()
            print(f"[クリーンアップ] {deleted_count}件の削除されたファイルをDBから削除しました")
        
        # 存在するファイルのみをメモリに保持
        valid_rows = [row for row in all_rows if row not in rows_to_remove]
        
        # フォルダ指定がある場合、さらにフィルタリング
        if folder:
            folder_normalized = os.path.normpath(folder)
            if not folder_normalized.endswith(os.sep):
                folder_normalized += os.sep
            valid_rows = [
                row for row in valid_rows 
                if row['path'].lower().startswith(folder_normalized.lower())
            ]
        
        conn.close()
        
        results = []
        for row in valid_rows:
            item = dict(row)
            # 修正：ここも hashlib を使う
            file_hash = hashlib.md5(item['path'].lower().encode('utf-8')).hexdigest()
            thumb_name = file_hash + ".jpg"
            item['thumbnail_url'] = f"http://{SERVER_IP}:8000/thumbs/{thumb_name}"
            results.append(item)
            
        return results
    except Exception as e:
        return {"error": str(e)}

@app.get("/api/scan")
def scan_folder(folder: str):
    """指定されたフォルダをスキャンしてDBに登録する"""
    if not os.path.exists(folder):
        return {"error": f"Folder not found: {folder}"}
    
    if not os.path.isdir(folder):
        return {"error": f"Not a directory: {folder}"}
    
    try:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()
        
        added_count = 0
        skipped_count = 0
        
        # フォルダ内を再帰的にスキャン
        for root, dirs, files in os.walk(folder):
            for file in files:
                file_path = os.path.join(root, file)
                ext = os.path.splitext(file)[1].lower()
                
                # ファイル種別を判定
                if ext in SUPPORTED_IMAGE_EXTENSIONS:
                    media_type = 'image'
                elif ext in SUPPORTED_VIDEO_EXTENSIONS:
                    media_type = 'video'
                else:
                    continue  # サポートされていない拡張子はスキップ
                
                try:
                    file_stat = os.stat(file_path)
                    size_bytes = file_stat.st_size
                    date_millis = int(file_stat.st_mtime * 1000)
                    orientation = get_orientation(file_path)
                    
                    # DBに挿入（既存ならスキップ）
                    cursor.execute(
                        """INSERT OR IGNORE INTO media_items 
                           (path, date_millis, type, size_bytes, orientation) 
                           VALUES (?, ?, ?, ?, ?)""",
                        (file_path, date_millis, media_type, size_bytes, orientation)
                    )
                    
                    # 実際に挿入されたかを確認
                    if cursor.rowcount > 0:
                        added_count += 1
                    else:
                        skipped_count += 1
                        
                except Exception as e:
                    print(f"Error processing file {file_path}: {e}")
                    skipped_count += 1
        
        conn.commit()
        conn.close()
        
        return {
            "status": "success",
            "added": added_count,
            "skipped": skipped_count,
            "total": added_count + skipped_count,
            "message": f"フォルダをスキャンして{added_count}件の新規メディアを追加しました。サムネイルを生成するには /api/generate-thumbnails を実行してください。"
        }
    except Exception as e:
        return {"error": str(e)}

@app.get("/api/generate-thumbnails")
def generate_thumbnails():
    """DB内のメディアのサムネイルを生成する"""
    try:
        import make_thumbnails
        make_thumbnails.main()
        return {
            "status": "success",
            "message": "サムネイル生成が完了しました",
        }
    except Exception as e:
        return {"error": str(e)}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)