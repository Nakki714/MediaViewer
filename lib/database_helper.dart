import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider/path_provider.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  // データベースを呼び出す（まだ無ければ作る）
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('media_viewer.db');
    return _database!;
  }

  // データベースの初期設定
  Future<Database> _initDB(String filePath) async {
    final directory = await getApplicationDocumentsDirectory();
    final path = join(directory.path, filePath);

    return await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: _createDB,
      ),
    );
  }

  // テーブル（データを保存する表）の作成
  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE media_items (
        path TEXT PRIMARY KEY,
        date_millis INTEGER NOT NULL,
        type TEXT NOT NULL,
        size_bytes INTEGER NOT NULL
      )
    ''');
  }

  // データを保存する
  Future<void> insertMediaItem(Map<String, dynamic> item) async {
    final db = await instance.database;
    await db.insert(
      'media_items',
      item,
      conflictAlgorithm: ConflictAlgorithm.replace, // 既に同じパスがあれば上書き
    );
  }

  // 保存したデータを全て読み込む
  Future<List<Map<String, dynamic>>> readAllMediaItems() async {
    final db = await instance.database;
    // 日付の新しい順（降順）で取得
    return await db.query('media_items', orderBy: 'date_millis DESC');
  }

  // データベースを空にする（更新・リセット用）
  Future<void> clearAll() async {
    final db = await instance.database;
    await db.delete('media_items');
  }
}