/// 打印任务数据模型
class PrintTask {
  /// Base64编码的打印字节流 (GS v 0 主指令)
  final String data;

  /// ESC * 回退数据（GS v 0 打印失败时自动尝试）
  final String? fallbackData;

  /// 打印份数
  final int copies;

  /// 接收时间
  final DateTime receivedAt;

  /// 任务状态
  PrintTaskStatus status;

  /// 完成时间
  DateTime? completedAt;

  /// 错误信息
  String? error;

  /// 是否使用了回退指令打印
  bool usedFallback = false;

  PrintTask({
    required this.data,
    this.fallbackData,
    this.copies = 1,
    DateTime? receivedAt,
    this.status = PrintTaskStatus.pending,
  }) : receivedAt = receivedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'data': data,
        'fallbackData': fallbackData,
        'copies': copies,
        'receivedAt': receivedAt.toIso8601String(),
        'status': status.name,
        'completedAt': completedAt?.toIso8601String(),
        'error': error,
        'usedFallback': usedFallback,
      };
}

enum PrintTaskStatus {
  pending('等待打印'),
  printing('打印中'),
  completed('已完成'),
  failed('失败');

  final String label;
  const PrintTaskStatus(this.label);
}
