import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'dart:io';

import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:math';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:exif/exif.dart';
import 'package:window_manager/window_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'dart:convert'; // JSON解析用に追加
import 'package:http/http.dart' as http; // API通信用に追加

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  
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
  runApp(const MediaViewer());
}

class MediaViewer extends StatefulWidget {
  const MediaViewer({super.key});
  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer> {
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
  final String path;
  final DateTime date;
  final MediaType type;
  final int sizeBytes;
  final String thumbnailUrl;
  final int orientation; // EXIFの回転情報（quarterTurns）

  MediaItem({
    required this.path,
    required this.date,
    required this.type,
    required this.sizeBytes,
    required this.thumbnailUrl,
    this.orientation = 0,
  });

  factory MediaItem.fromJson(Map<String, dynamic> json) {
    return MediaItem(
      path: json['path'],
      date: DateTime.fromMillisecondsSinceEpoch(json['date_millis']),
      type: json['type'] == 'image' ? MediaType.image : MediaType.video,
      sizeBytes: json['size_bytes'],
      thumbnailUrl: json['thumbnail_url'],
      orientation: json['orientation'] ?? 0,
    );
  }
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
  final Set<String> _knownPaths = {}; // DBから読み込んだパスを記憶する変数

  SnackBar? _downloadSnackBar;
final ValueNotifier<String> _downloadStatus = ValueNotifier("");
  final Set<MediaItem> _selectedItems = {};
  MediaItem? _pivotItem;
  
  final bool _isScanning = false;
  int _columns = 8;
  String? _targetPath;
  String? _downloadPath;
  
  // サーバー設定
  String _serverHost = 'localhost';
  int _serverPort = 8000;
  
  final FocusNode _gridFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _loadServerSettings();
    _loadSavedPaths();
    
    // デバッグ: アプリ起動時にAPIをテスト
    debugPrint('🚀 PhotoGalleryPage 起動 - APIテストを実行します...');
    _testAPI();
  }

  Future<void> _testAPI() async {
    try {
      final response = await http.get(Uri.parse(_buildServerUrl('/api/media')));
      debugPrint('📡 APIテスト結果: ステータス ${response.statusCode}');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        debugPrint('✅ APIレスポンス: ${(data as List).length} 件取得');
      }
    } catch (e) {
      debugPrint('❌ APIテストエラー: $e');
    }
  }

  String _buildServerUrl(String path) {
    return 'http://$_serverHost:$_serverPort$path';
  }

  Future<void> _loadServerSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _serverHost = prefs.getString('server_host') ?? 'localhost';
      _serverPort = prefs.getInt('server_port') ?? 8000;
    });
  }

  Future<void> _saveServerSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_host', _serverHost);
    await prefs.setInt('server_port', _serverPort);
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
    
    // APIサーバーから全データを一括で取得する！
    // サーバー側で最新情報を返すため、クライアント側でのバックグラウンドスキャンは廃止
    await _fetchMediaFromAPI();
  }
// サーバーからデータを取得する関数に書き換え
  Future<void> _fetchMediaFromAPI() async {
    try {
      // サーバーのAPIを叩く
      String apiUrl = _buildServerUrl('/api/media');
      
      // フォルダが指定されている場合、パラメータを付ける
      if (_targetPath != null && _targetPath!.isNotEmpty) {
        final uri = Uri.parse(apiUrl).replace(
          queryParameters: {'folder': _targetPath}
        );
        apiUrl = uri.toString();
        debugPrint('📁 フォルダ指定: $_targetPath');
      }

      final response = await http.get(Uri.parse(apiUrl));

      if (response.statusCode == 200) {
        // 文字列(JSON)をDartのリスト形式に変換
        final List<dynamic> data = jsonDecode(response.body);
        
        debugPrint('🔍 APIレスポンス: ${data.length}件取得');
        
        if (data.isEmpty) {
          debugPrint('⚠️ APIが空のデータを返しました');
          return;
        }

        List<MediaItem> loadedItems = [];
        _knownPaths.clear();

        for (var jsonItem in data) {
          // jsonデータからMediaItemインスタンスを生成
          final item = MediaItem.fromJson(jsonItem);
          loadedItems.add(item);
          _knownPaths.add(item.path.toLowerCase());
          debugPrint('📦 読み込み: ${item.path} | サムネイル: ${item.thumbnailUrl}');
        }
        
        debugPrint('✅ ${loadedItems.length}件を読み込みました');
        
        // 読み込んだデータを画面に反映
        _updateUI(loadedItems, sort: true);
      } else {
        debugPrint('❌ API通信エラー: ステータスコード ${response.statusCode}');
        debugPrint('📄 レスポンスボディ: ${response.body}');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('❌ サーバーに接続できません。後で再度実行してください。')),
          );
        }
      }
    } catch (e) {
      debugPrint('❌ API取得エラー: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❌ リモート コンピューターによりネットワーク接続が拒否されました。')),
        );
      }
    }
  }
