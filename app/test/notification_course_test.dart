import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/data/models.dart';
import 'package:pet_app/domain/medication_course.dart';
import 'package:pet_app/services/notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final pending = <Map<String, Object?>>[];
  final scheduled = <Map<dynamic, dynamic>>[];
  late NotificationService service;
  late Reminder reminder;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    service = NotificationService.forTesting();
    pending.clear();
    scheduled.clear();
    final day =
        MedicationCourse.day(DateTime.now()).add(const Duration(days: 1));
    final course = MedicationCourse(
        name: 'Medicine',
        dose: '0.5 ml',
        start: day,
        end: day.add(const Duration(days: 6)),
        times: [540, 1200]);
    reminder = Reminder(
        id: 'course',
        petId: 'pet',
        type: 'medication',
        title: course.name,
        rule: course.toRule(),
        nextAt: course.nextAt(day)!,
        createdAt: day,
        updatedAt: day);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'initialize':
          return true;
        case 'pendingNotificationRequests':
          return pending.toList();
        case 'cancel':
          final id = call.arguments is Map
              ? (call.arguments as Map)['id']
              : call.arguments;
          pending.removeWhere((r) => r['id'] == id);
          return null;
        case 'cancelAll':
          pending.clear();
          return null;
        case 'zonedSchedule':
          final args = Map<dynamic, dynamic>.from(call.arguments as Map);
          scheduled.add(args);
          pending.add({
            'id': args['id'],
            'title': args['title'],
            'body': args['body'],
            'payload': args['payload']
          });
          return null;
        default:
          return null;
      }
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
      'all daily slots are queued; cancel removes every course slot and preserves other reminders',
      () async {
    pending.addAll([
      {'id': 777, 'payload': 'other'},
      {'id': 888, 'payload': 'course'}
    ]);
    await service.schedule(reminder, nextAt: reminder.nextAt, petName: 'Buddy');
    expect(scheduled, hasLength(14));
    expect(scheduled.map((r) => r['id']).toSet(), hasLength(14));
    expect(scheduled.every((r) => r['payload'] == 'course'), isTrue);
    expect(scheduled.first['body'], 'Buddy · 0.5 ml');
    expect(pending.any((r) => r['id'] == 888), isFalse);
    await service.cancel('course');
    expect(pending.single['payload'], 'other');
  });

  test('course scheduling respects total pending-request headroom', () async {
    pending.addAll([
      for (var i = 0; i < 55; i++) {'id': i + 1, 'payload': 'other-$i'}
    ]);
    await service.schedule(reminder, nextAt: reminder.nextAt);
    expect(scheduled, hasLength(5));
    expect(pending, hasLength(60));
  });

  test(
      'notification initialization failure cannot fail the persisted business operation',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel, (_) async => throw PlatformException(code: 'unavailable'));
    await service.schedule(reminder, nextAt: reminder.nextAt);
    await service.cancel(reminder.id);
    await service.cancelAll();
    expect(await service.requestPermission(), isFalse);
  });
}
