/// 本地通知。
///
/// MVP 决策：**不做服务端推送**。提醒时间客户端算得出来，
/// 省一台服务器，也省掉 FCM / APNs / 各厂商通道的证书折腾。
///
/// 双市场差异：本地通知不依赖区域，两边同一套代码。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/models.dart';

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _inited = false;

  static const String _channelId = 'pet_reminders';
  static const String _channelName = 'Pet reminders';

  Future<void> init() async {
    if (_inited) return;

    // zonedSchedule 依赖时区库，必须先加载。
    // latest_all 体积较大但覆盖全时区；海外版尤其需要。
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation(_localZoneName()));

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: (_) {},
    );

    _inited = true;
  }

  /// 本地时区名。取系统偏移对应的 IANA 名称，
  /// 取不到时用 UTC —— 比写死 Asia/Shanghai 更安全（海外版会跑错）。
  static String _localZoneName() {
    final offset = DateTime.now().timeZoneOffset;
    final name = DateTime.now().timeZoneName;
    // 常见简写直接映射，避免依赖原生插件。
    const alias = {
      'CST': 'Asia/Shanghai',
      'GMT': 'Etc/GMT',
      'UTC': 'UTC',
      'EST': 'America/New_York',
      'EDT': 'America/New_York',
      'PST': 'America/Los_Angeles',
      'PDT': 'America/Los_Angeles',
    };
    final mapped = alias[name];
    if (mapped != null) return mapped;
    // 兜底：按偏移挑一个代表城市。
    final hours = offset.inHours;
    return switch (hours) {
      8 => 'Asia/Shanghai',
      9 => 'Asia/Tokyo',
      0 => 'UTC',
      -5 => 'America/New_York',
      -8 => 'America/Los_Angeles',
      1 => 'Europe/Berlin',
      _ => 'UTC',
    };
  }

  /// 请求通知权限。
  ///
  /// **调用时机有讲究**：必须在用户看到第一条计划之后。
  /// 一进 App 就弹，授权率会掉一半。
  Future<bool> requestPermission() async {
    await init();

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      final granted = await android.requestNotificationsPermission();
      return granted ?? false;
    }

    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      final granted = await ios.requestPermissions(alert: true, badge: true, sound: true);
      return granted ?? false;
    }
    return false;
  }

  /// 调度一条提醒。
  ///
  /// [nextAt] 由调用方显式传入，避免时区/重算差异。
  /// [petName] 作为通知副标题，多宠家庭一眼知道是谁的待办。
  Future<void> schedule(
    Reminder reminder, {
    required DateTime nextAt,
    String? petName,
  }) async {
    await init();

    if (!reminder.enabled) {
      await cancel(reminder.id);
      return;
    }

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: 'Vaccine, deworming and checkup reminders',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );

    try {
      await _plugin.zonedSchedule(
        _stableId(reminder.id),
        _titleOf(reminder),
        petName,
        tz.TZDateTime.from(nextAt, tz.local),
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (e) {
      // 通知调度失败不能影响业务主流程：提醒数据已入库，UI 照常展示。
      debugPrint('schedule notification failed: $e');
    }
  }

  /// 批量重排。生成计划后调用。
  Future<void> rescheduleAll(
    List<Reminder> reminders, {
    String? petName,
  }) async {
    for (final r in reminders) {
      await schedule(r, nextAt: r.nextAt, petName: petName);
    }
  }

  Future<void> cancel(String reminderId) async {
    await init();
    try {
      await _plugin.cancel(_stableId(reminderId));
    } catch (_) {
      // 忽略：取消失败不影响数据。
    }
  }

  Future<void> cancelAll() async {
    await init();
    await _plugin.cancelAll();
  }

  /// 通知标题。reminders.title 里存的是 i18n key，交给调用方翻译后传入更佳；
  /// 这里做一次兜底，保证 key 缺失时也不会显示英文变量名。
  static String _titleOf(Reminder reminder) {
    final t = reminder.title;
    if (t.contains('.')) return t.split('.').last;
    return t;
  }

  /// 通知 id 必须是 32 位 int。用 uuid 的稳定哈希。
  static int _stableId(String uuid) {
    var h = 0;
    for (final c in uuid.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h;
  }
}
