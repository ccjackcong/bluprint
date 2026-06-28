// lib/services/ble_service.dart
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
  // ⭐ 保留 _notifyChar，用于接收打印机状态通知
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

  // ── 初始化 ──
  Future<void> init() async {
    try {
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

      _logMessage('BLE 服务初始化完成');
    } catch (e) {
      _logMessage('初始化失败: $e');
      debugPrint('[BLE] 初始化异常: $e');
      // 注意：这里不抛出异常，让应用继续运行（可能在某些平台上不支持）
    }
  }

  // ── 保存打印机配置 ──
  Future<void> savePrinterConfig({
    required String deviceId,
    String? serviceUuid,
    String? writeCharUuid,
  }) async {
    try {
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
    } catch (e) {
      _logMessage('保存配置失败: $e');
    }
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
      _isScanning = false;
      notifyListeners();
      return;
    }

    // 超时后停止
    await Future.delayed(timeout);
    await stopScan();
  }

  Future<void> stopScan() async {
    if (!_isScanning) return;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {
      // 忽略停止扫描时的错误
    }
    _isScanning = false;
    _logMessage('扫描结束，发现 ${_scanResults.length} 个设备');
    notifyListeners();
  }

  // ── 连接打印机 ──
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

      for (final service in services) {
        if (service.uuid.toString().toLowerCase() == _serviceUuid.toLowerCase()) {
          for (final char in service.characteristics) {
            final cu = char.uuid.toString().toLowerCase();
            if (cu == _writeCharUuid.toLowerCase()) {
              _writeChar = char;
              _logMessage('找到写入特征值: ${char.uuid}');
            }
            if (char.properties.notify || char.properties.indicate) {
              _notifyChar = char;
              await char.setNotifyValue(true);
              char.lastValueStream.listen(_onNotify);
              _logMessage('找到通知特征值: ${char.uuid}');
            }
          }
        }
      }

      if (_writeChar == null) {
        _logMessage('未找到写入特征值 (service=$_serviceUuid, writeChar=$_writeCharUuid)');
        _logMessage('可用服务列表:');
        for (final s in services) {
          _logMessage('  Service: ${s.uuid}');
          for (final c in s.characteristics) {
            _logMessage('    Char: ${c.uuid} (${c.properties})');
          }
        }
        await device.disconnect();
        _setState(BleState.disconnected);
        _device = null;
        return false;
      }

      _setState(BleState.connected);
      _logMessage('打印机已连接 ✓');
      await savePrinterConfig(deviceId: device.remoteId.toString());
      return true;
    } catch (e) {
      _logMessage('连接失败: $e');
      _setState(BleState.disconnected);
      _device = null;
      try {
        await device.disconnect();
      } catch (_) {
        // 忽略断开时的错误
      }
      return false;
    }
  }

  // ── 断开连接 ──
  Future<void> disconnect() async {
    if (_device != null) {
      try {
        await _device!.disconnect();
      } catch (_) {
        // 忽略断开错误
      }
      _device = null;
    }
    _writeChar = null;
    _notifyChar = null;
    _setState(BleState.disconnected);
    _logMessage('已断开连接');
  }

  // ── 发送打印数据（核心方法） ──
  Future<PrintTask> sendPrintData(PrintTask task) async {
    // ⭐ 增加更严格的连接检查
    if (_state != BleState.connected) {
      task.status = PrintTaskStatus.failed;
      task.error = '打印机未连接 (当前状态: ${_state.name})';
      task.completedAt = DateTime.now();
      _logMessage('打印失败: ${task.error}');
      return task;
    }

    if (_writeChar == null) {
      task.status = PrintTaskStatus.failed;
      task.error = '未找到写入特征值';
      task.completedAt = DateTime.now();
      _logMessage('打印失败: ${task.error}');
      return task;
    }

    if (_device == null) {
      task.status = PrintTaskStatus.failed;
      task.error = '设备对象为空';
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
      // 安全计算分包大小（确保至少为 1）
      final int chunkSize = (mtu - 3) > 0 ? (mtu - 3) : 20;
      _logMessage('数据大小: ${bytes.length} 字节, MTU: $mtu, 分包大小: $chunkSize');

      for (int copy = 0; copy < task.copies; copy++) {
        int offset = 0;
        while (offset < bytes.length) {
          final int end = (offset + chunkSize > bytes.length)
              ? bytes.length
              : offset + chunkSize;
          final Uint8List chunk = bytes.sublist(offset, end);

          // ⭐ 使用 write 并等待结果，增加超时保护
          await _writeChar!.write(chunk, withoutResponse: false).timeout(
                const Duration(seconds: 5),
                onTimeout: () {
                  throw TimeoutException('写入超时');
                },
              );

          offset = end;

          // 微小延迟避免蓝牙缓冲区溢出
          await Future.delayed(const Duration(milliseconds: 10));
        }
        // 每份打印之间增加短暂延迟
        if (copy < task.copies - 1) {
          await Future.delayed(const Duration(milliseconds: 50));
        }
      }

      task.status = PrintTaskStatus.completed;
      task.completedAt = DateTime.now();
      task.error = null;
      _logMessage('打印完成 ✓ (${bytes.length} 字节 × ${task.copies} 份)');
    } on TimeoutException catch (e) {
      task.status = PrintTaskStatus.failed;
      task.error = '写入超时: $e';
      task.completedAt = DateTime.now();
      _logMessage('打印超时: $e');
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
    if (_state != s) {
      _state = s;
      notifyListeners();
    }
  }

  void _onNotify(List<int> data) {
    // 打印机返回的通知（如缺纸、过热等状态）
    debugPrint('[BLE] 通知: $data');
    // 可以在这里解析打印机状态并更新 UI
  }

  void _logMessage(String msg) {
    _log.insert(0, _LogEntry(DateTime.now(), msg));
    if (_log.length > 200) _log.removeLast(); // 保留最近 200 条
    notifyListeners();
  }

  // lib/services/ble_service.dart
Future<void> _autoConnect() async {
  if (_savedDeviceId == null) return;
  _logMessage('尝试自动连接已保存的打印机...');
  try {
    // ⭐ 将 String 转换为 Guid
    final deviceIdGuid = Guid.fromString(_savedDeviceId!);
    final devices = await FlutterBluePlus.systemDevices([deviceIdGuid]);
    if (devices.isNotEmpty) {
      await connect(devices.first);
    } else {
      _logMessage('未找到已保存的设备，需手动连接');
    }
  } catch (e) {
    _logMessage('自动连接失败: $e');
  }
}

  // ── 公开的辅助方法 ──
  String get statusText {
    switch (_state) {
      case BleState.disconnected:
        return '未连接';
      case BleState.scanning:
        return '扫描中';
      case BleState.connecting:
        return '连接中';
      case BleState.connected:
        return '已连接';
      case BleState.printing:
        return '打印中';
    }
  }

  // 清空日志
  void clearLog() {
    _log.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}

// ── 日志条目 ──
class _LogEntry {
  final DateTime time;
  final String message;
  _LogEntry(this.time, this.message);
}
