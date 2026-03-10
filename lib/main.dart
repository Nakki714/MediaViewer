import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:async';

// 【追加】動画再生とサムネイル用の新しいパッケージをインポート
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ja_JP', null);
  
  // 【追加】media_kitの初期化（これをしないとWindowsで動機が再生できません）
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
  MediaItem(this.file, this.date, this.type);
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
  MediaItem? _pivotItem;
  bool _isSelectionMode = false;
  bool _isScanning = false;
  int _columns = 6;
  String? _targetPath;
  String? _downloadPath;

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
    if (_targetPath != null) _scanPhotos();
  }

  void _toggleColumns() {
    setState(() {
      if (_columns == 4) _columns = 6;
      else if (_columns == 6) _columns = 8;
      else _columns = 4;
    });
  }

  Future<void> _pickPath(bool isSource) async {
    String? selected = await FilePicker.platform.getDirectoryPath();
    if (selected != null) {
      final prefs = await SharedPreferences.getInstance();
      if (isSource) {
        await prefs.setString('target_path', selected);
        setState(() => _targetPath = selected);
        _scanPhotos();
      } else {
        await prefs.setString('download_path', selected);
        setState(() => _downloadPath = selected);
      }
    }
  }

  Future<void> _scanPhotos() async {
    if (_targetPath == null || _isScanning) return;
    setState(() {
      _isScanning = true;
      _selectedItems.clear();
      _isSelectionMode = false;
      _groupedItems = {};
      _flatItems = [];
    });

    try {
      final dir = Directory(_targetPath!);
      List<MediaItem> items = [];
      DateTime lastUpdate = DateTime.now();

      final stream = dir.list(recursive: true, followLinks: false);
      await for (final entity in stream) {
        if (entity is File) {
          final path = entity.path.toLowerCase();
          MediaType? type;
          if (path.endsWith('.jpg') || path.endsWith('.jpeg') || path.endsWith('.png')) {
            type = MediaType.image;
          } else if (path.endsWith('.mp4') || path.endsWith('.mov') || path.endsWith('.avi') || path.endsWith('.mkv')) {
            type = MediaType.video;
          }

          if (type != null) {
            final stat = await entity.stat();
            // 【改善】ここではサムネイル生成を「一切行わない」。だからフリーズしない！
            items.add(MediaItem(entity, stat.modified, type));
            
            // UI更新頻度を落としてさらに軽量化
            if (DateTime.now().difference(lastUpdate).inMilliseconds > 1000) {
              _updateUI(items, sort: false); 
              lastUpdate = DateTime.now();
            }
          }
        }
      }
      _updateUI(items, sort: true);
    } catch (e) {
      debugPrint('Scan Error: $e');
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  void _updateUI(List<MediaItem> items, {bool sort = true}) {
    if (sort) {
      items.sort((a, b) => b.date.compareTo(a.date));
    }
    _flatItems = List.from(items);
    final Map<String, List<MediaItem>> grouped = {};
    for (var item in items) {
      String day = DateFormat('yyyy年MM月dd日(E)', 'ja_JP').format(item.date);
      grouped.putIfAbsent(day, () => []).add(item);
    }
    if (mounted) setState(() => _groupedItems = grouped);
  }

  Future<void> _deleteSelected() async {
    final bool? confirm = await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('削除の確認'),
        content: Text('${_selectedItems.length} 個のファイルを削除しますか？\n(ゴミ箱には入らず完全に消去されます)'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('キャンセル')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('削除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );

    if (confirm == true) {
      for (var item in _selectedItems) {
        try {
          await item.file.delete();
        } catch (e) {
          debugPrint('Delete Error: $e');
        }
      }
      _clearSelection();
      _scanPhotos();
    }
  }

  void _handleItemTap(MediaItem item) {
    final bool isControlPressed = HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.controlLeft) || 
                                 HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.controlRight);
    final bool isShiftPressed = HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftLeft) || 
                               HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftRight);

    setState(() {
      if (isShiftPressed && _pivotItem != null) {
        _isSelectionMode = true;
        int start = _flatItems.indexOf(_pivotItem!);
        int end = _flatItems.indexOf(item);
        if (start > end) { int tmp = start; start = end; end = tmp; }
        if (!isControlPressed) _selectedItems.clear();
        for (int i = start; i <= end; i++) { _selectedItems.add(_flatItems[i]); }
      } else if (isControlPressed || _isSelectionMode) {
        _isSelectionMode = true;
        if (_selectedItems.contains(item)) {
          _selectedItems.remove(item);
          if (_selectedItems.isEmpty) _isSelectionMode = false;
        } else {
          _selectedItems.add(item);
        }
        _pivotItem = item;
      } else {
        _pivotItem = item;
        Navigator.push(context, MaterialPageRoute(builder: (_) => DetailView(
          items: _flatItems, 
          initialIndex: _flatItems.indexOf(item), 
          downloadPath: _downloadPath,
          onDelete: () => _scanPhotos(),
        )));
      }
    });
  }

  Future<void> _bulkDownload() async {
    if (_downloadPath == null) return;
    for (var item in _selectedItems) {
      final name = item.file.path.split(Platform.pathSeparator).last;
      try {
        await item.file.copy('$_downloadPath${Platform.pathSeparator}$name');
      } catch(e) {
        debugPrint('Copy Error: $e');
      }
    }
    _clearSelection();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('一括保存が完了しました')));
  }

  void _clearSelection() {
    setState(() {
      _isSelectionMode = false;
      _selectedItems.clear();
      _pivotItem = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 50,
        title: const Text('マイフォト', style: TextStyle(fontSize: 16)),
        actions: [
          if (_isScanning) const Center(child: Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))),
          if (_isSelectionMode) ...[
            IconButton(icon: const Icon(Icons.download, color: Colors.blue), onPressed: _bulkDownload),
            IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: _deleteSelected),
            IconButton(icon: const Icon(Icons.close), onPressed: _clearSelection),
          ] else ...[
            IconButton(icon: const Icon(Icons.check_circle_outline), onPressed: () => setState(() => _isSelectionMode = true)),
            IconButton(icon: const Icon(Icons.grid_view), onPressed: _toggleColumns),
            IconButton(icon: const Icon(Icons.refresh), onPressed: _scanPhotos),
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
                _buildMenuButton('編集', [
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
                    final date = _groupedItems.keys.elementAt(index);
                    final items = _groupedItems[date]!;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(padding: const EdgeInsets.all(12), child: Text(date, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18))),
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: _columns, crossAxisSpacing: 2, mainAxisSpacing: 2),
                          itemCount: items.length,
                          itemBuilder: (context, i) {
                            final item = items[i];
                            final isSelected = _selectedItems.contains(item);
                            return GestureDetector(
                              onTap: () => _handleItemTap(item),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  item.type == MediaType.image 
                                    ? Image.file(item.file, fit: BoxFit.cover, cacheWidth: 400)
                                    // 【改善】遅延読み込みウィジェットを使用して画面に表示される時にサムネイルを作る
                                    : AsyncVideoThumbnail(videoPath: item.file.path),
                                  if (item.type == MediaType.video) const Center(child: Icon(Icons.play_circle_outline, color: Colors.white, size: 40)),
                                  if (isSelected) Container(color: Colors.blue.withOpacity(0.4), child: const Center(child: Icon(Icons.check_circle, color: Colors.white, size: 40))),
                                ],
                              ),
                            );
                          },
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

