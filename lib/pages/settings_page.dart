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
  final TextEditingController _apiDeviceKeyCtrl = TextEditingController();
  bool _scanning = false;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;

  /// 已配对打印机列表展开状态
  final Set<String> _expandedMacs = {};

  @override
  void initState() {
    super.initState();
    _portCtrl.text = _server.port.toString();
    _svcUuidCtrl.text = _ble.serviceUuid;
    _writeUuidCtrl.text = _ble.writeCharUuid;
    _apiUrlCtrl.text = _api.baseUrl;
    _apiDeviceIdCtrl.text = _api.deviceId;
    _apiStoreIdCtrl.text = _api.storeId;
    _apiDeviceKeyCtrl.text = _api.deviceKey;
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
    _apiDeviceKeyCtrl.dispose();
    super.dispose();
  }

  void _onApiChanged() {
    if (mounted) {
      if (_apiUrlCtrl.text != _api.baseUrl) _apiUrlCtrl.text = _api.baseUrl;
      if (_apiDeviceIdCtrl.text != _api.deviceId) _apiDeviceIdCtrl.text = _api.deviceId;
      if (_apiStoreIdCtrl.text != _api.storeId) _apiStoreIdCtrl.text = _api.storeId;
      if (_apiDeviceKeyCtrl.text != _api.deviceKey) _apiDeviceKeyCtrl.text = _api.deviceKey;
      setState(() {});
    }
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

          // ── 已配对打印机列表 ──
          _buildSectionTitle('已配对打印机'),
          ..._buildPairedPrinterList(),
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
          _buildSectionTitle('SANJOY 系统 API 配置'),
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

  /// 已配对打印机列表（每台一个可展开卡片）
  List<Widget> _buildPairedPrinterList() {
    final macs = _ble.allPairedMacs;
    final currentMac = _ble.savedDeviceId;

    if (macs.isEmpty) {
      return [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.print_disabled, color: Colors.grey[400], size: 32),
                const SizedBox(width: 8),
                Text('尚未配对任何打印机', style: TextStyle(color: Colors.grey[600])),
              ],
            ),
          ),
        ),
      ];
    }

    return [
      ...macs.map((mac) {
        final cfg = _ble.getConfigForMac(mac);
        if (cfg == null) return const SizedBox.shrink();

        final isCurrent = mac == currentMac;
        final brandName = cfg['brand'] as String? ?? '';
        final svcUuid = cfg['service_uuid'] as String? ?? '';
        final writeUuid = cfg['write_char_uuid'] as String? ?? '';

        // 品牌颜色
        Color brandColor;
        String brandLabel;
        switch (brandName) {
          case 'niimbot':
            brandColor = Colors.deepPurple;
            brandLabel = 'NIIMBOT (精臣)';
            break;
          case 'gprinter':
            brandColor = Colors.teal;
            brandLabel = '佳博 GP';
            break;
          default:
            brandColor = Colors.grey;
            brandLabel = '通用 ESC/POS';
        }

        final isConnected = isCurrent && _ble.device != null && _ble.state != BleState.disconnected;
        final isExpanded = _expandedMacs.contains(mac);

        return Card(
          margin: const EdgeInsets.symmetric(vertical: 3),
          shape: RoundedRectangleBorder(
            side: BorderSide(
              color: isCurrent ? Colors.amber.shade300 : Colors.transparent,
              width: isCurrent ? 1.5 : 0,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              // 卡片头部（点击展开/折叠）
              InkWell(
                onTap: () => setState(() {
                  if (isExpanded) {
                    _expandedMacs.remove(mac);
                  } else {
                    _expandedMacs.add(mac);
                  }
                }),
                borderRadius: BorderRadius.vertical(top: Radius.circular(isExpanded ? 0 : 8)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      // 连接状态指示灯
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: isConnected ? Colors.green : Colors.grey,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      // 打印机信息
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.print, size: 18, color: brandColor),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    _ble.device?.platformName ?? '未知设备',
                                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'MAC: $mac',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11, color: Colors.grey[600]),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      // 右侧标签和图标
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 品牌徽章
                          Chip(
                            label: Text(brandLabel, style: const TextStyle(fontSize: 10)),
                            backgroundColor: brandColor.withOpacity(0.15),
                            side: BorderSide(color: brandColor.withOpacity(0.3)),
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                          ),
                          const SizedBox(height: 2),
                          // 当前标记 / 状态文字
                          Text(
                            isCurrent ? (isConnected ? '● 已连接' : '○ 未连接') : '',
                            style: TextStyle(
                              fontSize: 11,
                              color: isConnected ? Colors.green : Colors.grey[500],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        isExpanded ? Icons.expand_less : Icons.expand_more,
                        size: 20,
                        color: Colors.grey,
                      ),
                    ],
                  ),
                ),
              ),

              // 展开区域：详细配对信息
              if (isExpanded)
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // UUID 信息
                      _buildInfoRow('Service UUID', svcUuid.isEmpty ? '(自动发现)' : svcUuid),
                      _buildInfoRow('Write Char', writeUuid.isEmpty ? '(自动发现)' : writeUuid),

                      const Divider(height: 12),

                      // 操作按钮行
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          if (!isConnected)
                            FilledButton.tonal.icon(
                              onPressed: () async {
                                // 从扫描结果找设备或直接用 MAC 重连
                                final matched = _ble.scanResults.where(
                                  (r) => r.device.remoteId.toString() == mac,
                                ).toList();
                                if (matched.isNotEmpty) {
                                  await _ble.connect(matched.first.device);
                                  setState(() {});
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('请先扫描并连接 $mac'), duration: Duration(seconds: 2)),
                                  );
                                }
                              },
                              style: FilledButton.styleFrom(foregroundColor: Colors.blue),
                              icon: const Icon(Icons.bluetooth_connected, size: 14),
                              label: const Text('连接', style: TextStyle(fontSize: 12)),
                            )
                          else
                            OutlinedButton.icon(
                              onPressed: () async { await _ble.disconnect(); setState(() {}); },
                              icon: const Icon(Icons.bluetooth_disabled, size: 14),
                              label: const Text('断开', style: TextStyle(fontSize: 12)),
                              style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                            ),

                          // 设为当前
                          if (!isCurrent)
                            FilledButton.tonal.icon(
                              onPressed: () async {
                                await _ble.savePrinterConfig(deviceId: mac);
                                setState(() {});
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('已切换为当前打印机'), duration: Duration(seconds: 1)),
                                );
                              },
                              icon: const Icon(Icons.star_border, size: 14),
                              label: const Text('设为当前', style: TextStyle(fontSize: 12)),
                            ),

                          // 删除配对
                          OutlinedButton.icon(
                            onPressed: () async {
                              await _ble.deletePrinterConfig(mac);
                              setState(() {});
                            },
                            icon: const Icon(Icons.delete_outline, size: 14),
                            label: const Text('删除', style: TextStyle(fontSize: 12)),
                            style: OutlinedButton.styleFrom(foregroundColor: Colors.red[400]),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      }),
    ];
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 90, child: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[700]))),
          Expanded(child: SelectableText(value, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
        ],
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
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                  ),
            ),
          ),
        ..._ble.scanResults.map((r) {
          final device = r.device;
          final isSaved = device.remoteId.toString() == _ble.savedDeviceId;
          final isPaired = _ble.allPairedMacs.contains(device.remoteId.toString());
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 2),
            child: ListTile(
              dense: true,
              leading: Stack(
                alignment: Alignment.centerRight,
                children: [
                  Icon(
                    isSaved ? Icons.star : Icons.bluetooth,
                    color: isSaved ? Colors.amber : Colors.blue,
                    size: 22,
                  ),
                  if (isPaired && !isSaved)
                    Container(
                      margin: const EdgeInsets.only(left: 14, bottom: 10),
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: Colors.orange,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                    ),
                ],
              ),
              title: Text(
                device.platformName.isNotEmpty ? device.platformName : '未知设备',
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
                helperText: '打印机 GATT Service UUID（留空则自动发现）',
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
                helperText: '写入数据特征值 UUID（留空则自动发现）',
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
                    const SnackBar(content: Text('UUID 配置已保存'), duration: Duration(seconds: 1)),
                  );
                  setState(() {});
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
                        SnackBar(content: Text('服务已启动: http://127.0.0.1:$port'), duration: const Duration(seconds: 2)),
                      );
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('启动失败: ${_server.lastError}'), backgroundColor: Colors.red),
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
                Icon(Icons.circle, size: 10, color: _server.isRunning ? Colors.green : Colors.grey),
                const SizedBox(width: 6),
                Text(
                  _server.isRunning ? '运行中 — http://127.0.0.1:${_server.port}' : '未启动',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                if (_server.isRunning)
                  TextButton(
                    onPressed: () async { await _server.stop(); setState(() {}); },
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
            TextField(
              controller: _apiDeviceKeyCtrl,
              decoration: const InputDecoration(
                labelText: '设备密钥',
                border: OutlineInputBorder(),
                isDense: true,
                helperText: '在系统 IoT 管理中生成的 24 位密钥',
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.circle, size: 10, color: _api.isConfigured ? Colors.green : Colors.grey),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _api.isConfigured
                        ? (_api.autoPolling ? '已配置 · 自动轮询中 (心跳60s/拉取10s)' : '已配置 · 轮询未启动')
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
                      deviceKey: _apiDeviceKeyCtrl.text.trim(),
                    );
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
