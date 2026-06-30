import 'dart:typed_data';

/// 打印任务数据模型
class PrintTask {
  /// Base64编码的打印字节流 (GS v 0 主指令，ESC/POS 协议)
  final String data;

  /// 纯文本 ESC/POS 标签数据（佳博等不支持位图的小票机优先使用）
  final String? textData;

  /// ESC * 回退数据（GS v 0 打印失败时自动尝试）
  final String? fallbackData;

  /// 原始像素位图数据（PIL "1" mode：0=黑, 1=白, 行优先, MSB first）— 供 NIIMBOT 等非 ESC/POS 协议使用
  final Uint8List? rawPixels;

  /// 位图像素宽度
  final int? widthPx;

  /// 位图像素高度
  final int? heightPx;

  /// 每行字节数
  final int? bytesPerRow;

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
    this.textData,
    this.fallbackData,
    this.rawPixels,
    this.widthPx,
    this.heightPx,
    this.bytesPerRow,
    this.copies = 1,
    DateTime? receivedAt,
    this.status = PrintTaskStatus.pending,
  }) : receivedAt = receivedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'data': data,
        'textData': textData,
        'fallbackData': fallbackData,
        'rawPixels': rawPixels,
        'widthPx': widthPx,
        'heightPx': heightPx,
        'bytesPerRow': bytesPerRow,
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
