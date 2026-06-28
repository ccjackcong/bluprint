/// 打印任务数据模型
class PrintTask {
  /// Base64编码的打印字节流
  final String data;

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

  PrintTask({
    required this.data,
    this.copies = 1,
    DateTime? receivedAt,
    this.status = PrintTaskStatus.pending,
  }) : receivedAt = receivedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'data': data,
        'copies': copies,
        'receivedAt': receivedAt.toIso8601String(),
        'status': status.name,
        'completedAt': completedAt?.toIso8601String(),
        'error': error,
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