// スキャン＆リフレッシュを一括処理
  Future<void> _scanAndRefresh(String folderPath) async {
    try {
      // 1. スキャン開始のSnackBar
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🔍 フォルダをスキャンしています: $folderPath'),
            duration: const Duration(seconds: 30),
          ),
        );
      }

      // 2. フォルダをスキャン
      debugPrint('🔍 フォルダをスキャンしています: $folderPath');
      final scanResponse = await http.get(
        Uri.parse(_buildServerUrl('/api/scan')).replace(
          queryParameters: {'folder': folderPath}
        ),
      );

      if (scanResponse.statusCode == 200) {
        final scanResult = jsonDecode(scanResponse.body);
        final added = scanResult['added'] ?? 0;
        debugPrint('✅ スキャン完了: $added 件追加、${scanResult['skipped']}件スキップ');
        
        // 3. 新しいメディアが追加された場合、サムネイル生成
        if (added > 0) {
          debugPrint('🖼️ サムネイルを生成しています...');
          final thumbResponse = await http.get(Uri.parse(_buildServerUrl('/api/generate-thumbnails')));
          if (thumbResponse.statusCode == 200) {
            debugPrint('✅ サムネイル生成完了');
            await Future.delayed(const Duration(seconds: 1));
          }
        }
      }
      
      // 4. 最後にデータを再読み込み
      await _fetchMediaFromAPI();

      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
      }
      
    } catch (e) {
      debugPrint('❌ スキャン＆リフレッシュエラー: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❌ リモート コンピューターによりネットワーク接続が拒否されました。')),
        );
      }
      // エラーが発生しても、とにかくデータを読み込むようにする
      await _fetchMediaFromAPI();
    }
  }
