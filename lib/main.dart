import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
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
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  
  WindowOptions windowOptions = const WindowOptions(
    title: 'Media Viewer',
    center: true,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

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
      title: 'Media Viewer',
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

  SnackBar? _downloadSnackBar;
final ValueNotifier<String> _downloadStatus = ValueNotifier("");
  final Set<MediaItem> _selectedItems = {};
  MediaItem? _pivotItem;
  
  bool _isScanning = false;
  int _columns = 8;
  String? _targetPath;
  String? _downloadPath;
  
  final FocusNode _gridFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _loadSavedPaths();
  }

  @override
  void dispose() {
    _gridFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadSavedPaths() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _targetPath = prefs.getString('target_path');
      _downloadPath = prefs.getString('download_path');
    });
    if (_targetPath != null) {
      _scanPhotosBackground();
    }
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

  void _toggleColumns() {
    setState(() {
      if (_columns == 8) {
        _columns = 10;
      } else if (_columns == 10) {
        _columns = 12;
      } else {
        _columns = 8;
      }
    });
  }

  Future<void> _scanPhotosBackground() async {
    if (_targetPath == null || _isScanning) {
      return;
    }
    setState(() {
      _isScanning = true;
      _selectedItems.clear();
      _groupedItems = {};
      _flatItems = [];
    });

    try {
      final receivePort = ReceivePort();
      await Isolate.spawn(_isolateScanTask, [_targetPath!, receivePort.sendPort]);

      List<MediaItem> buffer = [];
      DateTime lastUpdate = DateTime.now();

      await for (final message in receivePort) {
        if (message == null) {
          break;
        }
        if (message is MediaItem) {
          buffer.add(message);
          if (DateTime.now().difference(lastUpdate).inMilliseconds > 500) {
            _updateUI(buffer, sort: false);
            lastUpdate = DateTime.now();
          }
        }
      }
      _updateUI(buffer, sort: true);
    } catch (e) {
      debugPrint('Scan Error: $e');
    } finally {
      if (mounted) {
        setState(() => _isScanning = false);
      }
    }
  }

  static Future<DateTime?> _getVideoMediaDate(File file) async {
    RandomAccessFile? raf;
    try {
      raf = await file.open(mode: FileMode.read);
      final length = await raf.length();
      int offset = 0;

      while (offset < length) {
        raf.setPositionSync(offset);
        final header = raf.readSync(8);
        if (header.length < 8) break;

        int size = (header[0] << 24) | (header[1] << 16) | (header[2] << 8) | header[3];
        final type = String.fromCharCodes(header.sublist(4, 8));

        if (size == 1) {
          final extSize = raf.readSync(8);
          int upper = (extSize[0] << 24) | (extSize[1] << 16) | (extSize[2] << 8) | extSize[3];
          int lower = (extSize[4] << 24) | (extSize[5] << 16) | (extSize[6] << 8) | extSize[7];
          size = (upper * 4294967296) + lower;
          if (type != 'moov' && type != 'mvhd') {
            offset += size;
            continue;
          }
        } else if (size < 8) {
          break;
        }

        if (type == 'moov') {
          offset += (size == 1) ? 16 : 8; 
        } else if (type == 'mvhd') {
          final mvhdData = raf.readSync(32);
          final version = mvhdData[0];
          int creationTime = 0;
          
          if (version == 0) {
            creationTime = (mvhdData[4] << 24) | (mvhdData[5] << 16) | (mvhdData[6] << 8) | mvhdData[7];
          } else if (version == 1) {
            int upper = (mvhdData[4] << 24) | (mvhdData[5] << 16) | (mvhdData[6] << 8) | mvhdData[7];
            int lower = (mvhdData[8] << 24) | (mvhdData[9] << 16) | (mvhdData[10] << 8) | mvhdData[11];
            creationTime = (upper * 4294967296) + lower;
          }

          if (creationTime > 0) {
            final unixEpoch = creationTime - 2082844800;
            if (unixEpoch > 0) {
              return DateTime.fromMillisecondsSinceEpoch(unixEpoch * 1000);
            }
          }
          break;
        } else {
          offset += size; 
        }
      }
    } catch (_) {
    } finally {
      raf?.closeSync();
    }
    return null;
  }

  static Future<void> _isolateScanTask(List<dynamic> args) async {
    String targetPath = args[0];
    SendPort sendPort = args[1];

    try {
      final dir = Directory(targetPath);
      if (!dir.existsSync()) {
        sendPort.send(null);
        return;
      }

      final stream = dir.list(recursive: true, followLinks: false);
      await for (final entity in stream) {
        if (entity is File) {
          final path = entity.path.toLowerCase();
          MediaType? type;
          
          if (path.endsWith('.jpg') || path.endsWith('.jpeg') || path.endsWith('.png') || path.endsWith('.heic') || path.endsWith('.webp')) {
            type = MediaType.image;
          } else if (path.endsWith('.mp4') || path.endsWith('.mov') || path.endsWith('.avi') || path.endsWith('.mkv')) {
            type = MediaType.video;
          }

          if (type != null) {
            final stat = await entity.stat();
            DateTime fileDate = stat.changed; 

            if (type == MediaType.image) {
              try {
                final fileStream = entity.openRead(0, 65536);
                final bytes = <int>[];
                await for (final chunk in fileStream) {
                  bytes.addAll(chunk);
                }
                final tags = await readExifFromBytes(bytes);
                if (tags.containsKey('EXIF DateTimeOriginal')) {
                  String ds = tags['EXIF DateTimeOriginal']!.printable;
                  fileDate = DateFormat("yyyy:MM:dd HH:mm:ss").parse(ds);
                }
              } catch (_) {}
            } else if (type == MediaType.video) {
              final mediaDate = await _getVideoMediaDate(entity);
              if (mediaDate != null) {
                fileDate = mediaDate;
              }
            }
            sendPort.send(MediaItem(entity, fileDate, type, stat.size));
          }
        }
      }
    } catch (_) {} finally {
      sendPort.send(null);
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
    if (mounted) {
      setState(() => _groupedItems = grouped);
    }
  }

  Future<void> _downloadSelected() async {

  if (_downloadPath == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('メニューから「ダウンロード先の設定」を行ってください')),
    );
    return;
  }

  final total = _selectedItems.length;
  int completed = 0;

  final startTime = DateTime.now();

  // 最初にSnackBarを1回だけ作る
  _downloadStatus.value = "ダウンロード開始";

