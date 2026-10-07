import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/core/l10n.dart';
import 'package:pet_app/data/db/schema.dart';
import 'package:pet_app/data/models.dart';
import 'package:pet_app/data/repositories/member_repository.dart';
import 'package:pet_app/data/repositories/pet_repository.dart';
import 'package:pet_app/data/repositories/record_repository.dart';
import 'package:pet_app/data/repositories/reminder_repository.dart';
import 'package:pet_app/data/repositories/user_repository.dart';
import 'package:pet_app/domain/family_care.dart';
import 'package:pet_app/domain/medication_course.dart';
import 'package:pet_app/providers.dart';
import 'package:pet_app/services/notification_service.dart';
import 'package:pet_app/ui/delete_pet_button.dart';
import 'package:pet_app/ui/family_care_board.dart';
import 'package:pet_app/ui/medication_courses.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Notifications extends NotificationService {
  _Notifications() : super.forTesting();
  final cancelled = <String>[];
  final scheduled = <DateTime>[];
  int resets = 0;
  @override
  Future<void> cancelAll() async {
    resets++;
  }

  @override
  Future<void> cancel(String id) async {
    cancelled.add(id);
  }

  @override
  Future<void> schedule(Reminder reminder,
      {required DateTime nextAt, String? petName}) async {
    scheduled.add(nextAt);
  }

  @override
  Future<bool> requestPermission() async => true;
}

class _Sync extends SyncController {
  int refreshes = 0;
  @override
  SyncStatus build() => const SyncStatus();
  @override
  Future<void> markDirty() async {
    state = state.copyWith(pending: state.pending + 1);
  }

  @override
  Future<void> runSync() async {
    refreshes++;
  }
}

class _Pets extends PetsNotifier {
  @override
  Future<List<Pet>> build() => ref.read(petRepositoryProvider).listAll();
}

MedicationCourse _course(
        {DateTime? start,
        DateTime? end,
        List<int> times = const [540, 1200],
        double? stock = 4,
        double units = 1}) =>
    MedicationCourse(
      name: 'Medicine',
      dose: '1 tablet',
      start: start ?? DateTime(2026, 10, 7),
      end: end ?? DateTime(2026, 10, 8),
      times: times,
      stock: stock,
      unitsPerDose: units,
    );

