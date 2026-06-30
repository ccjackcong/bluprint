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

/// 打印机品牌（决定使用哪种打印协议）
enum PrinterBrand {
  niimbot('NIIMBOT', '精臣 B3S 等包封协议打印机'),
  gprinter('佳博', 'GP 等标准 ESC/POS 打印机'),
  generic('通用', '标准 ESC/POS 打印机');

  final String label;
  final String description;
  const PrinterBrand(this.label, this.description);
}

/// 已知打印机 UUID 预设表（来自 nRF 实际探测结果）
class _KnownPrinterPresets {
  // ── 精臣 B3S_P (NIIMBOT 协议) ──
  static const Map<String, String> b3s = {
    // 主协议通道（优先）
    'service':   'E7810A71-73AE-499D-8C15-FAA9AEF0C3F2',
    'write':     'BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F',
    'notify':    'BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F', // 同一个 char 同时支持 R/W/Notify
    // NUS 备用通道
    'nus_service': '49535343-FE7D-4AE5-8FA9-9FAFD205E455',
    'nus_tx':      '49535343-8841-43F4-A8D4-ECBE34729BB3',
    'nus_rx':      '49535343-1E4D-4BD9-BA61-23C647249616',
  };

  // ── 佳博 GP-5890XIII (ESC/POS) ──
  static const Map<String, String> gprinter = {
    'service':   '49535343-FE7D-4AE5-8FA9-9FAFD205E455',  // NUS
    'write':     '49535343-6DAA-4D02-ABF6-19569ACA69FE',  // TX (R/W)
    'notify':    '49535343-ACA3-481C-91EC-D85E28A60318',  // RX (Write+Notify)
    // ── 佳博 FFF0 备用通道（优先使用 → 支持 WriteWithoutResponse，打印数据流更可靠）──
    'alt_service': '0000FFF0-0000-1000-8000-00805F9B34FB',
    'alt_write':   '0000FFF2-0000-1000-8000-00805F9B34FB',  // WNR 优先
    'alt_notify':  '0000FFF1-0000-1000-8000-00805F9B34FB',
  };
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
  BluetoothCharacteristic? get writeChar => _writeChar;

  BluetoothCharacteristic? _notifyChar;
  BluetoothCharacteristic? get notifyChar => _notifyChar;

  /// 当前连接的打印机品牌（自动检测或用户手动指定）
  PrinterBrand _brand = PrinterBrand.generic;
  PrinterBrand get brand => _brand;

  // ── 已保存的打印机配置 ──
  String? _savedDeviceId;
  String get savedDeviceId => _savedDeviceId ?? '';

  // ── 全局 UUID（向后兼容旧版存储）──
  String _serviceUuid = '';
  String _writeCharUuid = '';

  String get serviceUuid => _serviceUuid;
  String get writeCharUuid => _writeCharUuid;

  // ── 按 MAC 存储的 UUID 配置（每台打印机独立）──
  Map<String, Map<String, String>> _printerUuids = {};

  /// 获取指定 MAC 的完整配置（API + BLE UUID + 品牌）
  Map<String, dynamic>? getConfigForMac(String mac) {
    if (!_printerUuids.containsKey(mac)) return null;
    return {
      ..._printerUuids[mac]!,
      'mac': mac,
    };
  }

  /// 获取所有已配对打印机的 MAC 列表
  List<String> get allPairedMacs => _printerUuids.keys.toList();

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

    // 加载全局 UUID（向后兼容）
    final svc = prefs.getString('printer_service_uuid');
    if (svc != null && svc.isNotEmpty) _serviceUuid = svc;
    final wr = prefs.getString('printer_write_char_uuid');
    if (wr != null && wr.isNotEmpty) _writeCharUuid = wr;

    // 加载按 MAC 存储的 UUID 配置
    await _loadPrinterUuids();

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