_downloadSnackBar = SnackBar(
  duration: const Duration(days: 1),
  content: ValueListenableBuilder<String>(
    valueListenable: _downloadStatus,
    builder: (context, text, _) {
      return Text(text);
    },
  ),
);

  ScaffoldMessenger.of(context).showSnackBar(_downloadSnackBar!);

  for (var item in _selectedItems) {

    try {

      final fileName = item.file.path.split(Platform.pathSeparator).last;
      final destPath = '$_downloadPath${Platform.pathSeparator}$fileName';

      await item.file.copy(destPath);

      completed++;

      final elapsed = DateTime.now().difference(startTime).inSeconds;
      final avg = elapsed / completed;
      final remaining = ((total - completed) * avg).round();

      if (!mounted) return;

     _downloadStatus.value =
    '$total件中 $completed件ダウンロード中\n残り約${remaining}秒';

setState(() {});
    } catch (e) {
      debugPrint('Copy error: $e');
    }
  }

  if (!mounted) return;

  _downloadStatus.value = '$total件ダウンロード完了';
  await Future.delayed(const Duration(seconds: 2));
ScaffoldMessenger.of(context).hideCurrentSnackBar();

await Future.delayed(const Duration(seconds: 2));

ScaffoldMessenger.of(context).hideCurrentSnackBar();

  _clearSelection();
}

  Future<void> _deleteSelected() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('削除の確認'),
        content: Text('${_selectedItems.length}件のファイルを削除しますか？\n（ディスクから完全に削除されます）'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('削除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );

    if (confirm != true) {
      return;
    }

    for (var item in _selectedItems) {
      try {
        if (item.file.existsSync()) {
          await item.file.delete();
        }
      } catch (e) {
        debugPrint('Delete error: $e');
      }
    }
    _clearSelection();
    _scanPhotosBackground(); 
  }

  void _handleItemTap(MediaItem item) {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final isCtrl = keys.contains(LogicalKeyboardKey.controlLeft) || keys.contains(LogicalKeyboardKey.controlRight);
    final isShift = keys.contains(LogicalKeyboardKey.shiftLeft) || keys.contains(LogicalKeyboardKey.shiftRight);

    setState(() {
      if (isShift && _pivotItem != null) {
        int start = _flatItems.indexOf(_pivotItem!);
        int end = _flatItems.indexOf(item);
        if (start > end) { 
          int tmp = start; 
          start = end; 
          end = tmp; 
        }
        if (!isCtrl) {
          _selectedItems.clear();
        }
        for (int i = start; i <= end; i++) {
          _selectedItems.add(_flatItems[i]);
        }
      } else if (isCtrl || _selectedItems.isNotEmpty) {
        if (_selectedItems.contains(item)) {
          _selectedItems.remove(item);
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
          onDelete: () => _scanPhotosBackground(),
        )));
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

    return KeyboardListener(
      focusNode: _gridFocusNode..requestFocus(),
      onKeyEvent: (event) {
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
          if (isSelectionMode) {
            _clearSelection();
          }
        }
      },
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 50,
          title: Text(isSelectionMode ? '${_selectedItems.length}件選択中' : 'マイフォト', style: const TextStyle(fontSize: 16)),
          actions: [
            if (_isScanning) const Center(child: Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))),
            if (isSelectionMode) ...[
              IconButton(icon: const Icon(Icons.download, color: Colors.blue), onPressed: _downloadSelected),
              IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: _deleteSelected),
              IconButton(icon: const Icon(Icons.close), onPressed: _clearSelection),
            ] else ...[
              IconButton(icon: const Icon(Icons.grid_view), onPressed: _toggleColumns),
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
                : CustomScrollView(
                    slivers: _groupedItems.entries.expand((entry) {
                      final dateKey = entry.key;
                      final items = entry.value;

                      return [
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                            child: Text(dateKey, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 8.0),
                          sliver: SliverGrid(
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: _columns,
                              crossAxisSpacing: 4,
                              mainAxisSpacing: 4,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                final item = items[index];
                                final isSelected = _selectedItems.contains(item);
                                return GestureDetector(
                                  onTap: () => _handleItemTap(item),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      item.type == MediaType.image 
                                        ? Image.file(item.file, fit: BoxFit.cover, cacheWidth: 300)
                                        : AsyncVideoThumbnail(videoPath: item.file.path),
                                      if (item.type == MediaType.video) const Center(child: Icon(Icons.play_circle_outline, color: Colors.white, size: 40)),
                                      if (isSelected) Container(color: Colors.blue.withValues(alpha: 0.4), child: const Center(child: Icon(Icons.check_circle, color: Colors.white, size: 40))),
                                      Positioned(
                                        top: 4, left: 4,
                                        child: GestureDetector(
                                          onTap: () {
                                            setState(() {
                                              if (isSelected) {
                                                _selectedItems.remove(item);
                                              } else {
                                                _selectedItems.add(item);
                                              }
                                              _pivotItem = item;
                                            });
                                          },
                                          child: Icon(isSelected ? Icons.check_circle : Icons.circle_outlined, color: isSelected ? Colors.blue : Colors.white70),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                              childCount: items.length,
                            ),
                          ),
                        ),
                      ];
                    }).toList(),
                  ),
            ),
          ],
        ),
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
        if (mounted) {
          setState(() => _thumbPath = destFile);
        }
        return;
      }
      final success = await _plugin.getVideoThumbnail(
        srcFile: widget.videoPath, destFile: destFile, width: 300, height: 300, format: 'jpeg', quality: 60, keepAspectRatio: true,
      );
      if (success && mounted) {
        setState(() => _thumbPath = destFile);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_thumbPath == null) {
      return Container(color: Colors.black12);
    }
    return Image.file(File(_thumbPath!), fit: BoxFit.cover);
  }
}

