import 'package:flutter/material.dart';
import 'services/ble_service.dart';  // 直接导入，不再条件判断
import 'services/http_server.dart';
import 'pages/print_page.dart';
import 'pages/settings_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await BleService.instance.init();
  } catch (e) {
    debugPrint('BLE 初始化失败: $e');
  }

  try {
    await HttpPrintServer.instance.start();
  } catch (e) {
    debugPrint('HTTP 服务启动失败: $e');
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