// 【追加】動画のサムネイルを非同期（裏側）で生成する専用ウィジェット
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
      // パスをハッシュ化して一意のファイル名にする
      final fileName = widget.videoPath.hashCode.toString();
      final destFile = '${tempDir.path}${Platform.pathSeparator}$fileName.jpeg';

      // 既に生成済みならそれを再利用
      if (File(destFile).existsSync()) {
        if (mounted) setState(() => _thumbPath = destFile);
        return;
      }

      final success = await _plugin.getVideoThumbnail(
        srcFile: widget.videoPath,
        destFile: destFile,
        width: 300,
        height: 300,
        format: 'jpeg',
        quality: 60,
        keepAspectRatio: true,
      );

      if (success && mounted) {
        setState(() => _thumbPath = destFile);
      }
    } catch (e) {
      debugPrint('Thumbnail Gen Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_thumbPath == null) return Container(color: Colors.black12);
    return Image.file(File(_thumbPath!), fit: BoxFit.cover);
  }
}

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
  
  // 【変更】video_player を media_kit に変更
  Player? _player;
  VideoController? _videoController;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
    _initMedia(_currentIndex);
  }

  Future<void> _initMedia(int index) async {
    _disposePlayer(); // 古いプレイヤーを破棄

    if (widget.items[index].type == MediaType.video) {
      // media_kitの初期化
      _player = Player();
      _videoController = VideoController(_player!);
      
      try {
        await _player!.open(Media(widget.items[index].file.path));
        _player!.setPlaylistMode(PlaylistMode.loop);
        if (mounted && _currentIndex == index) {
          setState(() {}); // 描画を更新
        } else {
          _disposePlayer();
        }
      } catch (e) {
        debugPrint('MediaKit Init Error: $e');
      }
    } else {
      if (mounted) setState(() {});
    }
  }

  void _disposePlayer() {
    _player?.dispose();
    _player = null;
    _videoController = null;
  }

  Future<void> _deleteOne() async {
    final item = widget.items[_currentIndex];
    final bool? confirm = await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('削除'),
        content: const Text('このファイルを削除しますか？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('キャンセル')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('削除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm == true) {
      try {
        await item.file.delete();
        widget.onDelete();
        if (mounted) Navigator.pop(context);
      } catch (e) {
        debugPrint('Delete Error: $e');
      }
    }
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
      onKeyEvent: (event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.escape) Navigator.pop(context);
          if (event.logicalKey == LogicalKeyboardKey.arrowRight && _currentIndex < widget.items.length - 1) {
            _pageController.nextPage(duration: const Duration(milliseconds: 200), curve: Curves.easeInOut);
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft && _currentIndex > 0) {
            _pageController.previousPage(duration: const Duration(milliseconds: 200), curve: Curves.easeInOut);
          }
          if (event.logicalKey == LogicalKeyboardKey.delete) _deleteOne();
        }
      },
      child: Scaffold(
        backgroundColor: isDark ? Colors.black : Colors.white,
        appBar: AppBar(
          backgroundColor: isDark ? Colors.black87 : Colors.white, 
          foregroundColor: isDark ? Colors.white : Colors.black,
          actions: [
            IconButton(icon: const Icon(Icons.download), onPressed: () async {
              if (widget.downloadPath == null) return;
              final name = currentItem.file.path.split(Platform.pathSeparator).last;
              try {
                await currentItem.file.copy('${widget.downloadPath}${Platform.pathSeparator}$name');
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('保存しました')));
              } catch (e) {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存に失敗しました: $e')));
              }
            }),
            IconButton(icon: const Icon(Icons.delete_outline, color: Colors.redAccent), onPressed: _deleteOne),
          ],
        ),
        body: Row(
          children: [
            Expanded(
              child: Stack(
                children: [
                  PageView.builder(
                    controller: _pageController,
                    itemCount: widget.items.length,
                    onPageChanged: (i) {
                      setState(() => _currentIndex = i);
                      _initMedia(i);
                    },
                    itemBuilder: (context, i) {
                      final isCurrentPage = (i == _currentIndex);

                      if (widget.items[i].type == MediaType.video) {
                        return Center(
                          // 【変更】VideoPlayerをMediaKitのVideoウィジェットに変更
                          child: (isCurrentPage && _videoController != null)
                              ? GestureDetector(
                                  onTap: () {
                                    if (_player != null) {
                                      _player!.state.playing ? _player!.pause() : _player!.play();
                                    }
                                  },
                                  child: Video(controller: _videoController!),
                                )
                              : const Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    CircularProgressIndicator(),
                                    SizedBox(height: 10),
                                    Text('動画を読み込み中...', style: TextStyle(color: Colors.grey)),
                                  ],
                                ),
                        );
                      } else {
                        return InteractiveViewer(child: Image.file(widget.items[i].file, fit: BoxFit.contain));
                      }
                    },
                  ),
                  if (_currentIndex > 0)
                    Positioned(left: 10, top: 0, bottom: 0, child: Center(child: IconButton(icon: const Icon(Icons.arrow_back_ios, color: Colors.white54, size: 40), onPressed: () => _pageController.previousPage(duration: const Duration(milliseconds: 200), curve: Curves.easeInOut)))),
                  if (_currentIndex < widget.items.length - 1)
                    Positioned(right: 10, top: 0, bottom: 0, child: Center(child: IconButton(icon: const Icon(Icons.arrow_forward_ios, color: Colors.white54, size: 40), onPressed: () => _pageController.nextPage(duration: const Duration(milliseconds: 200), curve: Curves.easeInOut)))),
                ],
              ),
            ),
            Container(
              width: 250, 
              decoration: BoxDecoration(
                color: isDark ? Colors.black87 : Colors.grey[50],
                border: Border(left: BorderSide(color: isDark ? Colors.white12 : Colors.black12))
              ),
              padding: const EdgeInsets.all(20), 
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, 
                children: [
                  Text('情報', style: TextStyle(color: isDark ? Colors.white : Colors.black, fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 20),
                  Text('種別: ${currentItem.type == MediaType.image ? "画像" : "動画"}', style: TextStyle(color: isDark ? Colors.white70 : Colors.black87, fontSize: 12)),
                  const SizedBox(height: 10),
                  Text('日付: ${DateFormat('yyyy/MM/dd HH:mm').format(currentItem.date)}', style: TextStyle(color: isDark ? Colors.white70 : Colors.black87, fontSize: 12)),
                  const SizedBox(height: 10),
                  Text('ファイル名:\n${currentItem.file.path.split(Platform.pathSeparator).last}', style: TextStyle(color: isDark ? Colors.white70 : Colors.black87, fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}