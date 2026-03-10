import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:isolate';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:async';
import 'dart:math';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
import 'package:exif/exif.dart';
import 'package:geocoding/geocoding.dart';
import 'package:url_launcher/url_launcher.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ja_JP', null);
  MediaKit.ensureInitialized();
  runApp(const MyPhotoApp());
}

class MyPhotoApp extends StatefulWidget {
  const MyPhotoApp({super.key});
  @override
  State<MyPhotoApp> createState() => _MyPhotoAppState();
}

class _MyPhotoAppState extends State<MyPhotoApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _themeMode = (prefs.getBool('isDark') ?? true) ? ThemeMode.dark : ThemeMode.light;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'どこでもフォト',
      theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
      darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      themeMode: _themeMode,
      home: PhotoGalleryPage(
        onThemeChanged: (isDark) async {
          setState(() => _themeMode = isDark ? ThemeMode.dark : ThemeMode.light);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('isDark', isDark);
        },
      ),
    );
  }
}

enum MediaType { image, video }

class MediaItem {
  final File file;
  final DateTime date;
  final MediaType type;
  final int sizeBytes;
  String? cityLocation; // 後から非同期で追加
  double aspectRatio = 1.0; // グリッド用（初期値1.0）

  MediaItem(this.file, this.date, this.type, this.sizeBytes);
}

class PhotoGalleryPage extends StatefulWidget {
  final Function(bool) onThemeChanged;
  const PhotoGalleryPage({super.key, required this.onThemeChanged});
  @override
  State<PhotoGalleryPage> createState() => _PhotoGalleryPageState();
}

class _PhotoGalleryPageState extends State<PhotoGalleryPage> {
  Map<String, List<MediaItem>> _groupedItems = {};
  List<MediaItem> _flatItems = [];
  final Set<MediaItem> _selectedItems = {};
  MediaItem? _pivotItem; // Shiftクリック用の起点
  
  bool _isScanning = false;
  String? _targetPath;
  String? _downloadPath;
  final Map<String, String> _locationCache = {}; // 座標ハッシュ -> 市区町村 のキャッシュ

  @override
  void initState() {
    super.initState();
    _loadSavedPaths();
  }

