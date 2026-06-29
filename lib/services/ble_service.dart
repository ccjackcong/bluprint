import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/print_task.dart';

/// BLE 连接状态
enum BleState {
  disconnected,
  scanning,
  connecting,
  connected,
  printing,
}

/// BLE 打印机管理服务（单例）
class BleService extends ChangeNotifier {
  static final BleService instance = BleService._();
  BleService._();

  // ── 状态 ──
  BleState _state = BleState.disconnected;
  BleState get state => _state;

  BluetoothDevice? _device;
  BluetoothDevice? get device => _device;

  BluetoothCharacteristic? _writeChar;
  BluetoothCharacteristic? _notifyChar;

  // ── 已保存的打印机配置 ──
  String? _savedDeviceId;
  String get savedDeviceId => _savedDeviceId ?? '';

  String _serviceUuid = '0000fee7-0000-1000-8000-00805f9b34fb';
  String get serviceUuid => _serviceUuid;

  String _writeCharUuid = '0000fee2-0000-1000-8000-00805f9b34fb';
  String get writeCharUuid => _writeCharUuid;

  // ── 扫描结果 ──
  List<ScanResult> _scanResults = [];
  List<ScanResult> get scanResults => List.unmodifiable(_scanResults);
  bool _isScanning = false;
  bool get isScanning => _isScanning;

  // ── 日志 ──
  final List<_LogEntry> _log = [];
  List<_LogEntry> get log => List.unmodifiable(_log);

  // ── 连接成功回调（由 ApiService 注册，连接后自动加载该打印机的 API 配置）──
  void Function(String deviceMac)? onConnected;

  // ── 初始化 ──
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _savedDeviceId = prefs.getString('printer_device_id');
    final svc = prefs.getString('printer_service_uuid');
    if (svc != null && svc.isNotEmpty) _serviceUuid = svc;
    final wr = prefs.getString('printer_write_char_uuid');
    if (wr != null && wr.isNotEmpty) _writeCharUuid = wr;

    // 监听蓝牙适配器状态，开启后尝试自动连接
    FlutterBluePlus.adapterState.listen((BluetoothAdapterState s) {
      debugPrint('[BLE] 适配器状态: $s');
      if (s == BluetoothAdapterState.on && _savedDeviceId != null) {
        _autoConnect();
      }
    });