  // ── 加载按 MAC 存储的 UUID 配置 ──
  Future<void> _loadPrinterUuids() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('printer_uuid_configs');
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        _printerUuids = decoded.map((k, v) =>
            MapEntry(k, Map<String, String>.from(v as Map)));
      } catch (e) {
        debugPrint('[BLE] 解析打印机 UUID 配置失败: $e');
        _printerUuids = {};
      }
    }
  }

  // ── 保存按 MAC 的 UUID 配置 ──
  Future<void> _savePrinterUuids() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('printer_uuid_configs', jsonEncode(_printerUuids));
  }

  // ── 保存打印机完整配置（UUID + 品牌 + MAC）──
  Future<void> savePrinterConfig({
    required String deviceId,
    String? serviceUuid,
    String? writeCharUuid,
    String? brandName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    _savedDeviceId = deviceId;
    await prefs.setString('printer_device_id', deviceId);

    if (deviceId.isNotEmpty) {
      // 按 MAC 存储 UUID 配置
      _printerUuids[deviceId] = {
        'service_uuid': serviceUuid ?? '',
        'write_char_uuid': writeCharUuid ?? '',
        'brand': brandName ?? _brand.name,
      };
      await _savePrinterUuids();

      // 同步到全局字段（向后兼容）
      if (serviceUuid != null) _serviceUuid = serviceUuid;
      if (writeCharUuid != null) _writeCharUuid = writeCharUuid;
    }

    _logMessage('💾 打印机配置已保存: $deviceId (${_brand.label})');
    notifyListeners();
  }

  /// 删除某台打印机的配对记录
  Future<void> deletePrinterConfig(String mac) async {
    _printerUuids.remove(mac);
    await _savePrinterUuids();
    if (_savedDeviceId == mac) {
      _savedDeviceId = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('printer_device_id');
    }
    _logMessage('🗑️ 已删除打印机 $mac 的配对记录');
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
      await FlutterBluePlus.startScan(timeout: timeout);
      FlutterBluePlus.scanResults.listen((results) {
        _scanResults = results;
        notifyListeners();
      });
    } catch (e) {
      _logMessage('扫描出错: $e');
    }

    await Future.delayed(timeout);
    await stopScan();
  }

  Future<void> stopScan() async {
    if (!_isScanning) return;
    try { await FlutterBluePlus.stopScan(); } catch (_) {}
    _isScanning = false;
    _logMessage('扫描结束，发现 ${_scanResults.length} 个设备');
    notifyListeners();
  }

  // ── 根据设备名称和服务 UUID 自动识别打印机品牌 ──
  PrinterBrand _detectBrand(BluetoothDevice device, List<BluetoothService> services) {
    final name = device.platformName.toLowerCase();

    // 按名称匹配
    if (name.contains('b3s') || name.contains('niim') || name.contains('精臣')) {
      return PrinterBrand.niimbot;
    }
    if (name.contains('gp') || name.contains('gprinter') || name.contains('佳博') ||
        name.contains('5890')) {
      return PrinterBrand.gprinter;
    }

    // 按 Service UUID 匹配（更可靠）
    for (final s in services) {
      final suid = s.uuid.toString().toLowerCase();
      if (suid.contains('e7810a71')) return PrinterBrand.niimbot;  // NIIMBOT 主协议
      if (suid.startsWith('fff0')) return PrinterBrand.gprinter;  // Gprinter 服务
    }

    return PrinterBrand.generic;
  }

  // ── 连接打印机 ──
  Future<bool> connect(BluetoothDevice device) async {
    if (_state == BleState.connecting || _state == BleState.connected) {
      await disconnect();
    }

    _device = device;
    _setState(BleState.connecting);
    final mac = device.remoteId.toString();
    _logMessage('正在连接 ${device.platformName} ($mac)...');

    try {
      await device.connect(timeout: const Duration(seconds: 15));
      _logMessage('GATT 连接成功，协商 MTU...');

      // 协商 MTU
      try {
        final int negotiatedMtu = await device.requestMtu(512);
        _logMessage('MTU 协商完成: $negotiatedMtu');
      } catch (e) {
        _logMessage('MTU 协商失败 (将使用默认 23): $e');
      }

      _logMessage('正在发现服务...');
      final services = await device.discoverServices();
      _writeChar = null;
      _notifyChar = null;

      // ── 自动检测品牌 ──
      _brand = _detectBrand(device, services);
      _logMessage('🏷️ 检测到品牌: ${_brand.label}');

      // ── 第 1 步：用预设 UUID 匹配（按品牌优先级）──
      bool foundByConfig = await _tryMatchByPreset(services, mac);

      // ── 第 2 步：用已保存的 per-MAC UUID 匹配 ──
      if (!foundByConfig) {
        foundByConfig = await _tryMatchBySavedMac(services, mac);
      }

      // ── 第 3 步：自动发现（兜底）──
      if (!foundByConfig) {
        _logMessage('预设 UUID 未匹配，自动发现可写特征值...');
        _logMessage('可用服务列表:');
        for (final s in services) {
          _logMessage('  Service: ${s.uuid}');
          for (final c in s.characteristics) {
            _logMessage('    Char: ${c.uuid} (${c.properties})');
          }
        }
        foundByConfig = await _autoDiscoverWriteChar(services);
      }

      if (_writeChar == null) {
        _logMessage('❌ 未找到任何可写入的特征值');
        await device.disconnect();
        _setState(BleState.disconnected);
        return false;
      }

      _setState(BleState.connected);
      _logMessage('✅ 打印机已连接 ✓ [${_brand.label}] Service=${_writeChar!.serviceUuid} Write=${_writeChar!.uuid}');

      // 监听连接状态变化
      device.connectionState.listen((BluetoothConnectionState s) {
        debugPrint('[BLE] 连接状态变化: $s');
        if (s == BluetoothConnectionState.disconnected) {
          _logMessage('⚠ 打印机连接已断开');
          _writeChar = null;
          _notifyChar = null;
          if (_state != BleState.disconnected) {
            _setState(BleState.disconnected);
          }
        }
      });

      // 保存本次连接发现的 UUID 和品牌
      await savePrinterConfig(
        deviceId: mac,
        serviceUuid: _writeChar!.serviceUuid.toString(),
        writeCharUuid: _writeChar!.uuid.toString(),
      );

      onConnected?.call(mac);
      return true;
    } catch (e) {
      _logMessage('连接失败: $e');
      _setState(BleState.disconnected);
      try { await device.disconnect(); } catch (_) {}
      return false;
    }
  }

  /// 用预设 UUID 按品牌优先匹配
  Future<bool> _tryMatchByPreset(List<BluetoothService> services, String mac) async {
    final savedCfg = _printerUuids[mac];
    // 如果该 MAC 有已保存的品牌偏好，优先使用
    final preferredBrand = savedCfg != null && savedCfg['brand']?.isNotEmpty == true
        ? PrinterBrand.values.where((b) => b.name == savedCfg['brand']).firstOrNull
        : _brand;

    // 根据品牌确定预设 UUID
    Map<String, String>? preset;
    switch (preferredBrand) {
      case PrinterBrand.niimbot:
        preset = _KnownPrinterPresets.b3s;
        break;
      case PrinterBrand.gprinter:
        // 佳博：优先使用 FFF2 (WNR) 通道 → 打印数据流更可靠
        if (await _tryMatchAltPreset(services,
            _KnownPrinterPresets.gprinter['alt_service']!,
            _KnownPrinterPresets.gprinter['alt_write']!,
            _KnownPrinterPresets.gprinter['alt_notify']!,
            '佳博 FFF2 (WNR)')) {
          return true;
        }
        preset = _KnownPrinterPresets.gprinter;
        break;
      case PrinterBrand.generic:
        break;
      case null:
        break;
    }

    if (preset == null) return false;

    // 尝试匹配预设的主 Service UUID
    final targetSvcUuid = preset['service']!;
    final targetWriteUuid = preset['write']!;

    for (final service in services) {
      if (service.uuid.toString().toLowerCase() == targetSvcUuid.toLowerCase()) {
        for (final char in service.characteristics) {
          final cu = char.uuid.toString().toLowerCase();
          if (cu == targetWriteUuid.toLowerCase() &&
              (char.properties.write || char.properties.writeWithoutResponse)) {
            _writeChar = char;
            _serviceUuid = service.uuid.toString();
            _writeCharUuid = char.uuid.toString();
            _logMessage('📍 品牌预设匹配: Service=$targetSvcUuid Write=$targetWriteUuid');
          }
          if ((char.properties.notify || char.properties.indicate) && _notifyChar == null) {
            _notifyChar = char;
            try { await char.setNotifyValue(true); } catch (_) {}
            char.lastValueStream.listen(_onNotify);
          }
        }
        if (_writeChar != null) return true;
      }
    }

    // 预设主 Service 未找到，但可能通过 NUS 备用通道匹配
    if (preset.containsKey('nus_service')) {
      final nusSvc = preset['nus_service']!;
      final nusTx = preset['nus_tx']!;
      final nusRx = preset['nus_rx']!;

      for (final service in services) {
        if (service.uuid.toString().toLowerCase() == nusSvc.toLowerCase()) {
          for (final char in service.characteristics) {
            final cu = char.uuid.toString().toLowerCase();
            if (cu == nusTx.toLowerCase() &&
                (char.properties.write || char.properties.writeWithoutResponse)) {
              _writeChar = char;
              _serviceUuid = nusSvc;
              _writeCharUuid = nusTx;
              _logMessage('📍 NUS 备用通道匹配: $nusSvc / $nusTx');
            }
            if (cu == nusRx.toLowerCase() && _notifyChar == null) {
              _notifyChar = char;
              try { await char.setNotifyValue(true); } catch (_) {}
              char.lastValueStream.listen(_onNotify);
            }
          }
          if (_writeChar != null) return true;
        }
      }
    }

    return false;
  }

  /// 匹配备用预设 UUID（用于佳博 FFF2 WNR 通道等）
  Future<bool> _tryMatchAltPreset(List<BluetoothService> services,
      String svcUuid, String writeUuid, String notifyUuid, String label) async {
    for (final service in services) {
      final suid = service.uuid.toString().toLowerCase();
      if (suid != svcUuid.toLowerCase()) continue;
      for (final char in service.characteristics) {
        final cu = char.uuid.toString().toLowerCase();
        if (cu == writeUuid.toLowerCase() &&
            (char.properties.write || char.properties.writeWithoutResponse)) {
          _writeChar = char;
          _serviceUuid = service.uuid.toString();
          _writeCharUuid = char.uuid.toString();
          _logMessage('📍 $label: Service=$svcUuid Write=$writeUuid');
        }
        if (cu == notifyUuid.toLowerCase() && _notifyChar == null &&
            (char.properties.notify || char.properties.indicate)) {
          _notifyChar = char;
          try { await char.setNotifyValue(true); } catch (_) {}
          char.lastValueStream.listen(_onNotify);
        }
      }
      if (_writeChar != null) return true;
    }
    return false;
  }

  /// 用该 MAC 已保存的 UUID 匹配
  Future<bool> _tryMatchBySavedMac(List<BluetoothService> services, String mac) async {
    final cfg = _printerUuids[mac];
    if (cfg == null) return false;

    final svcUuid = cfg['service_uuid'] ?? '';
    final writeUuid = cfg['write_char_uuid'] ?? '';
    if (svcUuid.isEmpty || writeUuid.isEmpty) return false;

    for (final service in services) {
      if (service.uuid.toString().toLowerCase() == svcUuid.toLowerCase()) {
        for (final char in service.characteristics) {
          if (char.uuid.toString().toLowerCase() == writeUuid.toLowerCase() &&
              (char.properties.write || char.properties.writeWithoutResponse)) {
            _writeChar = char;
            _serviceUuid = svcUuid;
            _writeCharUuid = writeUuid;
            _logMessage('📍 已保存配置匹配: $svcUuid / $writeUuid');
          }
          if ((char.properties.notify || char.properties.indicate) && _notifyChar == null) {
            _notifyChar = char;
            try { await char.setNotifyValue(true); } catch (_) {}
            char.lastValueStream.listen(_onNotify);
          }
        }
        if (_writeChar != null) return true;
      }
    }
    return false;
  }

  /// 兜底：自动发现第一个可写特征值
  Future<bool> _autoDiscoverWriteChar(List<BluetoothService> services) async {
    // 蓝牙核心标准服务（Generic Access / Device Info / Battery 等）
    // 注意: 000018F0/000018F2 是厂商自定义服务，不应跳过
    const stdServices = [
      '00001800', '00001801', '0000180a', '0000180f', '00001812',
    ];
    for (final service in services) {
      final uuid = service.uuid.toString().toLowerCase();
      if (stdServices.contains(uuid)) continue;
      if (uuid.startsWith('00002a')) continue; // 标准特征值声明

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
          try { await char.setNotifyValue(true); } catch (_) {}
          char.lastValueStream.listen(_onNotify);
          _logMessage('✨ 自动发现 Notify: ${char.uuid}');
        }
      }
    }
    return _writeChar != null;
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

  // ── 发送打印数据（根据打印机品牌选择协议）──
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
    notifyListeners();

    try {
      switch (_brand) {
        case PrinterBrand.niimbot:
          // NIIMBOT 包封协议
          if (task.rawPixels != null) {
            _logMessage('开始打印 (NIIMBOT 包封协议)...');
            await _doSendNiimbot(task.rawPixels!, task.widthPx!, task.heightPx!, task.bytesPerRow!, task.copies);
            task.status = PrintTaskStatus.completed;
            task.completedAt = DateTime.now();
            _logMessage('✅ NIIMBOT 打印完成 ✓');
          } else {
            throw Exception('NIIMBOT 协议需要原始位图数据，但 rawPixels 为空');
          }

        case PrinterBrand.gprinter:
        case PrinterBrand.generic:
          // 标准 ESC/POS
          _logMessage('开始打印 (GS v 0 ESC/POS)...');
          // 发送 ESC @ 初始化命令唤醒打印机（与 nRF 测试一致）
          await _writeChar!.write(Uint8List.fromList([0x1B, 0x40]), withoutResponse: true);
          await Future.delayed(const Duration(milliseconds: 50));
          await _doSendData(task.data, task.copies);
          task.status = PrintTaskStatus.completed;
          task.completedAt = DateTime.now();
          _logMessage('✅ ESC/POS 打印完成 ✓');
      }
    } catch (e) {
      // NIIMBOT 或 GS v 0 失败 → 对 ESC/POS 设备尝试回退 ESC *
      if (_brand != PrinterBrand.niimbot && task.fallbackData != null && task.fallbackData!.isNotEmpty) {
        _logMessage('⚠ 主协议失败: $e，尝试 ESC * 回退...');
        try {
          await _doSendData(task.fallbackData!, task.copies);
          task.status = PrintTaskStatus.completed;
          task.usedFallback = true;
          task.completedAt = DateTime.now();
          _logMessage('✅ ESC * 回退打印成功 ✓');
        } catch (e2) {
          task.status = PrintTaskStatus.failed;
          task.error = '$e | ESC*: $e2';
          task.completedAt = DateTime.now();
          _logMessage('❌ 打印失败 (两套指令均失败): $e2');
        }
      } else {
        task.status = PrintTaskStatus.failed;
        task.error = e.toString();
        task.completedAt = DateTime.now();
        _logMessage('❌ 打印失败: $e');
      }
    }

    _setState(BleState.connected);
    return task;
  }

  // ════════════════════════════════════════════════
  //  NIIMBOT 包封协议实现
  //  基于 niimprint Python 库 (AndBondStyle/niimprint)
  //  帧: 55 55 [Cmd] [DataLen] [Data...] [Checksum] AA AA
  // ════════════════════════════════════════════════

  Future<void> _doSendNiimbot(
    Uint8List rawPixels,
    int widthPx,
    int heightPx,
    int bytesPerRow,
    int copies,
  ) async {
    _logMessage('📐 位图尺寸: ${widthPx}×${heightPx}px, 每行$bytesPerRow字节, 共${rawPixels.length}字节数据');

    for (int copy = 0; copy < copies; copy++) {
      // ── 1) 握手 ──
      await _sendNiimbotFrame(0xC1, [0x01]);
      await Future.delayed(const Duration(milliseconds: 50));

      // ── 2) 打印浓度 ──
      await _sendNiimbotFrame(0x21, [5]);
      await Future.delayed(const Duration(milliseconds: 30));

      // ── 3) 标签类型 ──
      await _sendNiimbotFrame(0x23, [1]);
      await Future.delayed(const Duration(milliseconds: 30));

      // ── 4) 开始打印 (data=b"\x01") ──
      await _sendNiimbotFrame(0x01, [0x01]);
      _logMessage('▶ 开始打印');
      await Future.delayed(const Duration(milliseconds: 30));

      // ── 5) 页面开始 ──
      await _sendNiimbotFrame(0x03, [0x01]);
      await Future.delayed(const Duration(milliseconds: 30));

      // ── 6) 设置页面尺寸 (struct.pack(">HH", height, width)) ──
      // niimprint 传入 (image.height, image.width) → 第一个 uint16=高度
      await _sendNiimbotFrame(0x13, [
        (heightPx >> 8) & 0xFF, heightPx & 0xFF,  // 高度 big-endian
        (widthPx >> 8) & 0xFF,  widthPx & 0xFF,   // 宽度 big-endian
      ]);
      _logMessage('📄 页面尺寸: ${widthPx}×${heightPx}');
      await Future.delayed(const Duration(milliseconds: 30));

      // ── 7) 逐行发送图像数据 ──
      // 每行: header(6B) = row(2B big-endian) + 0,0,0 + 1 + pixel_data(N)
      // 后端 rawPixels: 0=black 需反转为 1=black (niimprint 期望)
      int sentRows = 0;
      for (int row = 0; row < heightPx; row++) {
        final rowStart = row * bytesPerRow;
        if (rowStart + bytesPerRow > rawPixels.length) break;

        final rowData = rawPixels.sublist(rowStart, rowStart + bytesPerRow);
        // 反转像素位: 0→0xFF (黑→打印), 1→0xFE (白→不打印)
        final inverted = Uint8List.fromList(
          rowData.map((b) => b ^ 0xFF).toList(),
        );

        await _sendNiimbotFrame(0x85, <int>[
          (row >> 8) & 0xFF, row & 0xFF,  // 行号 big-endian uint16
          0, 0, 0,                         // reserved
          1,                               // fixed
          ...inverted,                      // 像素数据 (1=print)
        ]);
        sentRows++;

        if (row % 10 == 0) {
          await Future.delayed(const Duration(milliseconds: 15));
        }
      }
      _logMessage('🖼 图像数据传输完成 ($sentRows 行)');

      // ── 8) 页面结束 ──
      await _sendNiimbotFrame(0xE3, [0x01]);
      _logMessage('📋 页面结束');
      await Future.delayed(const Duration(milliseconds: 50));

      // ── 9) 打印结束 (niimprint 循环重试直到打印机确认) ──
      for (int retry = 0; retry < 10; retry++) {
        await _sendNiimbotFrame(0xF3, [0x01]);
        await Future.delayed(const Duration(milliseconds: 100));
      }
      _logMessage('🏁 打印完成，走纸弹出');

      if (copy < copies - 1) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  /// 发送 NIIMBOT 包封协议帧
  Future<void> _sendNiimbotFrame(int cmd, List<int> data) async {
    final dataLen = data.length;
    var checksum = cmd ^ dataLen;
    for (final d in data) checksum ^= d;

    final frame = <int>[
      0x55, 0x55,           // 协议头
      cmd,                   // 命令
      dataLen,               // 数据长度
      ...data,               // 数据
      checksum,              // 校验和 (XOR)
      0xAA, 0xAA,            // 协议尾
    ];
    await _sendRawBytes(Uint8List.fromList(frame));
  }

  // ════════════════════════════════════════════════
  //  ESC/POS 分包发送逻辑
  // ════════════════════════════════════════════════

  /// BLE 分包发送 ESC/POS 数据
  Future<void> _doSendData(String base64Data, int copies) async {
    final Uint8List bytes = base64Decode(base64Data);
    final int mtu = _device!.mtuNow;
    final int chunkSize = mtu - 3; // ATT 头部占用 3 字节
    _logMessage('数据大小: ${bytes.length} 字节, MTU: $mtu, 分包大小: $chunkSize');

    // 优先使用无应答写入：NUS/FFF2 等数据通道特征值通常同时声明
    // Write + WriteWithoutResponse，但打印机不回 ATT 应答，应答模式必然超时
    final useWoR = _writeChar!.properties.writeWithoutResponse;

    for (int copy = 0; copy < copies; copy++) {
      int offset = 0;
      while (offset < bytes.length) {
        final int end = (offset + chunkSize > bytes.length)
            ? bytes.length
            : offset + chunkSize;
        final Uint8List chunk = bytes.sublist(offset, end);

        try {
          if (useWoR) {
            await _writeChar!.write(chunk, withoutResponse: true);
          } else {
            // 先尝试带应答写入（更可靠），超时则切换无应答
            await _writeChar!.write(chunk, withoutResponse: false)
                .timeout(const Duration(milliseconds: 600));
          }
        } catch (e) {
          // 写入超时 → 切换无应答模式重试当前 chunk
          if (!useWoR) {
            _logMessage('写入回应超时，切到无回应模式重试...');
            await _writeChar!.write(chunk, withoutResponse: true);
          } else {
            rethrow;
          }
        }

        offset = end;
        await Future.delayed(const Duration(milliseconds: 30));
      }
    }
  }

  /// 发送原始字节（NIIMBOT 协议帧用）
  Future<void> _sendRawBytes(Uint8List bytes) async {
    final int mtu = _device!.mtuNow;
    final int chunkSize = mtu - 3;
    int offset = 0;

    while (offset < bytes.length) {
      final int end = (offset + chunkSize > bytes.length)
          ? bytes.length
          : offset + chunkSize;
      final chunk = bytes.sublist(offset, end);

      // NIIMBOT 使用无应答写入（打印机不回复确认）
      if (_writeChar!.properties.writeWithoutResponse) {
        await _writeChar!.write(chunk, withoutResponse: true);
      } else {
        await _writeChar!.write(chunk, withoutResponse: false)
            .timeout(const Duration(milliseconds: 300));
      }

      offset = end;
      await Future.delayed(const Duration(milliseconds: 15)); // NIIMBOT 需要较短间隔
    }
  }

  // ── 内部方法 ──
  void _setState(BleState s) {
    _state = s;
    notifyListeners();
  }

  void _onNotify(List<int> data) {
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
      final devices = await FlutterBluePlus.systemDevices([Guid(_savedDeviceId!)]);
      if (devices.isNotEmpty) {
        await connect(devices.first);
        return;
      }

      _logMessage('系统配对设备中找不到，开始扫描匹配...');
      await startScan(timeout: const Duration(seconds: 8));
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
