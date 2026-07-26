import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 全局诊断日志单例。
/// 汇聚 BLE / API / UI 打印链路的关键标记，支持内存查看、复制、导出为 txt。
class AppLog extends ChangeNotifier {
  static final AppLog instance = AppLog._();
  AppLog._();

  static const int _max = 600;
  final List<LogRecord> _records = [];

  /// 只读快照（最新在前）
  List<LogRecord> get records => List.unmodifiable(_records);

  void d(String module, String msg) => _add(module, 'DEBUG', msg);
  void i(String module, String msg) => _add(module, 'INFO', msg);
  void w(String module, String msg) => _add(module, 'WARN', msg);
  void e(String module, String msg) => _add(module, 'ERROR', msg);

  void _add(String module, String level, String msg) {
    _records.insert(0, LogRecord(DateTime.now(), module, level, msg));
    if (_records.length > _max) _records.removeLast();
    notifyListeners();
  }

  void clear() {
    _records.clear();
    notifyListeners();
  }

  /// 拼接为可读文本（用于复制 / 导出）
  String get text {
    final buf = StringBuffer();
    buf.writeln('SANJOY 打印中转 App 诊断日志');
    buf.writeln('生成时间: ${DateTime.now()}');
    buf.writeln('共 ${_records.length} 条记录');
    buf.writeln('${'-' * 48}');
    // 旧→新 顺序输出，便于从头阅读
    for (final r in _records.reversed) {
      buf.writeln('[${_ts(r.time)}] [${r.level}] [${r.module}] ${r.msg}');
    }
    return buf.toString();
  }

  static String _ts(DateTime t) =>
      '${t.year}-${_pad(t.month)}-${_pad(t.day)} ${_pad(t.hour)}:${_pad(t.minute)}:${_pad(t.second)}';
  static String _pad(int n) => n.toString().padLeft(2, '0');

  /// 导出为 txt 文件，返回保存路径
  Future<String> exportToFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final now = DateTime.now();
    final name =
        'bluprint_log_${now.year}${_pad(now.month)}${_pad(now.day)}_${_pad(now.hour)}${_pad(now.minute)}${_pad(now.second)}.txt';
    final file = File('${dir.path}/$name');
    await file.writeAsString(text);
    return file.path;
  }
}

class LogRecord {
  final DateTime time;
  final String module;
  final String level;
  final String msg;
  _LogRecord(this.time, this.module, this.level, this.msg);
}
