import 'dart:async';
import 'package:flutter/material.dart';
import '../services/ble_service.dart';
import '../services/http_server.dart';
import '../models/print_task.dart';

/// 打印页面 — 显示连接状态、日志、打印历史
class PrintPage extends StatefulWidget {
  const PrintPage({super.key});

  @override
  State<PrintPage> createState() => _PrintPageState();
}

class _PrintPageState extends State<PrintPage> {
  final BleService _ble = BleService.instance;
  final HttpPrintServer _server = HttpPrintServer.instance;
  StreamSubscription<PrintTask>? _taskSub;
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _ble.addListener(_onStateChanged);
    _taskSub = _server.taskStream.listen((task) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ble.removeListener(_onStateChanged);
    _taskSub?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  Color _statusColor() {
    switch (_ble.state) {
      case BleState.connected:
      case BleState.printing:
        return Colors.green;
      case BleState.connecting:
      case BleState.scanning:
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _server.tasks;
    return Scaffold(
      appBar: AppBar(
        title: const Text('SANJOYBLU打印中转'),
        centerTitle: true,
        actions: [
          if (tasks.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: '清空记录',
              onPressed: () {
                _server.clearTasks();
                setState(() {});
              },
            ),
        ],
      ),
      body: Column(
        children: [
          // ── 状态卡片 ──
          _buildStatusCard(),
          const Divider(height: 1),
          // ── 服务信息 ──
          _buildServerInfo(),
          const Divider(height: 1),
          // ── 打印历史 / 日志 ──
          Expanded(child: _buildLogSection(tasks)),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: _statusColor(),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: _statusColor().withOpacity(0.4),
                  blurRadius: 6,
                  spreadRadius: 2,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _ble.statusText,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                if (_ble.device != null)
                  Text(
                    '${_ble.device!.platformName}  (${_ble.device!.remoteId})',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          if (_ble.state == BleState.connected)
            TextButton.icon(
              onPressed: () => _ble.disconnect(),
              icon: const Icon(Icons.link_off, size: 18),
              label: const Text('断开'),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
            ),
        ],
      ),
    );
  }

  Widget _buildServerInfo() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Icon(
            _server.isRunning ? Icons.http : Icons.http_rounded,
            color: _server.isRunning ? Colors.green : Colors.grey,
            size: 18,
          ),
          const SizedBox(width: 8),
          Text(
            _server.isRunning
                ? 'HTTP 服务: http://127.0.0.1:${_server.port}'
                : 'HTTP 服务未启动: ${_server.lastError}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const Spacer(),
          if (!_server.isRunning)
            TextButton.icon(
              onPressed: () async {
                await _server.start();
                setState(() {});
              },
              icon: const Icon(Icons.play_arrow, size: 16),
              label: const Text('启动'),
            ),
        ],
      ),
    );
  }

  Widget _buildLogSection(List<PrintTask> tasks) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Row(
            children: [
              Text(
                '打印记录',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const Spacer(),
              Text(
                '共 ${tasks.length} 条',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        Expanded(
          child: tasks.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.inbox_outlined,
                          size: 48,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.3)),
                      const SizedBox(height: 8),
                      Text(
                        '等待接收打印任务...',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withOpacity(0.5),
                            ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Web 端示例: POST http://127.0.0.1:${_server.port}/print',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withOpacity(0.4),
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Body: {"data": "<base64>", "copies": 1}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withOpacity(0.4),
                              fontFamily: 'monospace',
                            ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: tasks.length,
                  itemBuilder: (context, i) => _buildTaskCard(tasks[i]),
                ),
        ),
      ],
    );
  }

  Widget _buildTaskCard(PrintTask task) {
    final isCompleted = task.status == PrintTaskStatus.completed;
    final isFailed = task.status == PrintTaskStatus.failed;

    Color chipColor;
    switch (task.status) {
      case PrintTaskStatus.pending:
        chipColor = Colors.orange;
        break;
      case PrintTaskStatus.printing:
        chipColor = Colors.blue;
        break;
      case PrintTaskStatus.completed:
        chipColor = Colors.green;
        break;
      case PrintTaskStatus.failed:
        chipColor = Colors.red;
        break;
    }

    final timeStr =
        '${task.receivedAt.hour.toString().padLeft(2, '0')}:${task.receivedAt.minute.toString().padLeft(2, '0')}:${task.receivedAt.second.toString().padLeft(2, '0')}';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        dense: true,
        leading: Icon(
          isCompleted
              ? Icons.check_circle
              : isFailed
                  ? Icons.error
                  : task.status == PrintTaskStatus.printing
                      ? Icons.print
                      : Icons.schedule,
          color: chipColor,
        ),
        title: Text(
          isCompleted
              ? '打印完成'
              : isFailed
                  ? '打印失败'
                  : '${task.status.label}',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        subtitle: Text(
          isFailed && task.error != null
              ? '$timeStr — ${task.data.length ~/ 1.33} 字节 · ${task.copies}份 · ${task.error}'
              : '$timeStr — ${task.data.length ~/ 1.33} 字节 · ${task.copies}份',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: isCompleted
            ? Text(
                '✓',
                style: TextStyle(
                    color: Colors.green,
                    fontWeight: FontWeight.bold,
                    fontSize: 18),
              )
            : null,
      ),
    );
  }
}