    // 如果蓝牙已开启，立即尝试自动连接（修复冷启动时不自动重连的问题）
    if (FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on && _savedDeviceId != null) {
      _autoConnect();
    }
  }

  // ── 保存打印机配置 ──
  Future<void> savePrinterConfig({
    required String deviceId,
    String? serviceUuid,
    String? writeCharUuid,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    _savedDeviceId = deviceId;
    await prefs.setString('printer_device_id', deviceId);
    if (serviceUuid != null) {
      _serviceUuid = serviceUuid;
      await prefs.setString('printer_service_uuid', serviceUuid);
    }
    if (writeCharUuid != null) {
      _writeCharUuid = writeCharUuid;
      await prefs.setString('printer_write_char_uuid', writeCharUuid);
    }
    _logMessage('打印机配置已保存: $deviceId');
    notifyListeners();
  }

  // ── 扫描 BLE 设备 ──
  Future<void> startScan({Duration timeout = const Duration(seconds: 10)}) async {
    if (_isScanning) return;
    _scanResults = [];
    _isScanning = true;
    _logMessage('开始扫描 BLE 设备...');
    notifyListeners();

    try {
      // Android 需要定位权限
      await FlutterBluePlus.startScan(timeout: timeout);
      FlutterBluePlus.scanResults.listen((results) {
        _scanResults = results;
        notifyListeners();
      });
    } catch (e) {
      _logMessage('扫描出错: $e');
    }

    // 超时后停止
    await Future.delayed(timeout);
    await stopScan();
  }

  Future<void> stopScan() async {
    if (!_isScanning) return;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    _isScanning = false;
    _logMessage('扫描结束，发现 ${_scanResults.length} 个设备');
    notifyListeners();
  }

  // ── 连接打印机 ──
  // 已保存/手动配置的 UUID 优先；找不到时自动扫描发现
  Future<bool> connect(BluetoothDevice device) async {
    if (_state == BleState.connecting || _state == BleState.connected) {
      await disconnect();
    }

    _device = device;
    _setState(BleState.connecting);
    _logMessage('正在连接 ${device.platformName} (${device.remoteId})...');

    try {
      await device.connect(timeout: const Duration(seconds: 15));
      _logMessage('GATT 连接成功，正在发现服务...');

      final services = await device.discoverServices();
      _writeChar = null;
      _notifyChar = null;

      // ── 第 1 步：用预设 UUID 匹配 ──
      bool foundByConfig = false;
      for (final service in services) {
        if (service.uuid.toString().toLowerCase() == _serviceUuid.toLowerCase()) {
          for (final char in service.characteristics) {
            final cu = char.uuid.toString().toLowerCase();
            if (cu == _writeCharUuid.toLowerCase()) {
              _writeChar = char;
              _logMessage('找到写入特征值 (匹配预设): ${char.uuid}');
            }
            if (char.properties.notify || char.properties.indicate) {
              _notifyChar = char;
              await char.setNotifyValue(true);
              char.lastValueStream.listen(_onNotify);
              _logMessage('找到通知特征值: ${char.uuid}');
            }
          }
          if (_writeChar != null) foundByConfig = true;
        }
      }

      // ── 第 2 步：预设没匹配到 → 自动发现 ──
      if (!foundByConfig) {
        _logMessage('预设 UUID 未匹配 ($_serviceUuid / $_writeCharUuid)，自动发现...');
        _logMessage('可用服务列表:');
        for (final s in services) {
          _logMessage('  Service: ${s.uuid}');
          for (final c in s.characteristics) {
            _logMessage('    Char: ${c.uuid} (${c.properties})');
          }
        }

        for (final service in services) {
          final uuid = service.uuid.toString().toLowerCase();
          // 跳过蓝牙标准服务 (Generic Access / Generic Attribute / Device Information)
          if (uuid.startsWith('000018') || uuid.startsWith('00002a')) continue;

          for (final char in service.characteristics) {
            if (char.properties.write || char.properties.writeWithoutResponse) {
              if (_writeChar == null) {
                _writeChar = char;
                _serviceUuid = service.uuid.toString();
                _writeCharUuid = char.uuid.toString();
                _logMessage('✨ 自动发现: Service=$_serviceUuid, Write=$_writeCharUuid');
              }
            }
            if ((char.properties.notify || char.properties.indicate) && _notifyChar == null) {
              _notifyChar = char;
              await char.setNotifyValue(true);
              char.lastValueStream.listen(_onNotify);
              _logMessage('✨ 自动发现 Notify: ${char.uuid}');
            }
          }
        }
      }

      if (_writeChar == null) {
        _logMessage('❌ 未找到任何可写入的特征值');
        await device.disconnect();
        _setState(BleState.disconnected);
        return false;
      }

      _setState(BleState.connected);
      _logMessage('✅ 打印机已连接 ✓');

      // 自动发现的 UUID 自动保存，下次直接使用
      await savePrinterConfig(
        deviceId: device.remoteId.toString(),
        serviceUuid: _serviceUuid,
        writeCharUuid: _writeCharUuid,
      );

      // 通知 API 服务加载该打印机的配置
      onConnected?.call(device.remoteId.toString());

      return true;
    } catch (e) {
      _logMessage('连接失败: $e');
      _setState(BleState.disconnected);
      try { await device.disconnect(); } catch (_) {}
      return false;
    }
  }

  // ── 断开连接 ──
  Future<void> disconnect() async {
    if (_device != null) {
      try { await _device!.disconnect(); } catch (_) {}
      _device = null;
    }
    _writeChar = null;
    _notifyChar = null;
    _setState(BleState.disconnected);
    _logMessage('已断开连接');
  }

  // ── 发送打印数据（核心方法） ──
  Future<PrintTask> sendPrintData(PrintTask task) async {
    if (_state != BleState.connected || _writeChar == null || _device == null) {
      task.status = PrintTaskStatus.failed;
      task.error = '打印机未连接';
      task.completedAt = DateTime.now();
      _logMessage('打印失败: ${task.error}');
      return task;
    }

    _setState(BleState.printing);
    task.status = PrintTaskStatus.printing;
    _logMessage('开始打印...');
    notifyListeners();

    try {
      final Uint8List bytes = base64Decode(task.data);
      final int mtu = _device!.mtuNow;
      final int chunkSize = mtu - 3; // ATT 头部占用 3 字节
      _logMessage('数据大小: ${bytes.length} 字节, MTU: $mtu, 分包大小: $chunkSize');

      // 发送 ESC @ 初始化打印机（在数据已由后端包含时跳过重复发送）
      // 后端 iot_utils.py 已在数据头部添加了 ESC @，这里作为 double-safety
      bool useWriteWithoutResponse = false;

      for (int copy = 0; copy < task.copies; copy++) {
        int offset = 0;
        while (offset < bytes.length) {
          final int end = (offset + chunkSize > bytes.length)
              ? bytes.length
              : offset + chunkSize;
          final Uint8List chunk = bytes.sublist(offset, end);

          try {
            if (useWriteWithoutResponse) {
              await _writeChar!.write(chunk, withoutResponse: true);
            } else {
              await _writeChar!.write(chunk, withoutResponse: false)
                  .timeout(const Duration(milliseconds: 600));
            }
          } catch (e) {
            // 写入超时或失败 → 切到 withoutResponse 模式重试
            if (!useWriteWithoutResponse) {
              _logMessage('写入回应超时，切换到无回应写入模式...');
              useWriteWithoutResponse = true;
              await _writeChar!.write(chunk, withoutResponse: true);
            } else {
              rethrow;
            }
          }

          offset = end;

          // 微小延迟避免蓝牙缓冲区溢出
          await Future.delayed(const Duration(milliseconds: 10));
        }
      }

      task.status = PrintTaskStatus.completed;
      task.completedAt = DateTime.now();
      _logMessage('打印完成 ✓ (${bytes.length} 字节 × ${task.copies} 份)');
    } catch (e) {
      task.status = PrintTaskStatus.failed;
      task.error = e.toString();
      task.completedAt = DateTime.now();
      _logMessage('打印失败: $e');
    }

    _setState(BleState.connected);
    return task;
  }

  // ── 内部方法 ──
  void _setState(BleState s) {
    _state = s;
    notifyListeners();
  }

  void _onNotify(List<int> data) {
    // 打印机返回的通知（如缺纸、过热等状态）
    debugPrint('[BLE] 通知: $data');
  }

  void _logMessage(String msg) {
    _log.insert(0, _LogEntry(DateTime.now(), msg));
    if (_log.length > 200) _log.removeLast(); // 保留最近 200 条
    notifyListeners();
  }

  Future<void> _autoConnect() async {
    if (_savedDeviceId == null) return;
    _logMessage('尝试自动连接已保存的打印机...');
    try {
      // 1. 先查系统已配对设备
      final devices = await FlutterBluePlus.systemDevices([Guid(_savedDeviceId!)]);
      if (devices.isNotEmpty) {
        await connect(devices.first);
        return;
      }

      // 2. systemDevices 找不到 → 扫描匹配（BLE 热敏打印机可能不在 OS 配对列表）
      _logMessage('系统配对设备中找不到，开始扫描匹配...');
      await startScan(timeout: const Duration(seconds: 8));
      // 延迟等待扫描结果
      await Future.delayed(const Duration(seconds: 6));
      await stopScan();

      final matched = _scanResults.where(
        (r) => r.device.remoteId.toString() == _savedDeviceId,
      );
      if (matched.isNotEmpty) {
        _logMessage('扫描匹配成功，正在连接...');
        await connect(matched.first.device);
      } else {
        _logMessage('扫描也未找到已保存的设备，需手动连接');
      }
    } catch (e) {
      _logMessage('自动连接失败: $e');
    }
  }

  String get statusText {
    switch (_state) {
      case BleState.disconnected: return '未连接';
      case BleState.scanning:     return '扫描中';
      case BleState.connecting:   return '连接中';
      case BleState.connected:    return '已连接';
      case BleState.printing:     return '打印中';
    }
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}

class _LogEntry {
  final DateTime time;
  final String message;
  _LogEntry(this.time, this.message);
}
