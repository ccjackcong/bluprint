import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../services/ble_service.dart';
import '../services/http_server.dart';
import '../services/api_service.dart';
import '../services/mqtt_service.dart';

/// 设置页面 — BLE 扫描/选择打印机、HTTP 服务端口配置
///
/// 2026-08-13 重构：所有「打印机相关」配置（BLE UUID / 系统 API / MQTT 参数 / MQTT 开关）
/// 从顶层平铺收纳进「已配对打印机」卡片的展开区，且每台打印机独立保存。
/// 顶层仅保留全局配置：蓝牙适配器、已配对打印机列表、扫描附近设备、HTTP 打印服务。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final BleService _ble = BleService.instance;
  final HttpPrintServer _server = HttpPrintServer.instance;
  final ApiService _api = ApiService.instance;
  final MqttPushService _mqtt = MqttPushService.instance;
  final TextEditingController _portCtrl = TextEditingController();
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;

  /// 已配对打印机列表展开状态（MAC → 是否展开）
  final Set<String> _expandedMacs = {};

  /// 每台打印机的「高级 UUID 手动配置」折叠状态
  final Set<String> _advancedMacs = {};

  /// 每台打印机独立的编辑控制器（key = MAC）。
  ///
  /// 展开卡片时用该 MAC 已保存的配置初始化控制器；保存时写回对应 MAC。
  final Map<String, TextEditingController> _svcUuidCtrls = {};
  final Map<String, TextEditingController> _writeUuidCtrls = {};
  final Map<String, TextEditingController> _apiUrlCtrls = {};
  final Map<String, TextEditingController> _apiDeviceIdCtrls = {};
  final Map<String, TextEditingController> _apiStoreIdCtrls = {};
  final Map<String, TextEditingController> _apiDeviceKeyCtrls = {};

  @override
  void initState() {
    super.initState();
    _portCtrl.text = _server.port.toString();
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
    for (final c in _svcUuidCtrls.values) {
      c.dispose();
    }
    for (final c in _writeUuidCtrls.values) {
      c.dispose();
    }
    for (final c in _apiUrlCtrls.values) {
      c.dispose();
    }
    for (final c in _apiDeviceIdCtrls.values) {
      c.dispose();
    }
    for (final c in _apiStoreIdCtrls.values) {
      c.dispose();
    }
    for (final c in _apiDeviceKeyCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onApiChanged() {
    if (mounted) setState(() {});
  }

  void _onBleChanged() {
    if (mounted) setState(() {});
  }

  /// 获取（或惰性创建）某台打印机的编辑控制器
  TextEditingController _ctrlFor(
    Map<String, TextEditingController> map,
    String mac,
    String initial,
  ) {
    return map.putIfAbsent(mac, () => TextEditingController(text: initial));
  }

  /// 用指定 MAC 已保存的 API 配置刷新控制器（展开卡片时调用）
  void _loadControllersForMac(String mac) {
    final apiCfg = _api.getPrinterConfig(mac);
    final bleCfg = _ble.getConfigForMac(mac);

    _ctrlFor(_svcUuidCtrls, mac, bleCfg?['service_uuid'] ?? '').text =
        bleCfg?['service_uuid'] ?? '';
    _ctrlFor(_writeUuidCtrls, mac, bleCfg?['write_char_uuid'] ?? '').text =
        bleCfg?['write_char_uuid'] ?? '';
    _ctrlFor(_apiUrlCtrls, mac, apiCfg?['base_url'] ?? _api.baseUrl).text =
        apiCfg?['base_url'] ?? _api.baseUrl;
    _ctrlFor(_apiDeviceIdCtrls, mac, apiCfg?['device_id'] ?? _api.deviceId).text =
        apiCfg?['device_id'] ?? _api.deviceId;
    _ctrlFor(_apiStoreIdCtrls, mac, apiCfg?['store_id'] ?? _api.storeId).text =
        apiCfg?['store_id'] ?? _api.storeId;
    _ctrlFor(_apiDeviceKeyCtrls, mac, apiCfg?['device_key'] ?? _api.deviceKey).text =
        apiCfg?['device_key'] ?? _api.deviceKey;
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

          // ── 已配对打印机列表（含全部打印机相关配置）──
          _buildSectionTitle('已配对打印机'),
          ..._buildPairedPrinterList(),
          const SizedBox(height: 16),

          // ── 扫描设备 ──
          _buildSectionTitle('扫描附近设备'),
          _buildScanSection(),
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

  /// 已配对打印机列表（每台一个可展开卡片，展开区收纳全部打印机相关配置）
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
                onTap: () {
                  setState(() {
                    if (isExpanded) {
                      _expandedMacs.remove(mac);
                    } else {
                      _expandedMacs.add(mac);
                      _loadControllersForMac(mac); // 展开时加载该打印机配置到编辑器
                    }
                  });
                },
                borderRadius: BorderRadius.vertical(top: Radius.circular(isExpanded ? 0 : 8)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: isConnected ? Colors.green : Colors.grey,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
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
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Chip(
                            label: Text(brandLabel, style: const TextStyle(fontSize: 10)),
                            backgroundColor: brandColor.withValues(alpha: 0.15),
                            side: BorderSide(color: brandColor.withValues(alpha: 0.3)),
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                          ),
                          const SizedBox(height: 2),
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

              // 展开区域：BLE 信息 + API 配置 + MQTT + 操作
              if (isExpanded) _buildExpandedPrinter(mac, cfg, isCurrent, isConnected),
            ],
          ),
        );
      }),
    ];
  }

  /// 卡片展开区 — 收纳该打印机的全部相关配置
  Widget _buildExpandedPrinter(
    String mac,
    Map<String, dynamic> cfg,
    bool isCurrent,
    bool isConnected,
  ) {
    final svcUuid = cfg['service_uuid'] as String? ?? '';
    final writeUuid = cfg['write_char_uuid'] as String? ?? '';

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── BLE 通道信息（只读，展示有意义的通道 key 而非原始 UUID）──
          _buildSubTitle('BLE 通道'),
          _buildInfoRow('通道', _channelKeyLabel(svcUuid, writeUuid)),
          _buildInfoRow('Service UUID', svcUuid.isEmpty ? '(自动发现)' : svcUuid),
          _buildInfoRow('Write Char', writeUuid.isEmpty ? '(自动发现)' : writeUuid),

          const Divider(height: 20),

          // ── 系统 API 配置 ──
          _buildSubTitle('系统 API 配置'),
          _buildTextField(_ctrlFor(_apiUrlCtrls, mac, ''), '服务器地址', '如 https://sanjoy.example.com'),
          const SizedBox(height: 10),
          _buildTextField(_ctrlFor(_apiDeviceIdCtrls, mac, ''), '设备 ID', '在系统 IoT 管理中注册的 BLE 打印机 ID'),
          const SizedBox(height: 10),
          _buildTextField(_ctrlFor(_apiStoreIdCtrls, mac, ''), '门店 ID', '用于拉取该门店的待打印任务'),
          const SizedBox(height: 10),
          _buildTextField(_ctrlFor(_apiDeviceKeyCtrls, mac, ''), '设备密钥', '在系统 IoT 管理中生成的 24 位密钥'),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.circle, size: 10, color: _isThisMacConfigured(mac) ? Colors.green : Colors.grey),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _isThisMacConfigured(mac) ? '已配置' : '未配置',
                  style: Theme.of(context).textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: () async {
                  final url = _ctrlFor(_apiUrlCtrls, mac, '').text.trim();
                  final devId = _ctrlFor(_apiDeviceIdCtrls, mac, '').text.trim();
                  final storeId = _ctrlFor(_apiStoreIdCtrls, mac, '').text.trim();
                  final key = _ctrlFor(_apiDeviceKeyCtrls, mac, '').text.trim();
                  await _api.saveConfig(
                    baseUrl: url,
                    deviceId: devId,
                    storeId: storeId,
                    deviceKey: key,
                    mac: mac,
                  );
                  final ok = await _api.bindDevice();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(ok
                            ? '✅ 配置已保存，设备已绑定'
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

          const Divider(height: 20),

          // ── MQTT 参数（一键从服务器拉取 + 只读展示）──
          _buildSubTitle('MQTT 推送参数'),
          Row(
            children: [
              Icon(
                Icons.circle,
                size: 10,
                color: _mqtt.isConfigured ? Colors.green : Colors.grey,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _mqtt.isConfigured ? 'MQTT 参数已就绪' : '尚未拉取 MQTT 参数',
                  style: Theme.of(context).textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: () async {
                  final key = _ctrlFor(_apiDeviceKeyCtrls, mac, '').text.trim();
                  if (key.isEmpty) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('请先在上方填写设备密钥'), duration: Duration(seconds: 2)),
                      );
                    }
                    return;
                  }
                  // 确保 baseUrl 已写入当前会话（拉取需要）
                  final url = _ctrlFor(_apiUrlCtrls, mac, '').text.trim();
                  if (url.isNotEmpty) {
                    await _api.saveConfig(
                      baseUrl: url,
                      deviceId: _ctrlFor(_apiDeviceIdCtrls, mac, '').text.trim(),
                      storeId: _ctrlFor(_apiStoreIdCtrls, mac, '').text.trim(),
                      deviceKey: key,
                      mac: mac,
                    );
                  }
                  final ok = await _api.fetchBleConfig(key, mac: mac);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(ok ? '✅ MQTT 参数已从服务器加载' : '❌ 拉取失败: ${_api.lastError ?? "未知"}'),
                        duration: const Duration(seconds: 2),
                        backgroundColor: ok ? Colors.green : Colors.red,
                      ),
                    );
                    setState(() {});
                  }
                },
                child: const Text('从服务器拉取'),
              ),
            ],
          ),
          if (_mqtt.isConfigured) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.teal.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.teal.shade100),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildMqttInfoRow('服务器', _mqtt.brokerHost),
                  _buildMqttInfoRow('端口', _mqtt.brokerPort.toString()),
                  _buildMqttInfoRow('用户名', _mqtt.username),
                  _buildMqttInfoRow('订阅主题', _mqtt.subscribeTopic),
                ],
              ),
            ),
          ],

          // ── MQTT 实时推送开关（每台独立）──
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('启用 MQTT 实时推送', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              _mqtt.isConnected
                  ? '已连接 · 上次通知: ${_mqtt.lastNotification != null ? _formatTime(_mqtt.lastNotification!) : '暂无'}'
                  : _api.mqttEnabled
                      ? '正在连接...'
                      : '关闭后仅手动拉取打印',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            value: _api.mqttEnabled,
            onChanged: (v) => _api.setMqttEnabled(v, mac: mac),
            activeColor: Colors.teal,
          ),

          const Divider(height: 20),

          // ── 高级：手动 UUID（默认折叠）──
          _buildAdvancedUuid(mac),

          const SizedBox(height: 4),

          // ── 操作按钮行 ──
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (!isConnected)
                FilledButton.tonal(
                  onPressed: () async {
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
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.bluetooth_connected, size: 14),
                      SizedBox(width: 6),
                      Text('连接', style: TextStyle(fontSize: 12)),
                    ],
                  ),
                )
              else
                OutlinedButton.icon(
                  onPressed: () async { await _ble.disconnect(); setState(() {}); },
                  icon: const Icon(Icons.bluetooth_disabled, size: 14),
                  label: const Text('断开', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                ),

              if (!isCurrent)
                FilledButton.tonal(
                  onPressed: () async {
                    await _ble.savePrinterConfig(deviceId: mac);
                    setState(() {});
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已切换为当前打印机'), duration: Duration(seconds: 1)),
                      );
                    }
                  },
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.star_border, size: 14),
                      SizedBox(width: 6),
                      Text('设为当前', style: TextStyle(fontSize: 12)),
                    ],
                  ),
                ),

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
    );
  }

  /// 高级：手动 UUID 折叠区
  Widget _buildAdvancedUuid(String mac) {
    final expanded = _advancedMacs.contains(mac);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() {
            if (expanded) {
              _advancedMacs.remove(mac);
            } else {
              _advancedMacs.add(mac);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(Icons.tune, size: 16, color: Colors.grey[600]),
                const SizedBox(width: 4),
                Text(
                  '高级：手动 UUID 配置',
                  style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                ),
                const Spacer(),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: Colors.grey,
                ),
              ],
            ),
          ),
        ),
        if (expanded) ...[
          _buildTextField(_ctrlFor(_svcUuidCtrls, mac, ''), 'Service UUID', '留空则自动发现'),
          const SizedBox(height: 10),
          _buildTextField(_ctrlFor(_writeUuidCtrls, mac, ''), 'Write Characteristic UUID', '留空则自动发现'),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonal(
              onPressed: () {
                _ble.savePrinterConfig(
                  deviceId: mac,
                  serviceUuid: _ctrlFor(_svcUuidCtrls, mac, '').text.trim(),
                  writeCharUuid: _ctrlFor(_writeUuidCtrls, mac, '').text.trim(),
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
      ],
    );
  }

  /// 该 MAC 是否已配置（有 URL + 设备ID + 密钥）
  bool _isThisMacConfigured(String mac) {
    final cfg = _api.getPrinterConfig(mac);
    if (cfg == null) return false;
    final url = cfg['base_url'] ?? '';
    final dev = cfg['device_id'] ?? '';
    final key = cfg['device_key'] ?? '';
    return url.isNotEmpty && dev.isNotEmpty && key.isNotEmpty;
  }

  /// 将原始 Service/Write UUID 映射为有意义的通道名（key 而非 UUID 字符串）
  String _channelKeyLabel(String svcUuid, String writeUuid) {
    final svc = svcUuid.toLowerCase();
    final wr = writeUuid.toLowerCase();
    if (svc.contains('fff0') || wr.startsWith('0000fff2') || wr.contains('49535343-6daa')) {
      return '佳博 FFF2 (WNR)';
    }
    if (svc.contains('49535343')) {
      return 'NUS 通道';
    }
    if (svc.contains('e7810a71') || svc.contains('bef8d6c9')) {
      return '精臣 B3S';
    }
    if (svcUuid.isEmpty) return '自动发现';
    return '自定义';
  }

  Widget _buildSubTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
      ),
    );
  }

  Widget _buildTextField(TextEditingController ctrl, String label, String helper) {
    return TextField(
      controller: ctrl,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
        helperText: helper,
      ),
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
    );
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

  Widget _buildMqttInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 72, child: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[700]))),
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
                        await _ble.startScan();
                        await Future.delayed(const Duration(seconds: 10));
                        if (mounted) setState(() {});
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
        if (_ble.scanResults.isEmpty && !_ble.isScanning)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              '点击"扫描设备"查找附近的 BLE 打印机',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
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
                    if (mounted) {
                      if (_server.isRunning) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('服务已启动: http://127.0.0.1:$port'), duration: const Duration(seconds: 2)),
                        );
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('启动失败: ${_server.lastError}'), backgroundColor: Colors.red),
                        );
                      }
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
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                    child: const Text('停止'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }
}
