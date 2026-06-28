// lib/pages/settings_page.dart
import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'dart:io' show Platform;
import '../services/ble_service.dart';
import '../services/http_server.dart';

/// 设置页面 — BLE 扫描/选择打印机、HTTP 服务端口配置
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final BleService _ble = BleService.instance;
  final HttpPrintServer _server = HttpPrintServer.instance;
  final TextEditingController _portCtrl = TextEditingController();
  final TextEditingController _svcUuidCtrl = TextEditingController();
  final TextEditingController _writeUuidCtrl = TextEditingController();

  // ⭐ 用 BleService 的状态替代 FlutterBluePlus 的适配器状态
  bool _isScanning = false;
  bool _bleAvailable = true; // 默认 true，macOS/Web 会设置为模拟模式

  @override
  void initState() {
    super.initState();
    _portCtrl.text = _server.port.toString();
    _svcUuidCtrl.text = _ble.serviceUuid;
    _writeUuidCtrl.text = _ble.writeCharUuid;
    _ble.addListener(_onBleChanged);

    // ⭐ 检测当前平台是否支持真实蓝牙
    _checkBleAvailability();
  }

  @override
  void dispose() {
    _ble.removeListener(_onBleChanged);
    _portCtrl.dispose();
    _svcUuidCtrl.dispose();
    _writeUuidCtrl.dispose();
    super.dispose();
  }

  void _onBleChanged() {
    if (mounted) setState(() {});
  }

  // ⭐ 检测平台是否支持真实蓝牙
  void _checkBleAvailability() {
    if (kIsWeb) {
      _bleAvailable = false;
      return;
    }
    if (Platform.isMacOS) {
      _bleAvailable = false;
      return;
    }
    // Android / iOS 支持真实蓝牙
    _bleAvailable = true;
  }

  // ⭐ 获取蓝牙适配器状态描述（从 BleService 推断）
  String get _adapterStatusText {
    if (!_bleAvailable) return '模拟模式（macOS/Web）';
    final state = _ble.state;
    switch (state) {
      case BleState.disconnected:
        return '蓝牙已开启（未连接）';
      case BleState.connecting:
        return '连接中...';
      case BleState.connected:
        return '已连接';
      case BleState.scanning:
        return '扫描中...';
      case BleState.printing:
        return '打印中...';
    }
  }

  bool get _isAdapterReady {
    if (!_bleAvailable) return true; // 模拟模式下始终可用
    // 在真实平台上，只要不是扫描或连接中，就认为适配器就绪
    return _ble.state != BleState.scanning && _ble.state != BleState.connecting;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── 蓝牙状态 ──
          _buildSectionTitle('蓝牙适配器'),
          _buildAdapterStatus(),
          const SizedBox(height: 16),

          // ── 已保存的打印机 ──
          _buildSectionTitle('已保存的打印机'),
          _buildSavedPrinter(),
          const SizedBox(height: 16),

          // ── 扫描设备 ──
          _buildSectionTitle('扫描附近设备'),
          _buildScanSection(),
          const SizedBox(height: 16),

          // ── BLE 参数配置 ──
          _buildSectionTitle('BLE 参数配置'),
          _buildUuidConfig(),
          const SizedBox(height: 16),

          // ── HTTP 端口 ──
          _buildSectionTitle('HTTP 打印服务'),
          _buildHttpConfig(),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .titleSmall
            ?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildAdapterStatus() {
    final on = _bleAvailable && _ble.state != BleState.disconnected;
    final isSimulated = !_bleAvailable;

    return Card(
      child: ListTile(
        leading: Icon(
          isSimulated
              ? Icons.bluetooth
              : (on ? Icons.bluetooth : Icons.bluetooth_disabled),
          color: isSimulated
              ? Colors.amber
              : (on ? Colors.blue : Colors.grey),
        ),
        title: Text(
          isSimulated
              ? '模拟模式（无需蓝牙）'
              : (on ? '蓝牙已就绪' : '蓝牙未连接'),
        ),
        subtitle: Text(
          isSimulated
              ? '运行在 macOS / Web，使用模拟蓝牙服务'
              : _adapterStatusText,
        ),
        trailing: isSimulated
            ? Chip(
                label: const Text('模拟', style: TextStyle(fontSize: 12)),
                backgroundColor: Colors.amber.shade100,
                padding: EdgeInsets.zero,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              )
            : (on
                ? const Icon(Icons.check_circle, color: Colors.green)
                : null),
      ),
    );
  }

  Widget _buildSavedPrinter() {
    final saved = _ble.savedDeviceId;
    return Card(
      child: ListTile(
        leading: Icon(
          saved.isNotEmpty ? Icons.print : Icons.print_disabled,
          color: saved.isNotEmpty ? Colors.amber : Colors.grey,
        ),
        title: Text(saved.isNotEmpty ? '设备 ID: $saved' : '未保存打印机'),
        subtitle: _ble.device != null
            ? Text('已连接: ${_ble.device!.platformName}')
            : Text(_bleAvailable ? '请扫描并选择一台打印机' : '模拟模式下无真实设备'),
        trailing: saved.isNotEmpty
            ? TextButton(
                onPressed: () {
                  _ble.savePrinterConfig(deviceId: '');
                  _ble.disconnect();
                  setState(() {});
                },
                child: const Text('清除'),
              )
            : null,
      ),
    );
  }

  Widget _buildScanSection() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _isScanning || !_bleAvailable
                    ? null
                    : () async {
                        setState(() => _isScanning = true);
                        await _ble.startScan();
                        // 扫描后自动刷新
                        await Future.delayed(const Duration(seconds: 10));
                        if (mounted) setState(() => _isScanning = false);
                      },
                icon: _isScanning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.bluetooth_searching),
                label: Text(
                  _isScanning
                      ? '扫描中...'
                      : (_bleAvailable
                          ? '扫描设备'
                          : '模拟模式下不可用'),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // ⭐ 扫描结果列表（在模拟模式下显示提示）
        if (!_bleAvailable)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Card(
              color: Colors.amber.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.amber.shade700),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '当前运行在模拟模式，无需扫描物理设备。\n打印功能将使用模拟蓝牙服务。',
                        style: TextStyle(
                          color: Colors.amber.shade800,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_bleAvailable && _ble.scanResults.isEmpty && !_isScanning)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              '点击"扫描设备"查找附近的 BLE 打印机',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.5),
                  ),
            ),
          ),
        ..._ble.scanResults.map((r) {
          final device = r.device;
          final isSaved = device.remoteId.toString() == _ble.savedDeviceId;
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 2),
            child: ListTile(
              dense: true,
              leading: Icon(
                isSaved ? Icons.star : Icons.bluetooth,
                color: isSaved ? Colors.amber : Colors.blue,
                size: 22,
              ),
              title: Text(
                device.platformName.isNotEmpty
                    ? device.platformName
                    : '未知设备',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              subtitle: Text(
                '${device.remoteId}  ·  RSSI: ${r.rssi}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              trailing: isSaved
                  ? const Chip(
                      label: Text('当前', style: TextStyle(fontSize: 12)),
                      backgroundColor: Colors.amber,
                      padding: EdgeInsets.zero,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    )
                  : FilledButton.tonal(
                      onPressed: () => _ble.connect(device),
                      child: const Text('连接'),
                    ),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildUuidConfig() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            TextField(
              controller: _svcUuidCtrl,
              decoration: const InputDecoration(
                labelText: 'Service UUID',
                border: OutlineInputBorder(),
                isDense: true,
                helperText: '打印机 GATT Service UUID',
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _writeUuidCtrl,
              decoration: const InputDecoration(
                labelText: 'Write Characteristic UUID',
                border: OutlineInputBorder(),
                isDense: true,
                helperText: '写入数据特征值 UUID',
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: () {
                  _ble.savePrinterConfig(
                    deviceId: _ble.savedDeviceId,
                    serviceUuid: _svcUuidCtrl.text.trim(),
                    writeCharUuid: _writeUuidCtrl.text.trim(),
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('UUID 配置已保存'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
                child: const Text('保存 UUID 配置'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHttpConfig() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _portCtrl,
                    decoration: const InputDecoration(
                      labelText: '监听端口',
                      border: OutlineInputBorder(),
                      isDense: true,
                      helperText: 'Web 端通过此端口发送打印数据',
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.tonal(
                  onPressed: () async {
                    final port = int.tryParse(_portCtrl.text.trim()) ?? 15987;
                    await _server.start(port: port);
                    setState(() {});
                    if (_server.isRunning) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('服务已启动: http://127.0.0.1:$port'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('启动失败: ${_server.lastError}'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  },
                  child: const Text('启动'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 10,
                  color: _server.isRunning ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 6),
                Text(
                  _server.isRunning
                      ? '运行中 — http://127.0.0.1:${_server.port}'
                      : '未启动',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                if (_server.isRunning)
                  TextButton(
                    onPressed: () async {
                      await _server.stop();
                      setState(() {});
                    },
                    child: const Text('停止'),
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
