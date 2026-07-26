import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/app_log.dart';

/// 诊断日志页面 — 实时查看全局日志、复制全部、导出为 txt
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    AppLog.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    AppLog.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Color _levelColor(String level) {
    switch (level) {
      case 'ERROR':
        return Colors.red;
      case 'WARN':
        return Colors.orange;
      case 'INFO':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: AppLog.instance.text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已复制全部日志到剪贴板'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _export() async {
    try {
      final path = await AppLog.instance.exportToFile();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已导出到: $path'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('导出失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final records = AppLog.instance.records;
    return Scaffold(
      appBar: AppBar(
        title: const Text('诊断日志'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: '复制全部',
            onPressed: records.isEmpty ? null : _copyAll,
          ),
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: '导出 txt',
            onPressed: records.isEmpty ? null : _export,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: '清空',
            onPressed: records.isEmpty
                ? null
                : () {
                    AppLog.instance.clear();
                  },
          ),
        ],
      ),
      body: records.isEmpty
          ? Center(
              child: Text(
                '暂无日志\n操作打印 / 连接后会自动记录',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.4),
                    ),
              ),
            )
          : ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.all(8),
              itemCount: records.length,
              itemBuilder: (context, i) {
                final r = records[i];
                final timeStr =
                    '${r.time.hour.toString().padLeft(2, '0')}:${r.time.minute.toString().padLeft(2, '0')}:${r.time.second.toString().padLeft(2, '0')}';
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        timeStr,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              color: Colors.grey,
                            ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: RichText(
                          text: TextSpan(
                            style: Theme.of(context).textTheme.bodySmall,
                            children: [
                              TextSpan(
                                text: '[${r.module}] ',
                                style: TextStyle(
                                  color: _levelColor(r.level),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              TextSpan(text: r.msg),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
