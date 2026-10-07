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

import '../core/reminder_text.dart';
import '../data/models.dart';
import '../domain/medication_course.dart';

class NotificationService {
  NotificationService._();
  @visibleForTesting
  NotificationService.forTesting();

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
      onDidReceiveNotificationResponse: _onResponse,
    );

    _inited = true;
  }

  /// 通知被点击时的回调。由 main.dart 注入 —— 服务层不认识 Navigator，
  /// 只负责把 payload（提醒 id）交出去。
  ///
  /// 用静态字段而不是构造参数：通知可能在 App **完全没启动**时被点开，
  /// 那时引擎刚起来，回调注册必须简单可靠。
  static void Function(String reminderId)? onReminderTapped;

  static void _onResponse(NotificationResponse resp) {
    final payload = (resp.payload ?? '').trim();
    if (payload.isEmpty) return;
    onReminderTapped?.call(payload);
  }

  /// App 是被点通知拉起来的吗？是的话返回 payload。
  ///
  /// 冷启动场景：onDidReceiveNotificationResponse 在 initialize 之前就
  /// 已经发生过了，光靠回调会漏掉这一次点击，必须主动查一次。
  Future<String?> launchPayload() async {
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp != true) return null;
      final payload = (details?.notificationResponse?.payload ?? '').trim();
      return payload.isEmpty ? null : payload;
    } catch (_) {
      return null;
    }
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
    try { await init(); } catch (e) {
      debugPrint('notification initialization failed: $e');
      return false;
    }

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
      await init();
      final course = MedicationCourse.fromReminder(reminder);
      if (course != null) {
        // Queue independent slots so a missed confirmation does not suppress
        // the next reminder. Keep headroom under iOS's pending-request limit.
        await cancel(reminder.id);
        final pending = await _plugin.pendingNotificationRequests();
        final available = (60 - pending.length).clamp(0, 32);
        final now = DateTime.now();
        final slots = course.upcomingSlots(nextAt.isAfter(now) ? nextAt : now,
            limit: available);
        for (final slot in slots) {
          await _plugin.zonedSchedule(
            _stableId('${reminder.id}_${slot.millisecondsSinceEpoch}'),
            _titleOf(reminder),
            [if (petName != null) petName, course.dose].join(' · '),
            tz.TZDateTime.from(slot, tz.local), details,
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
            uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
            payload: reminder.id,
          );
        }
        return;
      }
      await _plugin.zonedSchedule(
        _stableId(reminder.id),
        _titleOf(reminder),
        petName,
        tz.TZDateTime.from(nextAt, tz.local),
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        // payload 只放提醒 id，不放宠物名之类的展示信息 ——
        // 那些会过期（改了名字就对不上），id 永远能查到最新状态。
        payload: reminder.id,
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
    try {
      await init();
      await _plugin.cancel(_stableId(reminderId));
      // A course schedules multiple slots, all with this reminder payload.
      for (final request in await _plugin.pendingNotificationRequests()) {
        if (request.payload == reminderId) await _plugin.cancel(request.id);
      }
    } catch (_) {
      // 忽略：取消失败不影响数据。
    }
  }

  Future<void> cancelAll() async {
    try {
      await init();
      await _plugin.cancelAll();
    } catch (e) {
      debugPrint('cancel notifications failed: $e');
    }
  }

  /// 通知标题。解析规则与列表页完全一致（core/reminder_text.dart）——
  /// 两处各写一份的话，会出现「列表里是『疫苗』、通知栏是 plan.vaccine.core」。
  static String _titleOf(Reminder reminder) =>
      reminderTitleFrom(reminder.title, reminder.type);

  /// 通知 id 必须是 32 位 int。用 uuid 的稳定哈希。
  static int _stableId(String uuid) {
    var h = 0;
    for (final c in uuid.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h;
  }
}
