import os
from pathlib import Path
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from dotenv import load_dotenv
import sqlite3
import hashlib

load_dotenv()
app = FastAPI()

default_db_path = os.path.join(Path.home(), "Documents", "media_viewer.db")
DB_PATH = os.getenv("DB_PATH", default_db_path)

# サムネイル保存先
THUMBNAIL_DIR = os.path.join(Path.home(), "Documents", ".media_thumbnails")

# ---------------------------------------------------------
# 【新機能】サムネイルフォルダをWeb公開する
# これにより http://localhost:8000/thumbs/ファイル名.jpg で画像が見れるようになります
# ---------------------------------------------------------
if os.path.exists(THUMBNAIL_DIR):
    app.mount("/thumbs", StaticFiles(directory=THUMBNAIL_DIR), name="thumbs")

@app.get("/api/media")
def get_all_media():
    """Flutterアプリに全データとサムネイルのURLを返す"""
    if not os.path.exists(DB_PATH):
        return {"error": "DB not found"}
    
    try:
        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row # 列名で取得できるようにする
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM media_items ORDER BY date_millis DESC")
        rows = cursor.fetchall()
        conn.close()
        
        results = []
        for row in rows:
            item = dict(row)
            # 修正：ここも hashlib を使う
            file_hash = hashlib.md5(item['path'].lower().encode('utf-8')).hexdigest()
            thumb_name = file_hash + ".jpg"
            item['thumbnail_url'] = f"http://localhost:8000/thumbs/{thumb_name}"
            results.append(item)
            
        return results
    except Exception as e:
        return {"error": str(e)}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)