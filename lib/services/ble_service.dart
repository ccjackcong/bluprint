// lib/services/ble_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/print_task.dart';

enum BleState {
  disconnected,
  scanning,
  connecting,
  connected,
  printing,
}

class BleService extends ChangeNotifier {
  static final BleService instance = BleService._();
  BleService._();

  final FlutterReactiveBle _ble = FlutterReactiveBle();

  BleState _state = BleState.disconnected;
  BleState get state => _state;

  String? _connectedDeviceId;
  String? _connectedDeviceName;
  String? get deviceName => _connectedDeviceName;

  // 用于数据的特征值
  String? _writeCharUuid;
  String? _serviceUuid;

  // 存储已保存的设备 ID
  String? _savedDeviceId;
  String get savedDeviceId => _savedDeviceId ?? '';

  // 扫描相关
  List<DiscoveredDevice> _scanResults = [];
  List<DiscoveredDevice> get scanResults => List.unmodifiable(_scanResults);
  bool _isScanning = false;
  bool get isScanning => _isScanning;

  // 日志
  final List<_LogEntry> _log = [];
  List<_LogEntry> get log => List.unmodifiable(_log);

  // 特征值订阅
  StreamSubscription<List<int>>? _notifySubscription;

  // ── 初始化 ──
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _savedDeviceId = prefs.getString('printer_device_id');
      _serviceUuid = prefs.getString('printer_service_uuid') ?? 
          '0000fee7-0000-1000-8000-00805f9b34fb';
      _writeCharUuid = prefs.getString('printer_write_char_uuid') ?? 
          '0000fee2-0000-1000-8000-00805f9b34fb';

      // 监听连接状态
      _ble.statusStream.listen((status) {
        debugPrint('[BLE] 状态变化: $status');
      });

      // 如果有保存的设备，自动连接
      if (_savedDeviceId != null && _savedDeviceId!.isNotEmpty) {
        _autoConnect();
      }

