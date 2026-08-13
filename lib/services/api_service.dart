import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/print_task.dart';
import 'ble_service.dart';
import 'http_server.dart';
import 'app_log.dart';
import 'mqtt_service.dart';

/// 服务器 API 客户端 — BluPrint 拉取 BLE 打印任务
///
/// 2026-08-12 重构：从"轮询"改为"MQTT 推送 + 手动拉取"。
/// - 任务产生后后端通过 MQTT 推送通知，App 收到后立刻拉取打印（毫秒级）。
/// - 保留手动拉取按钮（fetchAndPrint），推送未收到时可手动触发。
/// - 心跳保活定时器保留（60s 一次 bindDevice），不依赖 MQTT。
class ApiService extends ChangeNotifier {
  static final ApiService instance = ApiService._();
  ApiService._();

  // ── 配置 ──
  String _baseUrl = '';
  String get baseUrl => _baseUrl;

  String _deviceId = '';
  String get deviceId => _deviceId;

  String _storeId = '';
  String get storeId => _storeId;

  String _deviceKey = '';
  String get deviceKey => _deviceKey;

  bool _isConfigured = false;
  bool get isConfigured => _isConfigured;

  String? _lastError;
  String? get lastError => _lastError;

  // ── 状态 ──
  bool _isServerConnected = false;
  bool get isServerConnected => _isServerConnected;

  int _pendingJobCount = 0;
  int get pendingJobCount => _pendingJobCount;

  DateTime? _lastHeartbeat;
  DateTime? get lastHeartbeat => _lastHeartbeat;

  bool _isProcessing = false;

  // ── MQTT 推送开关（默认关闭，设置中可开启）──
  bool _mqttEnabled = false;
  bool get mqttEnabled => _mqttEnabled;

  Timer? _heartbeatTimer;
  bool _heartbeatRunning = false;

  // ── 按 BLE MAC 索引的打印机配置存储 ──
  Map<String, Map<String, String>> _printerConfigs = {};

  /// 统一日志：控制台 + 全局诊断日志（AppLog）。
  /// 仅转发以 [ApiService] 为前缀的 debugPrint，保持现有控制台输出不变。
  void _log(String m) {
    debugPrint(m);
    AppLog.instance.d('API', m.replaceFirst(RegExp(r'^\[ApiService\]\s*'), ''));
  }

  // ── 初始化 ──
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();

    // 加载全局配置（向后兼容）
    _baseUrl = prefs.getString('api_base_url') ?? '';
    _deviceId = prefs.getString('api_device_id') ?? '';
    _storeId = prefs.getString('api_store_id') ?? '';
    _deviceKey = prefs.getString('api_device_key') ?? '';

    // 加载按打印机存储的配置
    await _loadPrinterConfigs();

    // 如果当前有 BLE 打印机已保存，尝试加载其配置
    final ble = BleService.instance;
    final savedMac = ble.savedDeviceId;
    if (savedMac.isNotEmpty && _printerConfigs.containsKey(savedMac)) {
      await _applyPrinterConfig(savedMac);
    }

    _isConfigured = _baseUrl.isNotEmpty && _deviceId.isNotEmpty && _deviceKey.isNotEmpty;

    // 注册 BLE 连接成功回调 → 自动加载对应打印机的 API 配置
    ble.onConnected = (String mac) {
      _log('[ApiService] 🔗 BLE 已连接 $mac，尝试加载配置...');
      loadConfigForPrinter(mac);
    };

    // 注册 MQTT 推送回调 → 收到通知立刻拉取打印
    MqttPushService.instance.onNotify = () {
      _log('[ApiService] 📡 MQTT 推送触发拉取');
      fetchAndPrint();
    };