// フォルダをスキャンしてサーバーのDBに登録する
  Future<void> _showServerSettings() async {
    String tempHost = _serverHost;
    int tempPort = _serverPort;
    
    // async gapの前にNavigatorとScaffoldMessengerを取得
    final navigator = Navigator.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('サーバー設定'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                decoration: const InputDecoration(labelText: 'ホスト名/IP'),
                controller: TextEditingController(text: tempHost),
                onChanged: (value) => tempHost = value,
              ),
              const SizedBox(height: 16),
              TextField(
                decoration: const InputDecoration(labelText: 'ポート'),
                controller: TextEditingController(text: tempPort.toString()),
                keyboardType: TextInputType.number,
                onChanged: (value) {
                  if (value.isNotEmpty) {
                    tempPort = int.tryParse(value) ?? 8000;
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル'),
            ),
            ElevatedButton(
              onPressed: () async {
                setState(() {
                  _serverHost = tempHost;
                  _serverPort = tempPort;
                });
                await _saveServerSettings();
                if (!mounted) return;
                navigator.pop();
                await _fetchMediaFromAPI();
                if (!mounted) return;
                scaffoldMessenger.showSnackBar(
                  const SnackBar(content: Text('✅ 設定を保存しました')),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

// フォルダをスキャンしてサーバーのDBに登録する
  Future<void> _pickPath(bool isSource) async {
    String? selected = await FilePicker.platform.getDirectoryPath();
    if (selected != null) {
      final prefs = await SharedPreferences.getInstance();
      if (isSource) {
        await prefs.setString('target_path', selected);
        
        setState(() {
          _targetPath = selected;
          _flatItems = [];
          _groupedItems = {};
        });
        
        // スキャン＆リフレッシュを実行
        await _scanAndRefresh(selected);
        
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

      final fileName = item.path.split(Platform.pathSeparator).last;
      final destPath = '$_downloadPath${Platform.pathSeparator}$fileName';

      await File(item.path).copy(destPath);

      completed++;

      final elapsed = DateTime.now().difference(startTime).inSeconds;
      final avg = elapsed / completed;
      final remaining = ((total - completed) * avg).round();

      if (!mounted) return;

     _downloadStatus.value =
    '$total件中 $completed件ダウンロード中\n残り約$remaining秒';

setState(() {});
    } catch (e) {
      debugPrint('Copy error: $e');
    }
  }

  if (!mounted) return;

_downloadStatus.value = '$total件ダウンロード完了';
await Future.delayed(const Duration(seconds: 2));
if (!mounted) return;
ScaffoldMessenger.of(context).hideCurrentSnackBar();

await Future.delayed(const Duration(seconds: 2));

if (!mounted) return;
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
        if (File(item.path).existsSync()) {
          await File(item.path).delete();
        }
      } catch (e) {
        debugPrint('Delete error: $e');
      }
    }
    _clearSelection();
    // リフレッシュ: APIから最新データを再取得
    await _fetchMediaFromAPI(); 
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
          onDelete: () => _fetchMediaFromAPI(),
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
          title: Text(isSelectionMode ? '${_selectedItems.length}件選択中' : 'Media Viewer', style: const TextStyle(fontSize: 16)),
          actions: [
            if (_isScanning) const Center(child: Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))),
            if (isSelectionMode) ...[
              IconButton(icon: const Icon(Icons.download, color: Colors.blue), onPressed: _downloadSelected),
              IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: _deleteSelected),
              IconButton(icon: const Icon(Icons.close), onPressed: _clearSelection),
            ] else ...[
              IconButton(icon: const Icon(Icons.grid_view), onPressed: _toggleColumns),
              IconButton(icon: const Icon(Icons.refresh), onPressed: () {
                if (_targetPath != null && _targetPath!.isNotEmpty) {
                  _scanAndRefresh(_targetPath!);
                }
              }),
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
                    PopupMenuItem(child: const Text('サーバー設定'), onTap: () => Future(() => _showServerSettings())),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('サーバー: $_serverHost:$_serverPort', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  Text('フォルダ: ${_targetPath ?? 'フォルダ未選択'}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
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
                                      Image.network(
                                        item.thumbnailUrl,
                                        fit: BoxFit.cover,
                                        loadingBuilder: (context, child, loadingProgress) {
                                          if (loadingProgress == null) return child;
                                          return Center(
                                            child: CircularProgressIndicator(
                                              value: loadingProgress.expectedTotalBytes != null
                                                  ? loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes!
                                                  : null,
                                            ),
                                          );
                                        },
                                        errorBuilder: (context, error, stackTrace) {
                                          debugPrint('❌ サムネイル読み込みエラー: ${item.path}');
                                          debugPrint('   URL: ${item.thumbnailUrl}');
                                          debugPrint('   エラー: $error');
                                          return Container(
                                            color: Colors.grey[800],
                                            child: const Center(
                                              child: Column(
                                                mainAxisAlignment: MainAxisAlignment.center,
                                                children: [
                                                  Icon(Icons.broken_image, color: Colors.grey, size: 40),
                                                  SizedBox(height: 8),
                                                  Text('読み込みエラー', style: TextStyle(color: Colors.grey, fontSize: 10)),
                                                ],
                                              ),
                                            ),
                                          );
                                        },
                                      ),
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
    final item = widget.items[index];
    setState(() {
      _isVideoFocused = false;
      _rotationQuarterTurns = item.orientation; // DBから取得済みの回転情報を即時適用
    });

    if (item.type == MediaType.image) {
      try {
        final bytes = await File(item.path).readAsBytes();
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
        await _player!.open(Media(item.path));
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
    final fileName = item.path.split(Platform.pathSeparator).last;
    final destPath = '${widget.downloadPath}${Platform.pathSeparator}$fileName';
    try {
      await File(item.path).copy(destPath);
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
        if (File(item.path).existsSync()) {
          await File(item.path).delete();
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
        if (mounted) {
          Navigator.pop(context);
        }
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
                              child: Image.file(File(widget.items[i].path), fit: BoxFit.contain, cacheWidth: 2048),
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

                          Text(currentItem.path.split(Platform.pathSeparator).last, 
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black)),
                          const SizedBox(height: 4),
                          Text('${_currentExif['EXIF ExifImageWidth']?.printable ?? '-'} × ${_currentExif['EXIF ExifImageLength']?.printable ?? '-'}',
                            style: const TextStyle(color: Colors.grey, fontSize: 12)),
                          const SizedBox(height: 4),
                          Text('容量: ${_formatBytes(currentItem.sizeBytes)}', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                          
                          const Divider(height: 30),
                          Text('パス:\n${currentItem.path}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
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