void main() {
  late Database db;
  late PetRepository pets;
  late ReminderRepository reminders;
  late RecordRepository records;
  late MemberRepository members;
  late Pet pet;
  late _Notifications notifications;
  late ProviderContainer container;

  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
            version: kSchemaVersion,
            onCreate: (db, _) async {
              for (final sql in onCreate) {
                await db.execute(sql);
              }
            }));
    pets = PetRepository(db);
    reminders = ReminderRepository(db);
    records = RecordRepository(db);
    members = MemberRepository(db);
    pet = await pets.createSimple(
        name: 'Buddy', speciesWire: 'dog', createdBy: 'u1');
    await db.insert('users', {
      'id': 'u1',
      'nickname': 'Alice',
      'region': 'intl',
      'created_at': 1,
      'updated_at': 1
    });
    notifications = _Notifications();
    container = ProviderContainer(overrides: [
      petRepositoryProvider.overrideWithValue(pets),
      reminderRepositoryProvider.overrideWithValue(reminders),
      recordRepositoryProvider.overrideWithValue(records),
      memberRepositoryProvider.overrideWithValue(members),
      userRepositoryProvider.overrideWithValue(UserRepository(db)),
      notificationServiceProvider.overrideWithValue(notifications),
      syncControllerProvider.overrideWith(_Sync.new),
      petsProvider.overrideWith(_Pets.new),
      dbReadyProvider.overrideWith((ref) async {}),
    ]);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('multiple daily slots, inclusive end date and strict advancement', () {
    final course = _course();
    expect(course.nextAt(DateTime(2026, 10, 6)), DateTime(2026, 10, 7, 9));
    expect(course.nextAt(DateTime(2026, 10, 7, 9)), DateTime(2026, 10, 7, 9));
    expect(course.nextAt(DateTime(2026, 10, 7, 9), inclusive: false),
        DateTime(2026, 10, 7, 20));
    expect(
        course.nextAt(DateTime(2026, 10, 7, 20, 1)), DateTime(2026, 10, 8, 9));
    expect(course.nextAt(DateTime(2026, 10, 8, 20), inclusive: false), isNull);
    expect(course.upcomingSlots(DateTime(2026, 10, 7, 8)), hasLength(4));
    expect(
        course.upcomingSlots(DateTime(2026, 10, 7, 8), limit: 2), hasLength(2));
  });

  test('invalid dates, slots and quantities are rejected', () {
    expect(() => _course(end: DateTime(2026, 10, 6)).toRule(),
        throwsArgumentError);
    for (final times in <List<int>>[
      [],
      [540, 540],
      [-1],
      [1440]
    ]) {
      expect(() => _course(times: times).toRule(), throwsArgumentError);
    }
    expect(() => _course(stock: double.nan).toRule(), throwsArgumentError);
    expect(() => _course(units: 0).toRule(), throwsArgumentError);
  });

  test(
      'concurrent dose confirmations write once, advance once and retain actor',
      () async {
    final r = await reminders.createCourse(
        petId: pet.id, course: _course(), now: DateTime(2026, 10, 7, 8));
    final results = await Future.wait([
      reminders.completeOnce(r.id,
          expectedDueAt: r.nextAt,
          at: DateTime(2026, 10, 7, 9, 3),
          createdBy: 'u1',
          actorName: 'Alice'),
      reminders.completeOnce(r.id,
          expectedDueAt: r.nextAt,
          at: DateTime(2026, 10, 7, 9, 4),
          createdBy: 'u2',
          actorName: 'Bob'),
    ]);
    expect(results.where((r) => r.alreadyCompleted), hasLength(1));
    expect((await reminders.findById(r.id))!.nextAt, DateTime(2026, 10, 7, 20));
    final logs = await reminders.logsForPet(pet.id);
    final doses = await records.listByPet(pet.id);
    expect(logs, hasLength(1));
    expect(doses, hasLength(1));
    expect(logs.single['created_by'], doses.single.createdBy);
    expect(logs.single['actor_name'], doses.single.payload['actor_name']);
    expect(logs.single['record_id'], doses.single.id);
    expect(_course().remaining(logs.single['stock_used'] as num), 3);
    expect(doses.single.recordedAt, results.first.completedAt);
    expect(
        (await db.query('sync_outbox',
            where: 'table_name = ?', whereArgs: ['reminder_logs'])),
        hasLength(1));
  });

  test('final dose disables course and stale confirmation cannot advance',
      () async {
    final r = await reminders.createCourse(
        petId: pet.id,
        course: _course(end: DateTime(2026, 10, 7), times: [540]),
        now: DateTime(2026, 10, 7, 8));
    final result = await reminders.completeOnce(r.id,
        expectedDueAt: r.nextAt, at: r.nextAt);
    expect(result.nextAt, isNull);
    expect((await reminders.findById(r.id))!.enabled, isFalse);
    expect(
        (await reminders.completeOnce(r.id, expectedDueAt: r.nextAt))
            .alreadyCompleted,
        isTrue);
    expect(await records.listByPet(pet.id), hasLength(1));
  });

  test('transaction rolls back dose and log if advancement fails', () async {
    final r = await reminders.createCourse(
        petId: pet.id, course: _course(), now: DateTime(2026, 10, 7, 8));
    await db.execute(
        "CREATE TRIGGER reject_advance BEFORE UPDATE ON reminders BEGIN SELECT RAISE(ABORT, 'failed'); END");
    await expectLater(reminders.completeOnce(r.id, expectedDueAt: r.nextAt),
        throwsA(isA<DatabaseException>()));
    expect(await records.listByPet(pet.id), isEmpty);
    expect(await reminders.logsForPet(pet.id), isEmpty);
    expect((await reminders.findById(r.id))!.nextAt, r.nextAt);
  });

  test('inventory uses historical units after dose quantity changes', () async {
    final r = await reminders.createCourse(
        petId: pet.id,
        course: _course(units: 0.5),
        now: DateTime(2026, 10, 7, 8));
    await reminders.completeOnce(r.id, expectedDueAt: r.nextAt, at: r.nextAt);
    final used =
        (await reminders.logsForPet(pet.id)).single['stock_used'] as num;
    expect(_course(units: 2).remaining(used), 3.5);
  });

  test(
      'care board merges dose log with its record and preserves calendar boundaries',
      () async {
    final r = await reminders.createCourse(
        petId: pet.id, course: _course(), now: DateTime(2026, 10, 7, 8));
    await reminders.completeOnce(r.id,
        at: DateTime(2026, 10, 7, 9), createdBy: 'u1', actorName: 'Alice');
    await records.createSimple(
        petId: pet.id,
        type: RecordType.feeding,
        recordedAt: DateTime(2026, 10, 7, 23, 59),
        createdBy: 'u2');
    await records.createSimple(
        petId: pet.id,
        type: RecordType.water,
        recordedAt: DateTime(2026, 10, 8),
        createdBy: 'u2');
    final events = buildCareEvents(
        records: await records.listByPet(pet.id),
        logs: await reminders.logsForPet(pet.id),
        reminders: [r],
        day: DateTime(2026, 10, 7));
    expect(events, hasLength(2));
    expect(events.first.type, RecordType.feeding);
    expect(events.last.actorName, 'Alice');
  });

  test('viewer cannot give doses or delete; editor can give but cannot delete',
      () async {
    final r = await reminders.createCourse(
        petId: pet.id, course: _course(), now: DateTime(2026, 10, 7, 8));
    await members.add(petId: pet.id, userId: 'u1', role: MemberRole.viewer);
    final actions = container.read(appActionsProvider);
    await expectLater(actions.completeReminder(r.id), throwsStateError);
    await expectLater(actions.deletePet(pet.id), throwsStateError);
    await members.add(petId: pet.id, userId: 'u1', role: MemberRole.editor);
    await expectLater(actions.deletePet(pet.id), throwsStateError);
    await actions.completeReminder(r.id, expectedDueAt: r.nextAt);
    expect(await reminders.logsForPet(pet.id), hasLength(1));
  });

  test('removed owner cannot regain access through creator fallback', () async {
    await members.add(petId: pet.id, userId: 'u1', role: MemberRole.owner);
    await db.update('members', {'deleted_at': 5},
        where: 'pet_id = ?', whereArgs: [pet.id]);
    expect(await members.roleFor(pet.id, 'u1'), isNull);
    await expectLater(
        container.read(appActionsProvider).deletePet(pet.id), throwsStateError);
  });

  test(
      'unknown roles and an absent membership on a shared pet cannot grant creator privileges',
      () async {
    await members.add(petId: pet.id, userId: 'u2', role: MemberRole.owner);
    expect(await members.roleFor(pet.id, 'u1'), isNull);
    await members.add(petId: pet.id, userId: 'u1', role: MemberRole.editor);
    await db.update('members', {'role': 'unknown'},
        where: 'user_id = ?', whereArgs: ['u1']);
    expect(await members.roleFor(pet.id, 'u1'), isNull);
  });

  test('restoring notifications includes active pets only', () async {
    final now = DateTime.now();
    await reminders.createInterval(
        petId: pet.id,
        type: 'vaccine',
        title: 'Active',
        everyDays: 30,
        firstAt: now);
    final hidden = await pets.createSimple(
        name: 'Hidden', speciesWire: 'cat', createdBy: 'u1');
    await reminders.createInterval(
        petId: hidden.id,
        type: 'vaccine',
        title: 'Hidden',
        everyDays: 30,
        firstAt: now.add(const Duration(days: 1)));
    await pets.softDelete(hidden.id);
    await container.read(appActionsProvider).refreshNotifications();
    expect(notifications.resets, 1);
    expect(notifications.scheduled.map((d) => d.millisecondsSinceEpoch),
        [now.millisecondsSinceEpoch]);
  });

  test(
      'late confirmation advances past elapsed slots without logging unadministered doses',
      () async {
    final r = await reminders.createCourse(
        petId: pet.id, course: _course(), now: DateTime(2026, 10, 7, 8));
    final result = await reminders.completeOnce(r.id,
        expectedDueAt: r.nextAt, at: DateTime(2026, 10, 7, 20, 5));
    expect(result.nextAt, DateTime(2026, 10, 8, 9));
    expect(await reminders.logsForPet(pet.id), hasLength(1));
  });

  test(
      'pause and resume preserve latest state and skip an already confirmed future slot',
      () async {
    final today = MedicationCourse.day(DateTime.now());
    final course = _course(
        start: today.add(const Duration(days: 1)),
        end: today.add(const Duration(days: 2)));
    final r = await reminders.createCourse(petId: pet.id, course: course);
    await reminders.completeOnce(r.id,
        expectedDueAt: r.nextAt, at: DateTime.now());
    final paused = await reminders.toggleCourse(r, false);
    expect(paused.enabled, isFalse);
    expect(paused.nextAt, course.nextAt(r.nextAt, inclusive: false));
    final resumed = await reminders.toggleCourse(paused, true);
    expect(resumed.enabled, isTrue);
    expect(resumed.nextAt, course.nextAt(r.nextAt, inclusive: false));
    await reminders.softDelete(r.id);
    await expectLater(reminders.toggleCourse(resumed, true), throwsStateError);
  });

  test(
      'delete cancels notifications, clears selection and hides pending tasks while retaining history',
      () async {
    final r = await reminders.createCourse(
        petId: pet.id, course: _course(), now: DateTime(2026, 10, 7, 8));
    await records.createSimple(
        petId: pet.id,
        type: RecordType.feeding,
        recordedAt: DateTime.now(),
        createdBy: 'u1');
    container.read(selectedPetIdProvider.notifier).state = pet.id;
    await container.read(appActionsProvider).deletePet(pet.id);
    expect(await pets.listAll(), isEmpty);
    expect((await pets.findById(pet.id))!.deletedAt, isNotNull);
    expect(notifications.cancelled, contains(r.id));
    expect(container.read(selectedPetIdProvider), isNull);
    expect(
        await reminders.upcoming(
            from: DateTime(2026, 10, 7), to: DateTime(2026, 10, 9)),
        isEmpty);
    expect(await records.listByPet(pet.id), hasLength(1));
    await expectLater(reminders.completeOnce(r.id), throwsStateError);
    expect(
        (await db.query('sync_outbox',
                where: 'table_name = ? AND row_id = ?',
                whereArgs: ['pets', pet.id]))
            .single['op'],
        'delete');
  });

  test(
      'v6 upgrade preserves completion history, associates pet and seeds outbox',
      () async {
    final legacy = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    try {
      for (final sql in onCreate) {
        if (sql == createReminderLogs) {
          await legacy.execute(
              'CREATE TABLE reminder_logs(id TEXT PRIMARY KEY, reminder_id TEXT NOT NULL, '
              'due_at INTEGER NOT NULL, done_at INTEGER, record_id TEXT, action TEXT, UNIQUE(reminder_id,due_at))');
        } else if (!sql.contains(' ON reminder_logs')) {
          await legacy.execute(sql);
        }
      }
      await legacy.insert('pets', pet.toMap());
      final r = await reminders.createCourse(
          petId: pet.id, course: _course(), now: DateTime(2026, 10, 7, 8));
      await legacy.insert('reminders', r.toMap());
      await legacy.insert('reminder_logs', {
        'id': 'old-random-id',
        'reminder_id': r.id,
        'due_at': 100,
        'done_at': 200,
        'action': 'done'
      });
      for (final sql in migrations[7]!) {
        await legacy.execute(sql);
      }
      final log = (await legacy.query('reminder_logs')).single;
      expect(log['id'], 'log_${r.id}_100');
      expect(log['pet_id'], pet.id);
      expect(log['created_by'], isNull);
      expect(log['updated_at'], 200);
      expect(
          (await legacy.query('sync_outbox',
              where: 'table_name = ?', whereArgs: ['reminder_logs'])),
          hasLength(1));
    } finally {
      await legacy.close();
    }
  });

  testWidgets('delete confirmation can cancel then confirm', (tester) async {
    await tester.runAsync(() => container.read(petRoleProvider(pet.id).future));
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: Scaffold(body: DeletePetButton(pet: pet)))));
    await tester.pumpAndSettle();
    await tester.tap(find.text(L.t('pet.delete')));
    await tester.pumpAndSettle();
    expect(find.text(L.tp('pet.delete.title', {'name': pet.name})),
        findsOneWidget);
    await tester.tap(find.text(L.t('action.cancel')));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(pets.listAll), hasLength(1));
    await tester.tap(find.text(L.t('pet.delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, L.t('pet.delete')).last);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(await tester.runAsync(pets.listAll), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'care board displays actor, manual refresh and navigation on narrow phone',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final day = MedicationCourse.day(DateTime.now());
    final view = ProviderContainer(parent: container, overrides: [
      careEventsProvider((pet.id, day.millisecondsSinceEpoch))
          .overrideWith((ref) async => [
                CareEvent(
                    at: DateTime.now(),
                    type: RecordType.feeding,
                    actorId: 'u2',
                    actorName: 'Bob')
              ]),
      petRoleProvider(pet.id).overrideWith((ref) async => MemberRole.viewer),
      petRemindersProvider(pet.id).overrideWith((ref) async => []),
    ]);
    addTearDown(view.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
        container: view,
        child: MaterialApp(
            home: Scaffold(
                body:
                    SingleChildScrollView(child: FamilyCareBoard(pet: pet))))));
    await tester.pumpAndSettle();
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text(L.t('care.title')), findsOneWidget);
    await tester.tap(find.byTooltip(L.t('care.refresh')));
    await tester.pumpAndSettle();
    expect((view.read(syncControllerProvider.notifier) as _Sync).refreshes, 1);
    await tester.tap(find.text(L.t('med.title')));
    await tester.pumpAndSettle();
    expect(find.byType(MedicationCoursesPage), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'viewer sees course inventory and history but no write or delete controls',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final day = MedicationCourse.day(DateTime.now());
    final course =
        _course(start: day, end: day.add(const Duration(days: 7)), stock: 4);
    final r = Reminder(
        id: 'course',
        petId: pet.id,
        type: 'medication',
        title: course.name,
        rule: course.toRule(),
        nextAt: DateTime.now().add(const Duration(hours: 1)),
        createdAt: day,
        updatedAt: day);
    final view = ProviderContainer(parent: container, overrides: [
      petRoleProvider(pet.id).overrideWith((ref) async => MemberRole.viewer),
      petRemindersProvider(pet.id).overrideWith((ref) async => [r]),
      careLogsProvider(pet.id).overrideWith((ref) async => [
            {
              'reminder_id': r.id,
              'action': 'done',
              'stock_used': 0.5,
              'due_at': day.millisecondsSinceEpoch,
              'done_at': day.millisecondsSinceEpoch,
              'created_by': 'u2',
              'actor_name': 'Bob'
            },
          ]),
    ]);
    addTearDown(view.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
        container: view,
        child: MaterialApp(
            home: Scaffold(
                body: Column(children: [
          DeletePetButton(pet: pet),
          Expanded(child: MedicationCoursesPage(pet: pet))
        ])))));
    await tester.pumpAndSettle();
    expect(find.text(L.t('pet.delete')), findsNothing);
    expect(find.text(L.t('med.given')), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.text(L.tp('med.remaining', {'count': '3.5'})), findsOneWidget);
    await tester.tap(find.text(L.tp('med.history', {'count': '1'})));
    await tester.pumpAndSettle();
    expect(find.text('Bob'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('medication form validates and saves a course', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            home: Builder(
                builder: (context) => Scaffold(
                    body: TextButton(
                        onPressed: () =>
                            showMedicationCourseForm(context, pet: pet),
                        child: const Text('Open')))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(L.t('action.save')));
    await tester.tap(find.text(L.t('action.save')));
    await tester.pumpAndSettle();
    expect(find.text(L.t('med.error.required')), findsNWidgets(2));
    await tester.enterText(find.byType(TextFormField).at(0), 'Medicine');
    await tester.enterText(find.byType(TextFormField).at(1), '0.5 ml');
    await tester.enterText(find.byType(TextFormField).at(2), '10');
    await tester.ensureVisible(find.text(L.t('action.save')));
    await tester.tap(find.text(L.t('action.save')));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
    final saved =
        (await tester.runAsync(() => reminders.listForPet(pet.id)))!.single;
    expect(MedicationCourse.fromReminder(saved)!.dose, '0.5 ml');
    expect(jsonDecode(jsonEncode(saved.rule))['mode'], 'medication');
    expect(notifications.scheduled, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