  Future<void> _loadSavedPaths() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _targetPath = prefs.getString('target_path');
      _downloadPath = prefs.getString('download_path');
    });
    if (_targetPath != null) _scanPhotosBackground();
  }

  Future<void> _pickPath(bool isSource) async {
    String? selected = await FilePicker.platform.getDirectoryPath();
    if (selected != null) {
      final prefs = await SharedPreferences.getInstance();
      if (isSource) {
        await prefs.setString('target_path', selected);
        setState(() => _targetPath = selected);
        _scanPhotosBackground();
      } else {
        await prefs.setString('download_path', selected);
        setState(() => _downloadPath = selected);
      }
    }
  }

  // 【追加】_scanPhotosBackgroundから呼び出されるUI更新用のヘルパーメソッド
  void _updateUI(List<MediaItem> items, {required bool sort}) {
    if (!mounted) return;
    setState(() {
      _flatItems = List.from(items);
      if (sort) {
        _flatItems.sort((a, b) => b.date.compareTo(a.date));
      }
      final Map<String, List<MediaItem>> grouped = {};
      for (var item in _flatItems) {
        String day = DateFormat('yyyy年MM月dd日(E)', 'ja_JP').format(item.date);
        grouped.putIfAbsent(day, () => []).add(item);
      }
      _groupedItems = grouped;
    });
  }

  // 【改善】リアルタイム表示とバックグラウンド処理を両立させるIsolate通信
  Future<void> _scanPhotosBackground() async {
    if (_targetPath == null || _isScanning) return;
    setState(() {
      _isScanning = true;
      _selectedItems.clear();
      _groupedItems = {};
      _flatItems = [];
    });

    try {
      // 裏側スレッドとの通信用ポートを作成
      final receivePort = ReceivePort();
      await Isolate.spawn(_isolateScanTask, [_targetPath!, receivePort.sendPort]);

      List<MediaItem> buffer = [];
      DateTime lastUpdate = DateTime.now();

      // 裏側からファイルが届くたびに受け取る
      await for (final message in receivePort) {
        if (message == null) {
          break; // スキャン完了の合図
        } else if (message is MediaItem) {
          buffer.add(message);

          // 500ミリ秒ごとに画面を更新（これで見つけた端から画像が出てきます）
          if (DateTime.now().difference(lastUpdate).inMilliseconds > 500) {
            _updateUI(buffer, sort: false);
            lastUpdate = DateTime.now();
          }
        }
      }

      // 最後に全件を日付順にソートして完了
      _updateUI(buffer, sort: true);
      _fetchLocationsForGroups(); // 位置情報の取得を開始
    } catch (e) {
      debugPrint('Scan Error: $e');
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  // 裏側スレッドで実行されるタスク（メインスレッドを止めない）
  static Future<void> _isolateScanTask(List<dynamic> args) async {
    String targetPath = args[0];
    SendPort sendPort = args[1];

    try {
      final dir = Directory(targetPath);
      if (!dir.existsSync()) {
        sendPort.send(null);
        return;
      }

      // 非同期のリストアップを使うことで、ネットワークドライブでも1件ずつ即座に処理可能
      final stream = dir.list(recursive: true, followLinks: false);
      await for (final entity in stream) {
        if (entity is File) {
          final path = entity.path.toLowerCase();
          MediaType? type;
          
          if (path.endsWith('.jpg') || path.endsWith('.jpeg') || path.endsWith('.png') || path.endsWith('.heic')) {
            type = MediaType.image;
          } else if (path.endsWith('.mp4') || path.endsWith('.mov') || path.endsWith('.avi') || path.endsWith('.mkv')) {
            type = MediaType.video;
          }

          if (type != null) {
            final stat = await entity.stat();
            // 見つけたファイルをその都度メインの画面に投げ飛ばす
            sendPort.send(MediaItem(entity, stat.modified, type, stat.size));
          }
        }
      }
    } catch (e) {
      // 読み取り権限がないファイルなどは無視して進める
    } finally {
      // 最後に完了の合図(null)を送る
      sendPort.send(null);
    }
  }

  // 各日付グループの代表写真から位置情報を取得（重いのでメインスレッドで少しずつ実行）
  Future<void> _fetchLocationsForGroups() async {
    for (var dateKey in _groupedItems.keys) {
      if (!mounted) break;
      final items = _groupedItems[dateKey]!;
      List<String> cities = [];
      
      // グループ内の最大5件まで位置情報をチェック（API制限対策と高速化のため）
      int checkCount = min(items.length, 5);
      for (int i = 0; i < checkCount; i++) {
        if (items[i].type == MediaType.image) {
          try {
            final bytes = await items[i].file.readAsBytes();
            final tags = await readExifFromBytes(bytes);
            if (tags.containsKey('GPS GPSLatitude') && tags.containsKey('GPS GPSLongitude')) {
              final lat = _convertExifToDouble(tags['GPS GPSLatitude']!.values.toList());
              final lon = _convertExifToDouble(tags['GPS GPSLongitude']!.values.toList());
              final hash = "${lat.toStringAsFixed(3)},${lon.toStringAsFixed(3)}";

              if (_locationCache.containsKey(hash)) {
                if (!cities.contains(_locationCache[hash]!)) cities.add(_locationCache[hash]!);
              } else {
                List<Placemark> placemarks = await placemarkFromCoordinates(lat, lon);
                if (placemarks.isNotEmpty) {
                  String city = placemarks.first.locality ?? placemarks.first.administrativeArea ?? "";
                  if (city.isNotEmpty) {
                    _locationCache[hash] = city;
                    if (!cities.contains(city)) cities.add(city);
                  }
                }
              }
            }
          } catch (e) {
            // EXIFがない、または読めない場合はスキップ
          }
        }
      }

      if (cities.isNotEmpty && mounted) {
        setState(() {
          for (var item in items) {
            if (cities.length == 1) {
              item.cityLocation = cities.first;
            } else {
              item.cityLocation = "${cities.first}と他${cities.length - 1}か所";
            }
          }
        });
      }
    }
  }

  double _convertExifToDouble(List<dynamic> values) {
    if (values.length != 3) return 0.0;
    double d = values[0].numerator / values[0].denominator;
    double m = values[1].numerator / values[1].denominator;
    double s = values[2].numerator / values[2].denominator;
    return d + (m / 60.0) + (s / 3600.0);
  }

  // 【改善】Excelライクな複数選択の実装
  void _handleItemTap(MediaItem item) {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final isCtrl = keys.contains(LogicalKeyboardKey.controlLeft) || keys.contains(LogicalKeyboardKey.controlRight);
    final isShift = keys.contains(LogicalKeyboardKey.shiftLeft) || keys.contains(LogicalKeyboardKey.shiftRight);

    setState(() {
      if (isShift && _pivotItem != null) {
        // Shiftクリック: 範囲選択
        int start = _flatItems.indexOf(_pivotItem!);
        int end = _flatItems.indexOf(item);
        if (start > end) { int tmp = start; start = end; end = tmp; }
        if (!isCtrl) _selectedItems.clear(); // Ctrl同時押しでなければ既存の選択をクリア
        for (int i = start; i <= end; i++) {
          _selectedItems.add(_flatItems[i]);
        }
      } else if (isCtrl) {
        // Ctrlクリック: 個別トグル
        if (_selectedItems.contains(item)) {
          _selectedItems.remove(item);
        } else {
          _selectedItems.add(item);
        }
        _pivotItem = item;
      } else {
        if (_selectedItems.isNotEmpty) {
           // 選択モード中に普通にクリックしたら選択解除
           _selectedItems.clear();
        } else {
          // 単一クリック: 詳細ビューへ
          _pivotItem = item;
          Navigator.push(context, MaterialPageRoute(builder: (_) => DetailView(
            items: _flatItems, 
            initialIndex: _flatItems.indexOf(item), 
            downloadPath: _downloadPath,
            onDelete: () => _scanPhotosBackground(),
          )));
        }
      }
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedItems.clear();
      _pivotItem = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    bool isSelectionMode = _selectedItems.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 50,
        title: Text(isSelectionMode ? '${_selectedItems.length}件選択中' : 'マイフォト', style: const TextStyle(fontSize: 16)),
        actions: [
          if (_isScanning) const Center(child: Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))),
          if (isSelectionMode) ...[
            IconButton(icon: const Icon(Icons.download, color: Colors.blue), onPressed: () {}), // 一括DL処理等
            IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: () {}), // 一括削除等
            IconButton(icon: const Icon(Icons.close), onPressed: _clearSelection),
          ] else ...[
            IconButton(icon: const Icon(Icons.refresh), onPressed: _scanPhotosBackground),
          ]
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            color: Theme.of(context).cardColor,
            child: Row(
              children: [
                _buildMenuButton('ファイル', [
                  PopupMenuItem(child: const Text('フォルダを開く'), onTap: () => Future(() => _pickPath(true))),
                  PopupMenuItem(child: const Text('ダウンロード先の設定'), onTap: () => Future(() => _pickPath(false))),
                  PopupMenuItem(child: const Text('終了'), onTap: () => exit(0)),
                ]),
                _buildMenuButton('表示', [
                  PopupMenuItem(child: Text(isDark ? 'ライトモード' : 'ダークモード'), onTap: () => Future(() => widget.onThemeChanged(!isDark))),
                ]),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(_targetPath ?? 'フォルダ未選択', style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ),
          Expanded(
            child: _targetPath == null 
              ? Center(child: ElevatedButton(onPressed: () => _pickPath(true), child: const Text('フォルダを選択')))
              : ListView.builder(
                  itemCount: _groupedItems.length,
                  itemBuilder: (context, index) {
                    final dateKey = _groupedItems.keys.elementAt(index);
                    final items = _groupedItems[dateKey]!;
                    final locationText = items.first.cityLocation ?? "";

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                          child: Row(
                            children: [
                              Text(dateKey, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                              if (locationText.isNotEmpty) ...[
                                const SizedBox(width: 12),
                                const Icon(Icons.location_on, size: 14, color: Colors.grey),
                                Expanded(child: Text(locationText, style: const TextStyle(color: Colors.grey, fontSize: 14), overflow: TextOverflow.ellipsis)),
                              ]
                            ],
                          ),
                        ),
                        // 【改善】アスペクト比可変のグリッド（Googleフォト風 Wrapレイアウト）
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8.0),
                          child: Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: items.map((item) {
                              final isSelected = _selectedItems.contains(item);
                              // 高さ固定(約150px)で、幅はアスペクト比に応じて自然に広がる
                              return GestureDetector(
                                onTap: () => _handleItemTap(item),
                                child: Stack(
                                  children: [
                                    Container(
                                      height: 150,
                                      // Imageがロードされるまでの一時的な幅（正方形に近い）
                                      constraints: const BoxConstraints(minWidth: 100, maxWidth: 300), 
                                      child: item.type == MediaType.image 
                                        ? Image.file(item.file, fit: BoxFit.cover)
                                        : AsyncVideoThumbnail(videoPath: item.file.path),
                                    ),
                                    if (item.type == MediaType.video) const Positioned.fill(child: Center(child: Icon(Icons.play_circle_outline, color: Colors.white, size: 40))),
                                    if (isSelected) Positioned.fill(child: Container(color: Colors.blue.withOpacity(0.4), child: const Center(child: Icon(Icons.check_circle, color: Colors.white, size: 40)))),
                                    // 選択用チェックボックス（左上）
                                    Positioned(
                                      top: 4, left: 4,
                                      child: GestureDetector(
                                        onTap: () {
                                          setState(() {
                                            if (isSelected) _selectedItems.remove(item);
                                            else _selectedItems.add(item);
                                            _pivotItem = item;
                                          });
                                        },
                                        child: Icon(isSelected ? Icons.check_circle : Icons.circle_outlined, color: isSelected ? Colors.blue : Colors.white70),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ],
                    );
                  },
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuButton(String label, List<PopupMenuEntry> items) {
    return PopupMenuButton(
      offset: const Offset(0, 32),
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: Text(label, style: const TextStyle(fontSize: 13))),
      itemBuilder: (context) => items,
    );
  }
}

class AsyncVideoThumbnail extends StatefulWidget {
  final String videoPath;
  const AsyncVideoThumbnail({super.key, required this.videoPath});
  @override
  State<AsyncVideoThumbnail> createState() => _AsyncVideoThumbnailState();
}

class _AsyncVideoThumbnailState extends State<AsyncVideoThumbnail> {
  String? _thumbPath;
  final _plugin = FcNativeVideoThumbnail();

  @override
  void initState() {
    super.initState();
    _generateThumbnail();
  }

  Future<void> _generateThumbnail() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final fileName = widget.videoPath.hashCode.toString();
      final destFile = '${tempDir.path}${Platform.pathSeparator}$fileName.jpeg';

      if (File(destFile).existsSync()) {
        if (mounted) setState(() => _thumbPath = destFile);
        return;
      }
      final success = await _plugin.getVideoThumbnail(
        srcFile: widget.videoPath, destFile: destFile, width: 300, height: 300, format: 'jpeg', quality: 60, keepAspectRatio: true,
      );
      if (success && mounted) setState(() => _thumbPath = destFile);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_thumbPath == null) return Container(color: Colors.black12, width: 150);
    return Image.file(File(_thumbPath!), fit: BoxFit.cover);
  }
}

// ============================================
// 詳細ビュー（動画プレイヤー＆情報ペイン）
// ============================================
class DetailView extends StatefulWidget {
  final List<MediaItem> items;
  final int initialIndex;
  final String? downloadPath;
  final VoidCallback onDelete;
  const DetailView({super.key, required this.items, required this.initialIndex, this.downloadPath, required this.onDelete});
  @override
  State<DetailView> createState() => _DetailViewState();
}

class _DetailViewState extends State<DetailView> {
  late PageController _pageController;
  late int _currentIndex;
  
  Player? _player;
  VideoController? _videoController;
  
  bool _showInfo = false;
  bool _isFullscreen = false;
  bool _isMuted = false;

  // EXIFデータ格納用
  Map<String, IfdTag> _currentExif = {};
  double? _lat;
  double? _lon;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
    _loadInfoState();
    _initMedia(_currentIndex);
  }

  Future<void> _loadInfoState() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _showInfo = prefs.getBool('showInfoPane') ?? false;
    });
  }

  Future<void> _toggleInfo() async {
    setState(() => _showInfo = !_showInfo);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('showInfoPane', _showInfo);
  }

  Future<void> _initMedia(int index) async {
    _disposePlayer();
    final item = widget.items[index];

    // EXIF読み込み
    if (item.type == MediaType.image) {
      try {
        final bytes = await item.file.readAsBytes();
        final tags = await readExifFromBytes(bytes);
        double? lat, lon;
        if (tags.containsKey('GPS GPSLatitude')) {
          lat = _convertExifToDouble(tags['GPS GPSLatitude']!.values.toList());
          lon = _convertExifToDouble(tags['GPS GPSLongitude']!.values.toList());
        }
        if (mounted) {
          setState(() {
            _currentExif = tags;
            _lat = lat;
            _lon = lon;
          });
        }
      } catch (e) {
        if (mounted) setState(() { _currentExif = {}; _lat = null; _lon = null; });
      }
    } else {
      if (mounted) setState(() { _currentExif = {}; _lat = null; _lon = null; });
    }

    // 動画初期化
    if (item.type == MediaType.video) {
      _player = Player();
      _videoController = VideoController(_player!);
      try {
        await _player!.open(Media(item.file.path));
        _player!.setPlaylistMode(PlaylistMode.loop);
        if (_isMuted) _player!.setVolume(0);
        if (mounted && _currentIndex == index) setState(() {});
      } catch (_) {}
    }
  }

  double _convertExifToDouble(List<dynamic> values) {
    if (values.length != 3) return 0.0;
    return (values[0].numerator / values[0].denominator) + 
           ((values[1].numerator / values[1].denominator) / 60.0) + 
           ((values[2].numerator / values[2].denominator) / 3600.0);
  }

  void _disposePlayer() {
    _player?.dispose();
    _player = null;
    _videoController = null;
  }

  Future<void> _deleteOne() async {
    // 省略：削除の確認ダイアログ
  }

  void _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    
    final key = event.logicalKey;
    final isShift = HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftLeft) || 
                    HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftRight);

    if (key == LogicalKeyboardKey.escape) {
      if (_isFullscreen) setState(() => _isFullscreen = false);
      else Navigator.pop(context);
    }
    else if (key == LogicalKeyboardKey.keyF) {
      setState(() => _isFullscreen = !_isFullscreen);
    }
    else if (key == LogicalKeyboardKey.keyD && isShift) {
       // Shift+D ダウンロード
    }
    else if (key == LogicalKeyboardKey.keyR && isShift) {
       // Shift+R 回転（実装は複雑なため割愛しますが、トリガーはここです）
    }

    // 動画コントロール
    if (_player != null) {
      if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK) {
        _player!.state.playing ? _player!.pause() : _player!.play();
      } else if (key == LogicalKeyboardKey.keyM) {
        setState(() {
          _isMuted = !_isMuted;
          _player!.setVolume(_isMuted ? 0 : 100);
        });
      } else if (key == LogicalKeyboardKey.arrowRight) {
        _player!.seek(_player!.state.position + const Duration(seconds: 5));
      } else if (key == LogicalKeyboardKey.arrowLeft) {
        _player!.seek(_player!.state.position - const Duration(seconds: 5));
      }
    } else {
      // 画像時の左右移動
      if (key == LogicalKeyboardKey.arrowRight && _currentIndex < widget.items.length - 1) {
        _pageController.nextPage(duration: const Duration(milliseconds: 200), curve: Curves.easeInOut);
      } else if (key == LogicalKeyboardKey.arrowLeft && _currentIndex > 0) {
        _pageController.previousPage(duration: const Duration(milliseconds: 200), curve: Curves.easeInOut);
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB"];
    var i = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(1)} ${suffixes[i]}';
  }

  @override
  void dispose() {
    _disposePlayer();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentItem = widget.items[_currentIndex];
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return KeyboardListener(
      focusNode: FocusNode()..requestFocus(),
      onKeyEvent: _handleKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // メインコンテンツ（画像・動画）
            Row(
              children: [
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: widget.items.length,
                    onPageChanged: (i) {
                      setState(() => _currentIndex = i);
                      _initMedia(i);
                    },
                    itemBuilder: (context, i) {
                      if (widget.items[i].type == MediaType.video) {
                        return Center(
                          child: (i == _currentIndex && _videoController != null)
                              ? GestureDetector(
                                  onTap: () { if (_player != null) _player!.state.playing ? _player!.pause() : _player!.play(); },
                                  child: Video(controller: _videoController!, controls: AdaptiveVideoControls),
                                )
                              : const CircularProgressIndicator(),
                        );
                      } else {
                        return InteractiveViewer(child: Image.file(widget.items[i].file, fit: BoxFit.contain));
                      }
                    },
                  ),
                ),
                // 右側：情報ペイン（トグル可能）
                if (_showInfo && !_isFullscreen)
                  Container(
                    width: 300,
                    color: isDark ? Colors.grey[900] : Colors.white,
                    padding: const EdgeInsets.all(20),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('情報', style: TextStyle(color: isDark ? Colors.white : Colors.black, fontSize: 18, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 20),
                          
                          // 日付
                          Text(DateFormat('yyyy年MM月dd日(E) HH:mm', 'ja_JP').format(currentItem.date), style: TextStyle(color: isDark ? Colors.white70 : Colors.black87)),
                          const Divider(height: 30),

                          // 機器情報
                          if (_currentExif.containsKey('Image Make') || _currentExif.containsKey('Image Model')) ...[
                            Text('${_currentExif['Image Make']?.printable ?? ''} ${_currentExif['Image Model']?.printable ?? ''}'.trim(), 
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black)),
                            const SizedBox(height: 4),
                            Text('f/${_currentExif['EXIF FNumber']?.printable ?? '-'}  ${_currentExif['EXIF ExposureTime']?.printable ?? '-'}s  ${_currentExif['EXIF FocalLength']?.printable ?? '-'}mm  ISO${_currentExif['EXIF ISOSpeedRatings']?.printable ?? '-'}',
                              style: const TextStyle(color: Colors.grey, fontSize: 12)),
                            const Divider(height: 30),
                          ],

                          // ファイル情報
                          Text(currentItem.file.path.split(Platform.pathSeparator).last, 
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black)),
                          const SizedBox(height: 4),
                          Text('${_currentExif['EXIF ExifImageWidth']?.printable ?? '-'} × ${_currentExif['EXIF ExifImageLength']?.printable ?? '-'}',
                            style: const TextStyle(color: Colors.grey, fontSize: 12)),
                          const SizedBox(height: 12),
                          Text('パス:\n${currentItem.file.path}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
                          const SizedBox(height: 8),
                          Text('容量: ${_formatBytes(currentItem.sizeBytes)}', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                          const Divider(height: 30),

                          // 位置情報
                          if (_lat != null && _lon != null) ...[
                            Row(
                              children: [
                                const Icon(Icons.location_on, color: Colors.red),
                                const SizedBox(width: 8),
                                Expanded(child: Text(currentItem.cityLocation ?? "位置情報あり", style: TextStyle(color: isDark ? Colors.white : Colors.black))),
                              ],
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              onPressed: () => launchUrl(Uri.parse('https://maps.google.com/?q=$_lat,$_lon')),
                              icon: const Icon(Icons.map, size: 16),
                              label: const Text('Googleマップで開く'),
                            )
                          ] else ...[
                            const Text('位置情報なし', style: TextStyle(color: Colors.grey))
                          ]
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            
            // 右上オーバーレイアイコン群（写真に被らないよう背景グラデなどを敷くと良いですが今回はシンプルに配置）
            if (!_isFullscreen)
              Positioned(
                top: 10, right: _showInfo ? 310 : 10,
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(_showInfo ? Icons.info : Icons.info_outline, color: Colors.white, size: 28),
                      onPressed: _toggleInfo,
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.white, size: 28),
                      onPressed: _deleteOne,
                    ),
                    PopupMenuButton(
                      icon: const Icon(Icons.more_vert, color: Colors.white, size: 28),
                      itemBuilder: (context) => [
                        PopupMenuItem(child: const Text('ダウンロード (Shift+D)'), onTap: () {}),
                        PopupMenuItem(child: const Text('左に回転 (Shift+R)'), onTap: () {}),
                      ],
                    ),
                  ],
                ),
              ),
              
            // 戻るボタン
            if (!_isFullscreen)
              Positioned(
                top: 10, left: 10,
                child: IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white, size: 28), onPressed: () => Navigator.pop(context)),
              ),
          ],
        ),
      ),
    );
  }
}