import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/print_task.dart';
import 'ble_service.dart';
import 'http_server.dart';

/// 服务器 API 客户端 — BluPrint 拉取 BLE 打印任务
/// 支持自动心跳（保持设备在线）+ 自动轮询（拉取并打印待处理任务）
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

  // ── 自动轮询状态 ──
  bool _isServerConnected = false;
  bool get isServerConnected => _isServerConnected;

  int _pendingJobCount = 0;
  int get pendingJobCount => _pendingJobCount;

  DateTime? _lastHeartbeat;
  DateTime? get lastHeartbeat => _lastHeartbeat;

  bool _autoPolling = false;
  bool get autoPolling => _autoPolling;

  Timer? _heartbeatTimer;
  Timer? _pollTimer;
  bool _isProcessing = false;

  // ── 初始化 ──
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString('api_base_url') ?? '';
    _deviceId = prefs.getString('api_device_id') ?? '';
    _storeId = prefs.getString('api_store_id') ?? '';
    _deviceKey = prefs.getString('api_device_key') ?? '';
    _isConfigured = _baseUrl.isNotEmpty && _deviceId.isNotEmpty;

    // 已配置则自动启动轮询
    if (_isConfigured) {
      startAutoPoll();
    }
    notifyListeners();
  }

  Future<void> saveConfig({
    required String baseUrl,
    required String deviceId,
    required String storeId,
    required String deviceKey,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    _deviceId = deviceId;
    _storeId = storeId;
    _deviceKey = deviceKey;
    _isConfigured = _baseUrl.isNotEmpty && _deviceId.isNotEmpty;
    await prefs.setString('api_base_url', _baseUrl);
    await prefs.setString('api_device_id', _deviceId);
    await prefs.setString('api_store_id', _storeId);
    await prefs.setString('api_device_key', _deviceKey);

    // 保存后自动启动轮询
    if (_isConfigured) {
      startAutoPoll();
    }
    notifyListeners();
  }

  // ── 启动 / 停止自动轮询 ──
  void startAutoPoll() {
    if (!_isConfigured || _autoPolling) return;
    _autoPolling = true;
    debugPrint('[ApiService] 🚀 启动自动轮询: $_baseUrl device=$_deviceId store=$_storeId');

    // 心跳定时器（每 60 秒保持在线）
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 60), (_) => _doHeartbeat());

    // 轮询定时器（每 10 秒检查待打印任务）
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) => _autoFetchAndPrint());

    // 立即执行一次
    _doHeartbeat();
    _autoFetchAndPrint();
    notifyListeners();
  }

  void stopAutoPoll() {
    _autoPolling = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    _isServerConnected = false;
    _pendingJobCount = 0;
    debugPrint('[ApiService] ⏹ 停止自动轮询');
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

  // ── 自动拉取并打印 ──
  Future<void> _autoFetchAndPrint() async {
    if (_isProcessing) return;
    if (BleService.instance.state != BleState.connected) return; // BLE 未连接跳过

    _isProcessing = true;
    try {
      final jobs = await fetchPendingJobs();
      _pendingJobCount = jobs.length;
      notifyListeners();

      if (jobs.isEmpty) return;
      debugPrint('[ApiService] 📥 自动拉取到 ${jobs.length} 个待打印任务');

      for (final job in jobs) {
        // 渲染标签位图
        final escposBase64 = await renderLabel(job.productData);
        if (escposBase64 == null) {
          debugPrint('[ApiService] ⚠ 渲染失败，跳过 job#${job.jobId}');
          continue;
        }

        // 创建打印任务通过 BLE 发送
        final task = PrintTask(data: escposBase64, copies: job.copies);
        final result = await BleService.instance.sendPrintData(task);

        if (result.status == PrintTaskStatus.completed) {
          await markJobComplete(job.jobId);
          HttpPrintServer.instance.addTask(result);
          debugPrint('[ApiService] ✅ job#${job.jobId} 打印完成');
        } else {
          debugPrint('[ApiService] ❌ job#${job.jobId} 打印失败: ${result.error}');
        }
      }

      // 再次拉取更新计数
      final remaining = await fetchPendingJobs();
      _pendingJobCount = remaining.length;
      notifyListeners();
    } catch (e) {
      debugPrint('[ApiService] 自动轮询异常: $e');
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

  // ── 渲染标签位图（获取 ESC/POS base64）──
  Future<String?> renderLabel(Map<String, dynamic> productData) async {
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
          return data['escpos_data'] as String?;
        }
      }
      debugPrint('[ApiService] 渲染失败: ${response.statusCode}');
      return null;
    } catch (e) {
      debugPrint('[ApiService] 渲染异常: $e');
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
      debugPrint('[ApiService] 标记完成失败: $e');
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
  final String? createdAt;

  BlePrintJob({
    required this.jobId,
    required this.deviceId,
    required this.productData,
    required this.copies,
    this.createdAt,
  });

  factory BlePrintJob.fromJson(Map<String, dynamic> json) {
    return BlePrintJob(
      jobId: json['job_id'] ?? 0,
      deviceId: json['device_id'] ?? '',
      productData: Map<String, dynamic>.from(json['product_data'] ?? {}),
      copies: json['copies'] ?? 1,
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
