import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../services/ble_service.dart';
import '../services/http_server.dart';
import '../services/api_service.dart';

/// 设置页面 — BLE 扫描/选择打印机、HTTP 服务端口配置
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final BleService _ble = BleService.instance;
  final HttpPrintServer _server = HttpPrintServer.instance;
  final ApiService _api = ApiService.instance;
  final TextEditingController _portCtrl = TextEditingController();
  final TextEditingController _svcUuidCtrl = TextEditingController();
  final TextEditingController _writeUuidCtrl = TextEditingController();
  final TextEditingController _apiUrlCtrl = TextEditingController();
  final TextEditingController _apiDeviceIdCtrl = TextEditingController();
  final TextEditingController _apiStoreIdCtrl = TextEditingController();
  bool _scanning = false;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;

  @override
  void initState() {
    super.initState();
    _portCtrl.text = _server.port.toString();
    _svcUuidCtrl.text = _ble.serviceUuid;
    _writeUuidCtrl.text = _ble.writeCharUuid;
    _apiUrlCtrl.text = _api.baseUrl;
    _apiDeviceIdCtrl.text = _api.deviceId;
    _apiStoreIdCtrl.text = _api.storeId;
    _ble.addListener(_onBleChanged);
    _api.addListener(_onApiChanged);

    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (mounted) {
        setState(() => _adapterState = state);
      }
    });
  }

  @override
  void dispose() {
    _ble.removeListener(_onBleChanged);
    _api.removeListener(_onApiChanged);
    _adapterSub?.cancel();
    _portCtrl.dispose();
    _svcUuidCtrl.dispose();
    _writeUuidCtrl.dispose();
    _apiUrlCtrl.dispose();
    _apiDeviceIdCtrl.dispose();
    _apiStoreIdCtrl.dispose();
    super.dispose();
  }

  void _onApiChanged() {
    if (mounted) setState(() {});
  }

  void _onBleChanged() {
    if (mounted) setState(() {});
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
          const SizedBox(height: 16),

          // ── 服务器 API 配置（BLE 打印中转） ──
          _buildSectionTitle('三joy 系统 API 配置'),
          _buildApiConfig(),
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
    final on = _adapterState == BluetoothAdapterState.on;
    return Card(
      child: ListTile(
        leading: Icon(
          on ? Icons.bluetooth : Icons.bluetooth_disabled,
          color: on ? Colors.blue : Colors.grey,
        ),
        title: Text(on ? '蓝牙已开启' : '蓝牙未开启'),
        subtitle: Text(on ? '可以扫描和连接设备' : '请在系统设置中开启蓝牙'),
        trailing: on ? const Icon(Icons.check_circle, color: Colors.green) : null,
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
            : const Text('请扫描并选择一台打印机'),
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
                onPressed: _ble.isScanning
                    ? null
                    : () async {
                        setState(() => _scanning = true);
                        await _ble.startScan();
                        // 重新读取扫描结果
                        await Future.delayed(const Duration(seconds: 10));
                        if (mounted) setState(() => _scanning = false);
                      },
                icon: _ble.isScanning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.bluetooth_searching),
                label: Text(_ble.isScanning ? '扫描中...' : '扫描设备'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // 扫描结果列表
        if (_ble.scanResults.isEmpty && !_ble.isScanning)
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

  Widget _buildApiConfig() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            TextField(
              controller: _apiUrlCtrl,
              decoration: const InputDecoration(
                labelText: '服务器地址',
                border: OutlineInputBorder(),
                isDense: true,
                helperText: '如 https://sanjoy.example.com',
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _apiDeviceIdCtrl,
              decoration: const InputDecoration(
                labelText: '设备 ID',
                border: OutlineInputBorder(),
                isDense: true,
                helperText: '在系统 IoT 管理中注册的 BLE 打印机 ID',
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _apiStoreIdCtrl,
              decoration: const InputDecoration(
                labelText: '门店 ID',
                border: OutlineInputBorder(),
                isDense: true,
                helperText: '用于拉取该门店的待打印任务',
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 10,
                  color: _api.isConfigured ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _api.isConfigured
                        ? (_api.autoPolling
                            ? '已配置 · 自动轮询中 (心跳60s/拉取10s)'
                            : '已配置 · 轮询未启动')
                        : '未配置',
                    style: Theme.of(context).textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: () async {
                    await _api.saveConfig(
                      baseUrl: _apiUrlCtrl.text.trim(),
                      deviceId: _apiDeviceIdCtrl.text.trim(),
                      storeId: _apiStoreIdCtrl.text.trim(),
                    );
                    // saveConfig 内部已调用 startAutoPoll，再手动绑定一次确认即时心跳
                    final ok = await _api.bindDevice();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(ok
                              ? '✅ 配置已保存，设备已绑定，自动轮询已启动'
                              : '⚠️ 配置已保存，但绑定失败: ${_api.lastError ?? "未知"}'),
                          duration: const Duration(seconds: 2),
                          backgroundColor: ok ? Colors.green : Colors.orange,
                        ),
                      );
                    }
                  },
                  child: const Text('保存并绑定'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