    // 已配置则自动启动心跳（不启动轮询，改 MQTT 推送）
    if (_isConfigured) {
      startHeartbeat();
    }
    notifyListeners();
  }

  // ── 加载所有打印机的 API 配置 ──
  Future<void> _loadPrinterConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('api_configs');
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        _printerConfigs = decoded.map((k, v) =>
            MapEntry(k, Map<String, String>.from(v as Map)));
      } catch (e) {
        _log('[ApiService] 解析打印机配置失败: $e');
        _printerConfigs = {};
      }
    }
  }

  // ── 保存所有打印机的 API 配置到 SharedPreferences ──
  Future<void> _savePrinterConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_configs', jsonEncode(_printerConfigs));
  }

  // ── 连接 BLE 打印机后自动加载其 API 配置 ──
  Future<void> loadConfigForPrinter(String mac) async {
    if (!_printerConfigs.containsKey(mac)) {
      _log('[ApiService] 打印机 $mac 无已保存的 API 配置');
      return;
    }
    await _applyPrinterConfig(mac);
  }

  // ── 应用指定打印机的配置到当前会话 ──
  Future<void> _applyPrinterConfig(String mac) async {
    final cfg = _printerConfigs[mac];
    if (cfg == null) return;

    stopHeartbeat();

    _baseUrl = cfg['base_url'] ?? '';
    _deviceId = cfg['device_id'] ?? '';
    _storeId = cfg['store_id'] ?? '';
    _deviceKey = cfg['device_key'] ?? '';

    // 恢复 MQTT 推送开关（每台独立）
    _mqttEnabled = cfg['mqtt_enabled'] == 'true';

    // 同步全局配置
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_base_url', _baseUrl);
    await prefs.setString('api_device_id', _deviceId);
    await prefs.setString('api_store_id', _storeId);
    await prefs.setString('api_device_key', _deviceKey);

    _isConfigured = _baseUrl.isNotEmpty && _deviceId.isNotEmpty && _deviceKey.isNotEmpty;
    _lastError = null;

    // 恢复 MQTT 参数（若已保存），并更新订阅门店 ID
    final mqtt = MqttPushService.instance;
    if (cfg['mqtt_username']?.isNotEmpty == true) {
      mqtt.applyConfig(cfg);
    }
    if (_storeId.isNotEmpty) {
      mqtt.updateStoreId(_storeId);
    }

    // 按保存的开关状态恢复 MQTT 连接
    if (_mqttEnabled && _storeId.isNotEmpty) {
      await mqtt.setEnabled(true, storeId: _storeId);
    } else {
      await mqtt.setEnabled(false);
    }

    if (_isConfigured) {
      startHeartbeat();
    }
    _log('[ApiService] ✅ 已加载打印机 $mac 的 API 配置: device=$_deviceId store=$_storeId mqtt=$_mqttEnabled');
    notifyListeners();
  }

  /// 保存 API 配置。
  ///
  /// [mac] 指定关联的打印机 MAC。传 null 时回退到「当前打印机」。
  /// 每台打印机的配置独立存储，切换打印机时自动切换。
  Future<void> saveConfig({
    required String baseUrl,
    required String deviceId,
    required String storeId,
    required String deviceKey,
    String? mac,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    _deviceId = deviceId;
    _storeId = storeId;
    _deviceKey = deviceKey;
    _isConfigured = _baseUrl.isNotEmpty && _deviceId.isNotEmpty && _deviceKey.isNotEmpty;
    await prefs.setString('api_base_url', _baseUrl);
    await prefs.setString('api_device_id', _deviceId);
    await prefs.setString('api_store_id', _storeId);
    await prefs.setString('api_device_key', _deviceKey);

    // 同时保存到指定（或当前）BLE 打印机的配置中（按 MAC 索引）
    final ble = BleService.instance;
    final targetMac = (mac != null && mac.isNotEmpty) ? mac : ble.savedDeviceId;
    if (targetMac.isNotEmpty) {
      // 保留该 MAC 已有的 MQTT 参数和开关，仅更新 API 字段
      final existing = _printerConfigs[targetMac] ?? <String, String>{};
      _printerConfigs[targetMac] = {
        ...existing,
        'base_url': _baseUrl,
        'device_id': _deviceId,
        'store_id': _storeId,
        'device_key': _deviceKey,
      };
      await _savePrinterConfigs();
      _log('[ApiService] 💾 已将配置关联到打印机 $targetMac');
    }

    // 更新 MQTT 订阅的门店 ID
    if (_storeId.isNotEmpty) {
      MqttPushService.instance.updateStoreId(_storeId);
    }

    // 保存后自动启动心跳
    if (_isConfigured) {
      startHeartbeat();
    }
    notifyListeners();
  }

  /// 获取某台打印机已保存的 API 配置（供设置页回显）
  Map<String, String>? getPrinterConfig(String mac) => _printerConfigs[mac];

  /// 保存 MQTT 参数到指定打印机的配置（按 MAC 索引）
  Future<void> saveMqttParamsForMac(String mac, Map<String, dynamic> mqtt) async {
    if (mac.isEmpty) return;
    final existing = _printerConfigs[mac] ?? <String, String>{};
    _printerConfigs[mac] = {
      ...existing,
      'broker_host': mqtt['broker_host']?.toString() ?? '',
      'broker_port': mqtt['broker_port']?.toString() ?? '',
      'mqtt_username': mqtt['mqtt_username']?.toString() ?? '',
      'mqtt_password': mqtt['mqtt_password']?.toString() ?? '',
      'subscribe_topic': mqtt['subscribe_topic']?.toString() ?? '',
      'publish_topic': mqtt['publish_topic']?.toString() ?? '',
      'tls_enabled': (mqtt['tls_enabled'] == true ||
              mqtt['tls_enabled']?.toString() == 'true' ||
              mqtt['tls_enabled'] == 1)
          ? 'true'
          : 'false',
    };
    await _savePrinterConfigs();
  }

  // ── 从 IoT 设备管理 API 拉取 BLE 打印机的 MQTT 配置 ──
  Future<bool> fetchBleConfig(String deviceKey, {String? mac}) async {
    if (_baseUrl.isEmpty) {
      _lastError = '请先配置服务器地址';
      return false;
    }
    try {
      final uri = Uri.parse('$_baseUrl/api/iot/ble/config/$deviceKey');
      final response = await http.get(uri).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          // 提取 API 配置字段
          _deviceId = data['device_id']?.toString() ?? '';
          _storeId = data['store_id']?.toString() ?? '';

          // 同步到 SharedPreferences
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('api_device_id', _deviceId);
          await prefs.setString('api_store_id', _storeId);

          _isConfigured = _baseUrl.isNotEmpty && _deviceId.isNotEmpty && _deviceKey.isNotEmpty;
          _lastError = null;

          // 注入 MQTT 配置
          await MqttPushService.instance.configure(data);

          // 将 MQTT 参数持久化到对应打印机的配置中（每台独立）
          final ble = BleService.instance;
          final targetMac = (mac != null && mac.isNotEmpty) ? mac : ble.savedDeviceId;
          if (targetMac.isNotEmpty) {
            await saveMqttParamsForMac(targetMac, data);
            _log('[ApiService] 💾 已将 MQTT 参数关联到打印机 $targetMac');
          }

          _log('[ApiService] ✅ 已从服务器拉取 BLE 配置: device=$_deviceId store=$_storeId');
          notifyListeners();
          return true;
        }
      }
      _lastError = '拉取配置失败: ${response.statusCode}';
      return false;
    } catch (e) {
      _lastError = '网络错误: $e';
      return false;
    }
  }

  // ── 心跳保活（仅心跳，不轮询）──
  void startHeartbeat() {
    if (!_isConfigured || _heartbeatRunning) return;
    _heartbeatRunning = true;
    _log('[ApiService] 💓 启动心跳保活: $_baseUrl device=$_deviceId store=$_storeId');

    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 60), (_) => _doHeartbeat());

    // 立即心跳一次
    _doHeartbeat();
    notifyListeners();
  }

  void stopHeartbeat() {
    _heartbeatRunning = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _isServerConnected = false;
    _pendingJobCount = 0;
    _log('[ApiService] ⏹ 停止心跳保活');
    notifyListeners();
  }

  // ── MQTT 推送开关（设置中开启/关闭）──
  Future<void> setMqttEnabled(bool enabled, {String? mac}) async {
    _mqttEnabled = enabled;
    // 持久化到对应打印机（每台独立）
    final ble = BleService.instance;
    final targetMac = (mac != null && mac.isNotEmpty) ? mac : ble.savedDeviceId;
    if (targetMac.isNotEmpty) {
      final existing = _printerConfigs[targetMac] ?? <String, String>{};
      _printerConfigs[targetMac] = {
        ...existing,
        'mqtt_enabled': enabled ? 'true' : 'false',
      };
      await _savePrinterConfigs();
    }
    if (enabled && _storeId.isNotEmpty) {
      await MqttPushService.instance.setEnabled(true, storeId: _storeId);
    } else {
      await MqttPushService.instance.setEnabled(false);
    }
    notifyListeners();
  }

  // ── 内部心跳 ──
  Future<void> _doHeartbeat() async {
    final ok = await bindDevice();
    if (ok) {
      _lastHeartbeat = DateTime.now();
      _isServerConnected = true;
    } else {
      // 超过 3 分钟无心跳标记离线
      if (_lastHeartbeat != null &&
          DateTime.now().difference(_lastHeartbeat!) > const Duration(seconds: 180)) {
        _isServerConnected = false;
      }
    }
    notifyListeners();
  }

  // ── 拉取并打印（MQTT 推送触发 / 手动拉取按钮）──
  Future<void> fetchAndPrint() async {
    if (_isProcessing) return;

    _isProcessing = true;
    try {
      // 无论蓝牙是否连接，先拉取任务刷新待打印计数（UI 可见）
      final jobs = await fetchPendingJobs();
      _pendingJobCount = jobs.length;
      notifyListeners();

      if (jobs.isEmpty) return;

      // BLE 未连接：先尝试按需自动重连，成功后再打印（被动+按需策略）
      if (BleService.instance.state != BleState.connected) {
        _log('[ApiService] ⚠ 有 ${jobs.length} 个待打印任务，蓝牙未连接，尝试自动重连...');
        final reconnected = await BleService.instance.ensureConnected();
        if (!reconnected) {
          _log('[ApiService] ❌ 自动重连失败，保留 ${jobs.length} 个任务等待下次触发');
          return;
        }
        _log('[ApiService] ✅ 自动重连成功，继续打印 ${jobs.length} 个任务');
      }

      _log('[ApiService] 📥 自动拉取到 ${jobs.length} 个待打印任务');

      for (final job in jobs) {
        try {
          PrintTask task;

          if (job.printData.isNotEmpty) {
            // 纯桥接主路径：后端已渲染好 ESC/POS 字节流（base64），直接发送
            task = PrintTask(
              data: '',
              textData: job.printData,
              copies: job.copies,
            );
          } else {
            // 兼容旧后端：无预渲染数据时回退 HTTP 渲染
            final labelData = await renderLabel(job.productData);
            if (labelData == null) {
              // 渲染失败必须标记失败，否则任务永久 pending 卡死队列
              await markJobFailed(job.jobId);
              _log('[ApiService] ❌ job#${job.jobId} 渲染失败，已标记失败');
              continue;
            }
            task = PrintTask(
              data: labelData['escpos_data'] ?? '',
              textData: labelData['text_data'] as String?,
              fallbackData: labelData['esc_star_data'],
              rawPixels: labelData['raw_pixels'] as Uint8List?,
              widthPx: labelData['width_px'] as int?,
              heightPx: labelData['height_px'] as int?,
              bytesPerRow: labelData['bytes_per_row'] as int?,
              copies: job.copies,
            );
          }

          final result = await BleService.instance.sendPrintData(task);

          if (result.status == PrintTaskStatus.completed) {
            await markJobComplete(job.jobId);
            HttpPrintServer.instance.addTask(result);
            _log('[ApiService] ✅ job#${job.jobId} 打印完成');
          } else {
            // 标记为失败，避免无限重试导致状态来回切换
            await markJobFailed(job.jobId);
            _log('[ApiService] ❌ job#${job.jobId} 打印失败已标记: ${result.error}');
          }
        } catch (e) {
          // 单任务异常隔离：不让一个任务的异常阻塞整个队列
          _log('[ApiService] ❌ job#${job.jobId} 处理异常: $e');
          try {
            await markJobFailed(job.jobId);
          } catch (_) {}
        }
      }

      // 再次拉取更新计数
      final remaining = await fetchPendingJobs();
      _pendingJobCount = remaining.length;
      notifyListeners();
    } catch (e) {
      _log('[ApiService] fetchAndPrint 异常: $e');
    } finally {
      _isProcessing = false;
    }
  }

  // ── 绑定设备（心跳/上线通知） ──
  Future<bool> bindDevice() async {
    if (!_isConfigured) {
      _lastError = '请先配置服务器地址和设备 ID';
      return false;
    }
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/iot/ble-device/bind'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'device_id': _deviceId,
          'device_key': _deviceKey,
          'app_version': '1.0.0',
        }),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _lastError = null;
        return data['success'] == true;
      }
      _lastError = '绑定失败: ${response.statusCode}';
      return false;
    } catch (e) {
      _lastError = '网络错误: $e';
      return false;
    }
  }

  // ── 拉取待打印任务 ──
  Future<List<BlePrintJob>> fetchPendingJobs() async {
    if (!_isConfigured) {
      _lastError = '请先配置服务器地址和设备 ID';
      return [];
    }
    try {
      final uri = Uri.parse('$_baseUrl/api/iot/ble-jobs').replace(
        queryParameters: {
          'store_id': _storeId,
          'device_key': _deviceKey,
        },
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final jobs = (data['jobs'] as List? ?? [])
            .map((j) => BlePrintJob.fromJson(j))
            .toList();
        _lastError = null;
        return jobs;
      }
      _lastError = '获取任务失败: ${response.statusCode}';
      return [];
    } catch (e) {
      _lastError = '网络错误: $e';
      return [];
    }
  }

  // ── 渲染标签位图（获取 ESC/POS base64 + ESC * 回退数据 + 原始位图）──
  Future<Map<String, dynamic>?> renderLabel(Map<String, dynamic> productData) async {
    if (!_isConfigured) return null;
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/iot/ble-label-render'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'product_data': productData,
          'device_key': _deviceKey,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          final result = <String, dynamic>{
            'escpos_data': data['escpos_data'] as String? ?? '',
            'esc_star_data': data['esc_star_data'] as String?,
            'text_data': data['text_data'] as String?,   // 纯文本标签（佳博小票机用）
          };

          // 解析原始位图（供 NIIMBOT 等非 ESC/POS 协议使用）
          final rawBitmap = data['raw_bitmap'];
          if (rawBitmap != null && rawBitmap is Map<String, dynamic>) {
            final pixelsB64 = rawBitmap['pixels_b64'] as String?;
            if (pixelsB64 != null && pixelsB64.isNotEmpty) {
              result['raw_pixels'] = base64Decode(pixelsB64);
              result['width_px'] = rawBitmap['width'] as int?;
              result['height_px'] = rawBitmap['height'] as int?;
              result['bytes_per_row'] = rawBitmap['bytes_per_row'] as int?;
            }
          }
          return result;
        }
      }
      _log('[ApiService] 渲染失败: ${response.statusCode}');
      return null;
    } catch (e) {
      _log('[ApiService] 渲染异常: $e');
      return null;
    }
  }

  // ── 标记任务完成 ──
  Future<bool> markJobComplete(int jobId) async {
    if (!_isConfigured) return false;
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/iot/ble-job/complete'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'job_id': jobId,
          'device_key': _deviceKey,
        }),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['success'] == true;
      }
      return false;
    } catch (e) {
      _log('[ApiService] 标记完成失败: $e');
      return false;
    }
  }

  // ── 标记任务失败（避免无限重试）──
  Future<bool> markJobFailed(int jobId) async {
    if (!_isConfigured) return false;
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/iot/ble-job/fail'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'job_id': jobId,
          'device_key': _deviceKey,
        }),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['success'] == true;
      }
      return false;
    } catch (e) {
      _log('[ApiService] 标记失败出错: $e');
      return false;
    }
  }
}

/// BLE 打印任务数据模型
class BlePrintJob {
  final int jobId;
  final String deviceId;
  final Map<String, dynamic> productData;
  final int copies;
  final String printData; // 后端预渲染 ESC/POS 字节流（base64），非空时纯桥接直发
  final String? createdAt;

  BlePrintJob({
    required this.jobId,
    required this.deviceId,
    required this.productData,
    required this.copies,
    this.printData = '',
    this.createdAt,
  });

  factory BlePrintJob.fromJson(Map<String, dynamic> json) {
    return BlePrintJob(
      // 兼容后端历史字段名：优先 job_id，回退 id（旧后端只返回 id）
      jobId: json['job_id'] ?? json['id'] ?? 0,
      deviceId: json['device_id'] ?? '',
      productData: Map<String, dynamic>.from(json['product_data'] ?? {}),
      copies: json['copies'] ?? 1,
      printData: json['print_data']?.toString() ?? '',
      createdAt: json['created_at'],
    );
  }

  String get productName =>
      productData['product_name']?.toString() ??
      productData['name']?.toString() ??
      '未知产品';

  @override
  String toString() => 'BlePrintJob#$jobId: $productName ×$copies';
}
