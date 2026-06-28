// lib/services/http_server.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';           // ⭐ 添加这一行，提供 HttpServer 类
import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import '../models/print_task.dart';
import 'ble_service.dart';

/// 本地 HTTP 打印服务器
/// 监听 127.0.0.1:15987，接收 Web 端 POST 的打印任务
class HttpPrintServer {
  static final HttpPrintServer instance = HttpPrintServer._();
  HttpPrintServer._();

  HttpServer? _server;
  bool _running = false;
  bool get isRunning => _running;

  int _port = 15987;
  int get port => _port;

  String _lastError = '';
  String get lastError => _lastError;

  /// 打印任务流（供 UI 监听）
  final StreamController<PrintTask> _taskController =
      StreamController<PrintTask>.broadcast();
  Stream<PrintTask> get taskStream => _taskController.stream;

  /// 接收到的任务列表
  final List<PrintTask> tasks = [];

  /// 启动 HTTP 服务器
  Future<bool> start({int? port}) async {
    if (_running) return true;
    if (port != null) _port = port;

    final router = Router();

    // ── POST /print ── 接收打印任务
    router.post('/print', (Request request) async {
      try {
        final body = await request.readAsString();
        final Map<String, dynamic> json = jsonDecode(body);

        final String data = json['data'] as String? ?? '';
        if (data.isEmpty) {
          return Response(400,
              body: jsonEncode({'error': '缺少打印数据 (data)'}),
              headers: {'Content-Type': 'application/json'});
        }

        final int copies = json['copies'] as int? ?? 1;

        final task = PrintTask(data: data, copies: copies);
        tasks.insert(0, task);
        if (tasks.length > 100) tasks.removeLast();
        _taskController.add(task);

        debugPrint('[HTTP] 收到打印任务: ${data.length} 字节, $copies 份');

        // ⭐ 修改点：异步触发打印，并捕获异常避免影响响应
        unawaited(
          BleService.instance.sendPrintData(task).then((result) {
            debugPrint('[HTTP] 打印结果: ${result.status.label}');
          }).catchError((e, stack) {
            debugPrint('[HTTP] 打印失败: $e\n$stack');
          }),
        );

        // 立即返回成功（打印异步进行）
        return Response(200,
            body: jsonEncode({
              'status': 'ok',
              'message': '打印任务已接收',
              'copies': copies,
            }),
            headers: {
              'Content-Type': 'application/json',
              'Access-Control-Allow-Origin': '*',
            });
      } catch (e) {
        // ⭐ 修改点：更详细的错误日志
        debugPrint('[HTTP] 请求处理异常: $e');
        return Response(400,
            body: jsonEncode({'error': '请求解析失败: $e'}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    // ── GET /status ── 查询打印机状态
    router.get('/status', (Request request) {
      final ble = BleService.instance;
      // ⭐ 修改点：增加对设备信息的空安全处理
      final deviceName = ble.device?.platformName ?? '';
      final deviceId = ble.device?.remoteId.toString() ?? '';
      return Response.ok(
        jsonEncode({
          'http_server': 'running',
          'ble_state': ble.state.name,
          'ble_status': ble.statusText,
          'ble_device': deviceName,
          'ble_device_id': deviceId,
          'task_count': tasks.length,
        }),
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*',
        },
      );
    });

    // ── CORS 预检 ──
    // ⭐ 修改点：使用更通用的路径匹配方式
    router.add('OPTIONS', '/<.*>', (Request request) {
      return Response(200, headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type',
      });
    });

    try {
      _server = await io.serve(router, '127.0.0.1', _port);
      _running = true;
      _lastError = '';
      debugPrint('[HTTP] 打印服务器已启动: http://127.0.0.1:$_port');
      return true;
    } catch (e) {
      _running = false;
      _lastError = e.toString();
      debugPrint('[HTTP] 启动失败: $e');
      return false;
    }
  }

  /// 停止 HTTP 服务器
  Future<void> stop() async {
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
    }
    _running = false;
    debugPrint('[HTTP] 打印服务器已停止');
  }

  /// 清空任务历史
  void clearTasks() {
    tasks.clear();
  }

  void dispose() {
    stop();
    _taskController.close();
  }
}
