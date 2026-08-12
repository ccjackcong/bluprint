import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart' as mqtt;
import 'package:mqtt_client/mqtt_server_client.dart' as mqtt;
import 'app_log.dart';

/// MQTT 推送服务 — 订阅 BLE 打印任务通知
///
/// 连接到 sanjoyapp MQTT broker（TLS:8883），订阅 `sanjoy/ble/{store_id}/notify`，
/// 收到推送后回调 ApiService 拉取并打印任务，替代旧轮询方案。
class MqttPushService extends ChangeNotifier {
  static final MqttPushService instance = MqttPushService._();
  MqttPushService._();

  // ── 配置（动态注入，不再硬编码）──
  String _brokerHost = 'leestofu.cn';
  int _brokerPort = 8883;
  bool _tlsEnabled = true;
  String _username = '';
  String _password = '';
  String _subscribeTopic = '';
  String _publishTopic = '';

  /// 是否已从 API 获取过配置
  bool _configured = false;
  bool get isConfigured => _configured;

  // 公开只读 getters（供设置页展示已加载的配置）
  String get brokerHost => _brokerHost;
  int get brokerPort => _brokerPort;
  String get username => _username;
  String get subscribeTopic => _subscribeTopic;
  String get publishTopic => _publishTopic;

  mqtt.MqttServerClient? _client;
  bool _connected = false;
  bool get isConnected => _connected;

  String? _lastError;
  String? get lastError => _lastError;

  DateTime? _lastNotification;
  DateTime? get lastNotification => _lastNotification;

  // 自动重连
  Timer? _reconnectTimer;
  bool _shouldReconnect = true;
  bool _enabled = false; // 默认关闭，用户在设置中开启
  bool get isEnabled => _enabled;

  String _storeId = '';
  String? _currentTopic;

  // 收到通知后的回调
  void Function()? onNotify;

  void _log(String m) {
    debugPrint('[MqttPush] $m');
    AppLog.instance.d('MQTT', m);
  }

  // ── 从 API 配置 MQTT 连接参数 ──
  Future<void> configure(Map<String, dynamic> config) async {
    _brokerHost = config['broker_host']?.toString() ?? 'leestofu.cn';
    _brokerPort = int.tryParse(config['broker_port']?.toString() ?? '') ?? 8883;
    _username = config['mqtt_username']?.toString() ?? '';
    _password = config['mqtt_password']?.toString() ?? '';
    _subscribeTopic = config['subscribe_topic']?.toString() ?? '';
    _publishTopic = config['publish_topic']?.toString() ?? '';
    if (config['store_id'] != null) _storeId = config['store_id'].toString();
    // TLS：服务器下发 true/false/1/0 均可
    final tlsVal = config['tls_enabled'];
    _tlsEnabled = tlsVal == true || tlsVal?.toString() == 'true' || tlsVal == 1;
    _configured = true;
    _log('⚙ 已加载 MQTT 配置: host=$_brokerHost port=$_brokerPort tls=$_tlsEnabled user=$_username topic=$_subscribeTopic store=$_storeId');
  }

  // ── 启用 / 禁用 ──
  Future<void> setEnabled(bool enabled, {String storeId = ''}) async {
    _enabled = enabled;
    if (storeId.isNotEmpty) _storeId = storeId;
    if (enabled && _storeId.isNotEmpty && _configured) {
      await connect();
    } else if (enabled && !_configured) {
      _log('⚠ MQTT 已启用但尚未配置，请先在设置中绑定 BLE 设备');
    } else {
      await disconnect();
    }
    notifyListeners();
  }

  void updateStoreId(String storeId) {
    if (_storeId == storeId) return;
    _storeId = storeId;
    if (_enabled) {
      // 换门店需要重新订阅
      disconnect().then((_) => connect());
    }
  }

  // ── 连接 ──
  Future<void> connect() async {
    if (_client != null && _connected) {
      _log('已连接，跳过重复连接');
      return;
    }
    if (_storeId.isEmpty) {
      _log('storeId 为空，无法订阅');
      return;
    }

    _shouldReconnect = true;
    try {
      _client = mqtt.MqttServerClient.withPort(_brokerHost, 'bluprint_${_storeId}', _brokerPort);

      _client!.secure = _tlsEnabled;
      if (_tlsEnabled) {
        _client!.securityContext = SecurityContext.defaultContext;
      }
      _client!.onConnected = _onConnected;
      _client!.onDisconnected = _onDisconnected;
      _client!.onSubscribed = _onSubscribed;
      _client!.logging(on: false);

      final connMsg = mqtt.MqttConnectMessage()
          .withClientIdentifier('bluprint_${_storeId}_${DateTime.now().millisecondsSinceEpoch}')
          .authenticateAs(_username, _password)
          .withWillTopic('sanjoy/ble/${_storeId}/status')
          .withWillMessage('{"status":"offline","store_id":"$_storeId"}')
          .startClean()
          .keepAliveFor(60);

      _client!.connectionMessage = connMsg;

      await _client!.connect();
      _log('连接中...');
    } catch (e) {
      _log('连接失败: $e');
      _lastError = 'MQTT 连接失败: $e';
      _connected = false;
      notifyListeners();
      _scheduleReconnect();
    }
  }

  void _onConnected() {
    _connected = true;
    _lastError = null;
    _log('✅ 已连接到 broker ($_brokerHost:$_brokerPort)');
    _subscribeToStore();
    notifyListeners();
  }

  void _onDisconnected() {
    _connected = false;
    _log('⚠ 已断开连接');
    notifyListeners();
    if (_shouldReconnect && _enabled) {
      _scheduleReconnect();
    }
  }

  void _onSubscribed(String topic) {
    _log('📡 已订阅: $topic');
  }

  Future<void> _subscribeToStore() async {
    if (_client == null || !_connected || _storeId.isEmpty) return;

    final topic = _subscribeTopic.isNotEmpty ? _subscribeTopic : 'sanjoy/ble/$_storeId/notify';
    if (_currentTopic != null) {
      _client!.unsubscribe(_currentTopic!);
    }
    _client!.subscribe(topic, mqtt.MqttQos.atMostOnce);
    _currentTopic = topic;

    // 设置消息回调
    _client!.updates!.listen((List<mqtt.MqttReceivedMessage<mqtt.MqttPublishMessage>> messages) {
      for (final msg in messages) {
        _onMessage(msg.topic, msg.payload);
      }
    });
  }

  void _onMessage(String topic, mqtt.MqttPublishMessage payload) {
    try {
      final raw = const Utf8Decoder().convert(payload.payload.message);
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final jobId = data['job_id'];
      final ts = data['ts'];

      _lastNotification = DateTime.now();
      _log('📩 收到打印通知: job=$jobId topic=$topic ts=$ts');

      // 回调 ApiService 拉取并打印
      if (onNotify != null) {
        onNotify!();
      }
    } catch (e) {
      _log('消息解析失败: $e');
    }
  }

  // ── 断开 ──
  Future<void> disconnect() async {
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    try {
      _client?.disconnect();
    } catch (_) {}
    _client = null;
    _connected = false;
    _currentTopic = null;
    _log('⏹ 已断开');
    notifyListeners();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 15), () {
      if (_shouldReconnect && _enabled && _storeId.isNotEmpty) {
        _log('🔄 尝试重连...');
        connect();
      }
    });
  }

  // ── 释放资源 ──
  void disposeService() {
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    disconnect();
  }
}