// ============================================
// 詳細ビュー
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

  late FocusNode _focusNode;
  
  Player? _player;
  VideoController? _videoController;

  
  
  bool _showInfo = false;
  bool _isFullscreenUI = false; 
  bool _isMuted = false;
  bool _isVideoFocused = false;

  int _rotationQuarterTurns = 0;

  double _currentVolume = 100.0;
  bool _showVolumeOverlay = false;
  Timer? _volumeOverlayTimer;

  Map<String, IfdTag> _currentExif = {};

  @override
  void initState() {
    super.initState();

    _focusNode = FocusNode();      // ←追加
    _focusNode.requestFocus();     // ←追加

    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
    _loadInfoState();
    _initMedia(_currentIndex);
  }

  Future<void> _loadInfoState() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _showInfo = prefs.getBool('showInfoPane') ?? false);
  }

  Future<void> _toggleInfo() async {
    setState(() => _showInfo = !_showInfo);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('showInfoPane', _showInfo);
  }

  Future<void> _initMedia(int index) async {
    _disposePlayer();
    setState(() {
      _isVideoFocused = false;
      _rotationQuarterTurns = 0; 
    });
    
    final item = widget.items[index];

    if (item.type == MediaType.image) {
      try {
        final bytes = await item.file.readAsBytes();
        final tags = await readExifFromBytes(bytes);
        if (mounted) {
          setState(() => _currentExif = tags);
        }
      } catch (_) {
        if (mounted) {
          setState(() => _currentExif = {});
        }
      }
    } else {
      if (mounted) {
        setState(() => _currentExif = {});
      }
      _player = Player();
      _videoController = VideoController(_player!);
      try {
        await _player!.open(Media(item.file.path));
        _player!.setPlaylistMode(PlaylistMode.loop);
        _player!.setVolume(_currentVolume);
        if (_isMuted) {
          _player!.setVolume(0);
        }
        if (mounted && _currentIndex == index) {
          setState(() {});
        }
      } catch (_) {}
    }
  }

  void _disposePlayer() {
    _player?.dispose();
    _player = null;
    _videoController = null;
  }

  Future<void> _toggleWindowFullscreen() async {

  bool isFull = await windowManager.isFullScreen();

  await windowManager.setFullScreen(!isFull);

  if (mounted) {
    setState(() {
      _isFullscreenUI = !isFull;
    });
  }

}

  Future<void> _downloadCurrent() async {
    if (widget.downloadPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('ダウンロード先が設定されていません')));
      return;
    }
    final item = widget.items[_currentIndex];
    final fileName = item.file.path.split(Platform.pathSeparator).last;
    final destPath = '${widget.downloadPath}${Platform.pathSeparator}$fileName';
    try {
      await item.file.copy(destPath);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('保存しました')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存に失敗しました: $e')));
    }
  }

  Future<void> _deleteCurrent() async {
    final item = widget.items[_currentIndex];
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('削除の確認'),
        content: const Text('このファイルを削除しますか？\n（ディスクから完全に削除されます）'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('削除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );

    if (confirm == true) {
      try {
        if (item.file.existsSync()) {
          await item.file.delete();
        }
        widget.onDelete(); 
        if (!mounted) return;
        Navigator.pop(context); 
      } catch (e) {
        debugPrint('Delete error: $e');
      }
    }
  }

  void _setVolume(double increment) {
    if (_player == null) {
      return;
    }
    setState(() {
      _currentVolume = (_currentVolume + increment).clamp(0.0, 100.0);
      _player!.setVolume(_currentVolume);
      _isMuted = _currentVolume <= 0;
      _showVolumeOverlay = true;
    });
    
    _volumeOverlayTimer?.cancel();
    _volumeOverlayTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() => _showVolumeOverlay = false);
      }
    });
  }

  void _handleKey(KeyEvent event) async {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return;
    }
    
    final key = event.logicalKey;
    final currentItem = widget.items[_currentIndex];

    if (event is KeyDownEvent && key == LogicalKeyboardKey.escape) {
      bool isWindowFull = await windowManager.isFullScreen();
      if (isWindowFull) {
  await windowManager.setFullScreen(false);

  if (mounted) {
    setState(() {
      _isFullscreenUI = false;
    });
  }

} else {
        Navigator.pop(context);
      }
    } else if (event is KeyDownEvent && key == LogicalKeyboardKey.keyF) {

  bool isFull = await windowManager.isFullScreen();
  await windowManager.setFullScreen(!isFull);

  if (mounted) {
    setState(() {
      _isFullscreenUI = !isFull;
    });
  }

} else if (event is KeyDownEvent && key == LogicalKeyboardKey.keyM && _player != null) {
  setState(() {
    _isMuted = !_isMuted;
    _player!.setVolume(_isMuted ? 0 : _currentVolume);
    _showVolumeOverlay = true;
  });

  _volumeOverlayTimer?.cancel();
  _volumeOverlayTimer = Timer(const Duration(seconds: 2), () {
    if (mounted) {
      setState(() => _showVolumeOverlay = false);
    }
  });
    } else if (key == LogicalKeyboardKey.arrowUp && _player != null) {
      _setVolume(5.0);
    } else if (key == LogicalKeyboardKey.arrowDown && _player != null) {
      _setVolume(-5.0);
    } else if (event is KeyDownEvent && (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK) && _player != null) {
      if (_player!.state.playing) {
        _player!.pause();
      } else {
        _player!.play();
      }
    } else if (event is KeyDownEvent && key == LogicalKeyboardKey.arrowRight) {
      if (currentItem.type == MediaType.video && _isVideoFocused && _player != null) {
        _player!.seek(_player!.state.position + const Duration(seconds: 5));
      } else if (_currentIndex < widget.items.length - 1) {
        _pageController.nextPage(duration: const Duration(milliseconds: 200), curve: Curves.easeInOut);
      }
    } else if (event is KeyDownEvent && key == LogicalKeyboardKey.arrowLeft) {
      if (currentItem.type == MediaType.video && _isVideoFocused && _player != null) {
        // 現在位置から5秒引いた時間を計算
        final targetPosition = _player!.state.position - const Duration(seconds: 5);
        // マイナスになれば0秒、そうでなければ計算した時間をセット
        _player!.seek(targetPosition.isNegative ? Duration.zero : targetPosition);
      } else if (_currentIndex > 0) {
        _pageController.previousPage(duration: const Duration(milliseconds: 200), curve: Curves.easeInOut);
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) {
      return "0 B";
    }
    const suffixes = ["B", "KB", "MB", "GB", "TB"];
    var i = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(1)} ${suffixes[i]}';
  }

  @override
  void dispose() {
    _disposePlayer();
    _pageController.dispose();
    _focusNode.dispose();    
    _volumeOverlayTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentItem = widget.items[_currentIndex];
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return KeyboardListener(
      focusNode: _focusNode,
      onKeyEvent: _handleKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _isVideoFocused = false),
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
                                ? Listener(
                                    behavior: HitTestBehavior.deferToChild,
                                    onPointerDown: (PointerDownEvent event) {

                                          // 動画UIをクリックした場合は無視
                                          if (event.localPosition.dy > MediaQuery.of(context).size.height - 80) {
                                            return;
                                          }
                                      setState(() => _isVideoFocused = true);

                                      // 左クリックのみ
                                      if ((event.buttons & kPrimaryMouseButton) != 0 && _player != null) {

                                        // 再生/停止
                                        if (_player!.state.playing) {
                                          _player!.pause();
                                        } else {
                                          _player!.play();
                                        }

                                      }
                                    },
                                    child: MaterialDesktopVideoControlsTheme(
                                      normal: MaterialDesktopVideoControlsThemeData(
                                        bottomButtonBar: [
                                          const MaterialDesktopPlayOrPauseButton(),
                                          const MaterialDesktopVolumeButton(),
                                          const MaterialDesktopPositionIndicator(),
                                          const Spacer(),
                                          // ValueKeyを追加してキャッシュを強制クリアし、アイコンを再描画させる
                                          IconButton(
                                            key: ValueKey('fullscreen_btn_$_isFullscreenUI'),
                                            icon: Icon(
                                              _isFullscreenUI ? Icons.fullscreen_exit : Icons.fullscreen,
                                              color: Colors.white,
                                            ),
                                            onPressed: _toggleWindowFullscreen,
                                          ),
                                        ],
                                      ),
                                      fullscreen: MaterialDesktopVideoControlsThemeData(
                                        bottomButtonBar: [
                                          const MaterialDesktopPlayOrPauseButton(),
                                          const MaterialDesktopVolumeButton(),
                                          const MaterialDesktopPositionIndicator(),
                                          const Spacer(),
                                          // こちらも同様にValueKeyを設定
                                          IconButton(
                                            key: ValueKey('fullscreen_btn_$_isFullscreenUI'),
                                            icon: Icon(
                                              _isFullscreenUI ? Icons.fullscreen_exit : Icons.fullscreen,
                                              color: Colors.white,
                                            ),
                                            onPressed: _toggleWindowFullscreen,
                                          ),
                                        ]
                                      ),
                                      child: Video(controller: _videoController!),
                                    ),
                                  )
                                : const CircularProgressIndicator(),
                          );
                        } else {
                          return InteractiveViewer(
                            child: RotatedBox(
                              quarterTurns: _rotationQuarterTurns,
                              child: Image.file(widget.items[i].file, fit: BoxFit.contain, cacheWidth: 2048),
                            ),
                          );
                        }
                      },
                    ),
                  ),
                ),
                
                if (_showInfo && !_isFullscreenUI)
                  Container(
                    width: 300,
                    color: isDark ? Colors.grey[900] : Colors.white,
                    padding: const EdgeInsets.all(20),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.start,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('情報', style: TextStyle(color: isDark ? Colors.white : Colors.black, fontSize: 18, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 20),
                          
                          Text(DateFormat('yyyy年MM月dd日(E) HH:mm', 'ja_JP').format(currentItem.date), style: TextStyle(color: isDark ? Colors.white70 : Colors.black87)),
                          const Divider(height: 30),

                          if (_currentExif.containsKey('Image Make') || _currentExif.containsKey('Image Model')) ...[
                            Text('${_currentExif['Image Make']?.printable ?? ''} ${_currentExif['Image Model']?.printable ?? ''}'.trim(), 
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black)),
                            const SizedBox(height: 4),
                            Text('f/${_currentExif['EXIF FNumber']?.printable ?? '-'}  ${_currentExif['EXIF ExposureTime']?.printable ?? '-'}s  ${_currentExif['EXIF FocalLength']?.printable ?? '-'}mm  ISO${_currentExif['EXIF ISOSpeedRatings']?.printable ?? '-'}',
                              style: const TextStyle(color: Colors.grey, fontSize: 12)),
                            const Divider(height: 30),
                          ],

                          Text(currentItem.file.path.split(Platform.pathSeparator).last, 
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black)),
                          const SizedBox(height: 4),
                          Text('${_currentExif['EXIF ExifImageWidth']?.printable ?? '-'} × ${_currentExif['EXIF ExifImageLength']?.printable ?? '-'}',
                            style: const TextStyle(color: Colors.grey, fontSize: 12)),
                          const SizedBox(height: 4),
                          Text('容量: ${_formatBytes(currentItem.sizeBytes)}', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                          
                          const Divider(height: 30),
                          Text('パス:\n${currentItem.file.path}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
                          const Divider(height: 30),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            
            if (currentItem.type == MediaType.video)
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _showVolumeOverlay ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 300),
                  // 音量％の位置を画面の中心から少し上に配置 (-0.5は上端と中心の中間)
                  child: Align(
                    alignment: const Alignment(0.0, -0.5),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      decoration: BoxDecoration(
                        // 背景の透明度を30% (alpha: 0.3) に変更
                        color: Colors.black.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${_isMuted ? 0 : _currentVolume.toInt()}%',
                        style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
              ),

            if (!_isFullscreenUI)
              Positioned(
                top: 10, right: _showInfo ? 310 : 10,
                child: Row(
                  children: [
                    IconButton(icon: Icon(_showInfo ? Icons.info : Icons.info_outline, color: Colors.white, size: 28), onPressed: _toggleInfo),
                    if (currentItem.type == MediaType.image)
                      IconButton(icon: const Icon(Icons.rotate_right, color: Colors.white, size: 28), onPressed: () => setState(() => _rotationQuarterTurns++)),
                    IconButton(icon: const Icon(Icons.download, color: Colors.white, size: 28), onPressed: _downloadCurrent),
                    IconButton(icon: const Icon(Icons.delete_outline, color: Colors.white, size: 28), onPressed: _deleteCurrent),
                  ],
                ),
              ),
              
            if (!_isFullscreenUI)
              Positioned(top: 10, left: 10, child: IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white, size: 28), onPressed: () => Navigator.pop(context))),
          ],
        ),
      ),
    );
  }
}