import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'dart:io' show Platform;

// ⭐ 关键修改：macOS 和 Web 使用 Mock 版本
import 'services/ble_service.dart'
    if (dart.library.macos) 'services/ble_service_mock.dart'
    if (dart.library.web) 'services/ble_service_mock.dart';

import 'services/http_server.dart';
import 'pages/print_page.dart';
import 'pages/settings_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化 BLE（带错误保护）
  try {
    await BleService.instance.init();
  } catch (e) {
    debugPrint('⚠️ BLE 初始化失败（Mac/Web 可能正常）: $e');
  }

  // 启动 HTTP 服务（带错误保护）
  try {
    await HttpPrintServer.instance.start();
  } catch (e) {
    debugPrint('⚠️ HTTP 服务启动失败: $e');
  }

  runApp(const SanjoyPrintApp());
}

// ---------- 下面的代码与你原来完全一致，无需改动 ----------
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