      _logMessage('BLE 服务初始化完成');
    } catch (e) {
      _logMessage('初始化失败: $e');
    }
  }

  // ── 扫描设备 ──
  Future<void> startScan({Duration timeout = const Duration(seconds: 10)}) async {
    if (_isScanning) return;
    _scanResults = [];
    _isScanning = true;
    _setState(BleState.scanning);
    _logMessage('开始扫描...');
    notifyListeners();

    try {
      final subscription = _ble.scanForDevices(
        withServices: [],
        scanMode: ScanMode.lowLatency,
      ).listen((device) {
        // 去重更新
        final index = _scanResults.indexWhere((d) => d.id == device.id);
        if (index >= 0) {
          _scanResults[index] = device;
        } else {
          _scanResults.add(device);
        }
        notifyListeners();
      });

      await Future.delayed(timeout);
      await subscription.cancel();
    } catch (e) {
      _logMessage('扫描出错: $e');
    }

    _isScanning = false;
    _setState(BleState.disconnected);
    _logMessage('扫描结束，发现 ${_scanResults.length} 个设备');
    notifyListeners();
  }

  Future<void> stopScan() async {
    _isScanning = false;
    notifyListeners();
  }

  // ── 连接设备 ──
  Future<bool> connect(DiscoveredDevice device) async {
    if (_state == BleState.connected || _state == BleState.connecting) {
      await disconnect();
    }

    _setState(BleState.connecting);
    _connectedDeviceId = device.id;
    _connectedDeviceName = device.name;
    _logMessage('正在连接 ${device.name} (${device.id})...');

    try {
      // 建立连接
      final connection = _ble.connectToDevice(
        id: device.id,
        connectionTimeout: const Duration(seconds: 15),
      );

      // 等待连接建立
      await connection.first;

      // 发现服务
      final services = await _ble.discoverServices(device.id);
      bool foundChar = false;

      for (final service in services) {
        if (service.serviceId == _serviceUuid) {
          for (final char in service.characteristics) {
            if (char.characteristicId == _writeCharUuid) {
              foundChar = true;
              _logMessage('找到写入特征值: ${char.characteristicId}');
              
              // 如果需要接收通知
              if (char.properties.contains(CharacteristicProperty.notify)) {
                _notifySubscription = _ble.subscribeToCharacteristic(
                  device.id,
                  _serviceUuid!,
                  _writeCharUuid!,
                ).listen((data) {
                  debugPrint('[BLE] 通知数据: $data');
                });
              }
            }
          }
        }
      }

      if (!foundChar) {
        _logMessage('未找到写入特征值');
        await disconnect();
        return false;
      }

      _setState(BleState.connected);
      _logMessage('已连接 ✓');
      await savePrinterConfig(deviceId: device.id);
      return true;
    } catch (e) {
      _logMessage('连接失败: $e');
      _setState(BleState.disconnected);
      return false;
    }
  }

  // ── 断开连接 ──
  Future<void> disconnect() async {
    if (_connectedDeviceId != null) {
      try {
        await _ble.clearGattCache(_connectedDeviceId!);
      } catch (_) {}
      _connectedDeviceId = null;
      _connectedDeviceName = null;
    }
    await _notifySubscription?.cancel();
    _notifySubscription = null;
    _setState(BleState.disconnected);
    _logMessage('已断开');
  }

  // ── 发送打印数据 ──
  Future<PrintTask> sendPrintData(PrintTask task) async {
    if (_state != BleState.connected || _connectedDeviceId == null) {
      task.status = PrintTaskStatus.failed;
      task.error = '打印机未连接';
      task.completedAt = DateTime.now();
      return task;
    }

    if (_writeCharUuid == null || _serviceUuid == null) {
      task.status = PrintTaskStatus.failed;
      task.error = '未配置特征值';
      task.completedAt = DateTime.now();
      return task;
    }

    _setState(BleState.printing);
    task.status = PrintTaskStatus.printing;
    _logMessage('开始打印...');
    notifyListeners();

    try {
      final bytes = base64Decode(task.data);
      final chunkSize = 20; // 经典 BLE MTU

      _logMessage('数据: ${bytes.length} 字节, 分包: $chunkSize');

      for (int copy = 0; copy < task.copies; copy++) {
        int offset = 0;
        while (offset < bytes.length) {
          final end = (offset + chunkSize > bytes.length) 
              ? bytes.length 
              : offset + chunkSize;
          final chunk = bytes.sublist(offset, end);

          await _ble.writeCharacteristicWithoutResponse(
            _connectedDeviceId!,
            _serviceUuid!,
            _writeCharUuid!,
            value: chunk,
          );

          offset = end;
          await Future.delayed(const Duration(milliseconds: 20));
        }
      }

      task.status = PrintTaskStatus.completed;
      task.completedAt = DateTime.now();
      _logMessage('打印完成 ✓');
    } catch (e) {
      task.status = PrintTaskStatus.failed;
      task.error = e.toString();
      task.completedAt = DateTime.now();
      _logMessage('打印失败: $e');
    }

    _setState(BleState.connected);
    return task;
  }

  // ── 辅助方法 ──
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
    _logMessage('配置已保存');
    notifyListeners();
  }

  void _setState(BleState s) {
    if (_state != s) {
      _state = s;
      notifyListeners();
    }
  }

  void _logMessage(String msg) {
    _log.insert(0, _LogEntry(DateTime.now(), msg));
    if (_log.length > 200) _log.removeLast();
    notifyListeners();
  }

  Future<void> _autoConnect() async {
    if (_savedDeviceId == null) return;
    _logMessage('尝试自动连接...');
    try {
      // 通过扫描找到设备并连接
      final subscription = _ble.scanForDevices(
        withServices: [],
        scanMode: ScanMode.lowLatency,
      ).listen((device) {
        if (device.id == _savedDeviceId) {
          subscription.cancel();
          connect(device);
        }
      });
      await Future.delayed(const Duration(seconds: 5));
      await subscription.cancel();
    } catch (e) {
      _logMessage('自动连接失败: $e');
    }
  }

  String get statusText {
    switch (_state) {
      case BleState.disconnected: return '未连接';
      case BleState.scanning: return '扫描中';
      case BleState.connecting: return '连接中';
      case BleState.connected: return '已连接';
      case BleState.printing: return '打印中';
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
