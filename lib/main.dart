import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'dart:io' show Platform;

// 条件导入：在非 macOS 平台使用真实的 BLE 服务
import 'services/ble_service.dart'
    if (dart.library.macos) 'services/ble_service_mock.dart'
    if (dart.library.web) 'services/ble_service_mock.dart';

import 'services/http_server.dart';
import 'pages/print_page.dart';
import 'pages/settings_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化服务（带错误处理）
  try {
    // BLE 服务（在 macOS/Web 上会自动使用 Mock 版本）
    await BleService.instance.init();
  } catch (e) {
    // 即使 BLE 初始化失败，也继续启动应用（只在 macOS/Web 可能发生）
    debugPrint('⚠️ BLE 初始化失败: $e');
  }

  try {
    // HTTP 服务（监听 8080 端口）
    await HttpPrintServer.instance.start();
  } catch (e) {
    debugPrint('⚠️ HTTP 服务启动失败: $e');
    // 可以在 UI 中显示错误提示，但应用继续运行
  }

  runApp(const SanjoyPrintApp());
}

class SanjoyPrintApp extends StatelessWidget {
  const SanjoyPrintApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '三joy 打印中转',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFF59E0B),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFF59E0B),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;
  late final BleService _ble;

  final List<Widget> _pages = const [
    PrintPage(),
    SettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
    _ble = BleService.instance;
    // 如果 BLE 服务支持添加监听器（Mock 版本也应实现）
    if (_ble is ChangeNotifier) {
      (_ble as ChangeNotifier).addListener(_onBleStateChanged);
    }
  }

  @override
  void dispose() {
    if (_ble is ChangeNotifier) {
      (_ble as ChangeNotifier).removeListener(_onBleStateChanged);
    }
    super.dispose();
  }

  void _onBleStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.print_outlined),
            selectedIcon: const Icon(Icons.print),
            label: '打印',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: _ble.state == BleState.connected,
              child: const Icon(Icons.settings_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: _ble.state == BleState.connected,
              child: const Icon(Icons.settings),
            ),
            label: '设置',
          ),
        ],
      ),
    );
  }
}

// ---------- 模拟 BLE 状态枚举（与真实保持一致） ----------
// 如果你的 BleService 已定义 BleState，此处可省略
enum BleState { disconnected, connecting, connected, disconnecting }
