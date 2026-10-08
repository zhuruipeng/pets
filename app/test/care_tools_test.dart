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
import 'package:pet_app/domain/care_handoff.dart';
import 'package:pet_app/domain/family_care.dart';
import 'package:pet_app/domain/labels.dart';
import 'package:pet_app/domain/medication_course.dart';
import 'package:pet_app/domain/symptom_observation.dart';
import 'package:pet_app/providers.dart';
import 'package:pet_app/services/report_renderer.dart';
import 'package:pet_app/ui/backup_page.dart';
import 'package:pet_app/ui/care_handoff.dart';
import 'package:pet_app/ui/symptom_fields.dart';
import 'package:pet_app/ui/symptom_observations.dart';
import 'package:pet_app/ui/profile_screen.dart';
import 'package:pet_app/ui/sheets.dart';
import 'package:pet_app/services/backup_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FixturePets extends PetsNotifier {
  @override
  Future<List<Pet>> build() async => [];
}

void main() {
  late Database db;
  late Pet pet, other;
  late RecordRepository records;
  late ReminderRepository reminders;
  late ProviderContainer container;
  final at = DateTime(2026, 10, 7, 9);
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
    await db.insert('users', {
      'id': 'owner',
      'nickname': 'Alice',
      'region': 'intl',
      'created_at': 1,
      'updated_at': 1
    });
    final pets = PetRepository(db);
    pet = await pets.createSimple(
        name: 'Buddy', speciesWire: 'dog', createdBy: 'owner');
    pet = Pet.fromMap({...pet.toMap(), 'allergy': 'Chicken'});
    await pets.update(pet);
    other = await pets.createSimple(
        name: 'Other', speciesWire: 'cat', createdBy: 'owner');
    records = RecordRepository(db);
    reminders = ReminderRepository(db);
    container = ProviderContainer(overrides: [
      petRepositoryProvider.overrideWithValue(pets),
      recordRepositoryProvider.overrideWithValue(records),
      reminderRepositoryProvider.overrideWithValue(reminders),
      memberRepositoryProvider.overrideWithValue(MemberRepository(db)),
      userRepositoryProvider.overrideWithValue(UserRepository(db)),
      dbReadyProvider.overrideWith((ref) async {}),
    ]);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  MedicationCourse course({DateTime? end}) => MedicationCourse(
      name: 'Medicine',
      dose: '1 tablet',
      start: at,
      end: end ?? DateTime(2026, 10, 9),
      times: [600, 1200]);

  test(
      'observations validate stable codes and retain structured symptoms across round trips',
      () {
    const observation = SymptomObservation(
        count: 3, appetite: 'reduced', energy: 'low', stool: 'soft');
    final restored = SymptomObservation.fromPayload(observation.toPayload())!;
    expect(restored.count, 3);
    expect(restored.symptom, 'vomiting');
    expect(restored.summary, contains('3'));
    expect(restored.summary, isNot(contains('observation.')));
    expect(recordTypeFromWire(RecordType.symptom.wireName), RecordType.symptom);
    for (final count in [0, -1, 1001]) {
      expect(() => SymptomObservation(count: count).toPayload(),
          throwsArgumentError);
    }
    expect(SymptomObservation.fromPayload({'symptom': 'unknown'}), isNull);
    expect(
        SymptomObservation.fromPayload({'symptom': 'vomiting', 'count': 1.5}),
        isNull);
  });

  test(
      'saving a dated observation uses the existing actor, outbox and same-pet references',
      () async {
    final visit = await records.createSimple(
        petId: pet.id,
        type: RecordType.medical,
        recordedAt: at,
        createdBy: 'owner');
    final reminder =
        await reminders.createCourse(petId: pet.id, course: course(), now: at);
    await container.read(appActionsProvider).addRecord(
        petId: pet.id,
        type: RecordType.symptom,
        recordedAt: at,
        payload: SymptomObservation(
                count: 2,
                medicalRecordId: visit.id,
                courseReminderId: reminder.id)
            .toPayload());
    final record = (await records.listByPet(pet.id))
        .firstWhere((r) => r.type == RecordType.symptom);
    expect(record.recordedAt, at);
    expect(record.payload['actor_name'], 'Alice');
    expect(record.payload['course_reminder_id'], reminder.id);
    expect(recordPayloadSummary(record), contains('2'));
    final event =
        buildCareEvents(records: [record], logs: [], reminders: [], day: at)
            .single;
    expect(
        event.detail, contains(SymptomObservation.fromRecord(record)!.title));
    expect(event.detail, isNot(contains('vomiting')));
    expect(
        await db
            .query('sync_outbox', where: 'row_id = ?', whereArgs: [record.id]),
        isNotEmpty);
  });

  test('viewer access and references to another pet cannot write observations',
      () async {
    final visit = await records.createSimple(
        petId: other.id,
        type: RecordType.medical,
        recordedAt: at,
        createdBy: 'owner');
    final reminder = await reminders.createCourse(
        petId: other.id, course: course(), now: at);
    for (final observation in [
      SymptomObservation(medicalRecordId: visit.id),
      SymptomObservation(courseReminderId: reminder.id)
    ]) {
      await expectLater(
          container.read(appActionsProvider).addRecord(
              petId: pet.id,
              type: RecordType.symptom,
              recordedAt: at,
              payload: observation.toPayload()),
          throwsArgumentError);
    }
    await MemberRepository(db)
        .add(petId: pet.id, userId: 'owner', role: MemberRole.viewer);
    await expectLater(
        container.read(appActionsProvider).addRecord(
            petId: pet.id,
            type: RecordType.symptom,
            recordedAt: at,
            payload: const SymptomObservation().toPayload()),
        throwsStateError);
    expect(await records.listByPet(pet.id), isEmpty);
  });

  test(
      'handoff includes care details, intersecting active courses and excludes unrelated history',
      () async {
    await records.createSimple(
        petId: pet.id,
        type: RecordType.feeding,
        recordedAt: at,
        createdBy: 'owner',
        valueNum: 100,
        unit: 'g',
        payload: {'brand': 'Usual food', 'kind': 'dry'});
    await records.createSimple(
        petId: other.id,
        type: RecordType.feeding,
        recordedAt: at,
        createdBy: 'owner',
        valueText: 'Other food');
    final active =
        await reminders.createCourse(petId: pet.id, course: course(), now: at);
    await reminders.createCourse(petId: other.id, course: course(), now: at);
    final report = buildCareHandoff(
        pet: pet,
        records: [
          ...await records.listByPet(pet.id),
          ...await records.listByPet(other.id)
        ],
        reminders: [
          ...await reminders.listForPet(pet.id),
          ...await reminders.listForPet(other.id)
        ],
        from: at,
        to: DateTime(2026, 10, 8),
        now: at,
        instructions: 'Walk twice',
        contact: 'Alice 12345');
    final facts = report.facts.map((f) => f.value).join('\n');
    expect(facts, contains('Chicken'));
    expect(facts, contains('100 g'));
    expect(facts, contains('Walk twice'));
    expect(facts, contains('Alice 12345'));
    expect(facts, isNot(contains('Other food')));
    expect(report.records, hasLength(1));
    expect(report.records.single.detail, contains('10:00 / 20:00'));
    expect(report.footerKey, 'handoff.footer');
    final ended = buildCareHandoff(
        pet: pet,
        records: [],
        reminders: [active],
        from: DateTime(2026, 10, 10),
        to: DateTime(2026, 10, 11),
        now: at);
    expect(ended.records, isEmpty);
    final paused = Reminder.fromMap({...active.toMap(), 'enabled': 0});
    expect(
        buildCareHandoff(
                pet: pet,
                records: [],
                reminders: [paused],
                from: at,
                to: at,
                now: at)
            .records,
        isEmpty);
    expect(
        () => buildCareHandoff(
            pet: pet,
            records: [],
            reminders: [],
            from: at,
            to: DateTime(2026, 10, 6),
            now: at),
        throwsArgumentError);
  });

  testWidgets(
      'handoff renders a real PNG with the custom footer and no contact when excluded',
      (tester) async {
    final report = buildCareHandoff(
        pet: pet,
        records: [],
        reminders: [],
        from: at,
        to: at,
        now: at,
        instructions: 'A long instruction. ' * 100);
    expect(report.facts.any((f) => f.label == L.t('handoff.contact')), isFalse);
    final bytes =
        await tester.runAsync(() => renderPetReportPng(report, width: 360));
    expect(bytes!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
  });

  for (final language in [L.current.name]) {
    testWidgets(
        'read-only observation page and handoff fit a small $language screen',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await container.read(petRecordsProvider(pet.id).future);
        await container.read(petRoleProvider(pet.id).future);
      });
      await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: SymptomObservationsPage(pet: pet))));
      await tester.pumpAndSettle();
      expect(find.text(L.t('observation.empty')), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsOneWidget);
      await tester.pumpWidget(ProviderScope(overrides: [
        petRoleProvider(pet.id).overrideWith((ref) async => MemberRole.viewer),
        petRecordsProvider(pet.id).overrideWith((ref) async => []),
      ], child: MaterialApp(home: SymptomObservationsPage(pet: pet))));
      await tester.pumpAndSettle();
      expect(find.byType(FloatingActionButton), findsNothing);
      await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: CareHandoffPage(pet: pet))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(ProviderScope(overrides: [
        backupInventoryProvider.overrideWith((ref) async =>
            const BackupInventory(pets: 1, records: 3, attachments: 2)),
      ], child: const MaterialApp(home: BackupPage())));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'observation form preserves initial fields and tolerates unavailable references',
      (tester) async {
    SymptomObservation? value;
    const initial = SymptomObservation(
        symptom: 'cough',
        count: 4,
        energy: 'low',
        medicalRecordId: 'removed',
        courseReminderId: 'removed-course');
    await tester.runAsync(() async {
      await container.read(petRecordsProvider(pet.id).future);
      await container.read(petRemindersProvider(pet.id).future);
    });
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            home: Scaffold(
                body: SingleChildScrollView(
                    child: SymptomFields(
                        petId: pet.id,
                        initial: initial,
                        onChanged: (v) => value = v))))));
    await tester.pump();
    expect(find.text('4'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('symptom-count')), '5');
    expect(value!.symptom, 'cough');
    expect(value!.energy, 'low');
    expect(value!.count, 5);
    expect(tester.takeException(), isNull);
  });

  testWidgets('symptom save stays visible with a keyboard and enlarged text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.runAsync(() async {
      await container.read(petRecordsProvider(pet.id).future);
      await container.read(petRemindersProvider(pet.id).future);
      await container.read(weightSeriesProvider(pet.id).future);
      await container.read(petRoleProvider(pet.id).future);
    });
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!),
            home: Scaffold(
                body: Consumer(
                    builder: (context, ref, _) => TextButton(
                        onPressed: () => showAddRecordSheet(context, ref,
                            petId: pet.id, initialType: RecordType.symptom),
                        child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final count = find.byKey(const ValueKey('symptom-count'));
    await tester.ensureVisible(count);
    await tester.enterText(count, '0');
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, L.t('addRecord.save'));
    expect(tester.getRect(save).bottom, lessThanOrEqualTo(380));
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(await tester.runAsync(() => records.listByPet(pet.id)), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('quick symptom choices keep optional links out of the main form',
      (tester) async {
    SymptomObservation? value;
    await tester.runAsync(() async {
      await container.read(petRecordsProvider(pet.id).future);
      await container.read(petRemindersProvider(pet.id).future);
    });
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            home: Scaffold(
                body: SingleChildScrollView(
                    child: SymptomFields(
                        petId: pet.id, onChanged: (v) => value = v))))));
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    final low = find.byKey(const ValueKey('observation.energy-low'));
    await tester.ensureVisible(low);
    await tester.tap(low);
    expect(value!.energy, 'low');
    final extra = find.text(L.t('observation.extra'));
    await tester.ensureVisible(extra);
    await tester.tap(extra);
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<String>), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the real health tab exposes both new tools and navigates to them',
      (tester) async {
    final view = ProviderContainer(parent: container, overrides: [
      currentPetProvider.overrideWithValue(pet),
      petsProvider.overrideWith(_FixturePets.new),
      petRecordsProvider(pet.id).overrideWith((ref) async => []),
      petRemindersProvider(pet.id).overrideWith((ref) async => []),
      petRoleProvider(pet.id).overrideWith((ref) async => MemberRole.owner),
      weightSeriesProvider(pet.id).overrideWith((ref) async => []),
      petMembersProvider(pet.id).overrideWith((ref) async => []),
      petDocumentsProvider(pet.id).overrideWith((ref) async => []),
      petPhotosProvider(pet.id).overrideWith((ref) async => []),
    ]);
    addTearDown(view.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
        container: view,
        child: const MaterialApp(home: Scaffold(body: ProfileScreen()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text(L.t('profile.tab.health')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(L.t('observation.title')));
    await tester.tap(find.text(L.t('observation.title')));
    await tester.pumpAndSettle();
    expect(find.byType(SymptomObservationsPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(L.t('handoff.title')));
    await tester.tap(find.text(L.t('handoff.title')));
    await tester.pumpAndSettle();
    expect(find.byType(CareHandoffPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test(
      'backup selector specifies iOS UTI and both translations cover every symptom state',
      () {
    expect(
        backupFileType.uniformTypeIdentifiers, contains('public.zip-archive'));
    for (final code in SymptomObservation.symptoms) {
      expect(
          L.t('observation.symptom.$code'), isNot('observation.symptom.$code'));
    }
    for (final code in {
      ...SymptomObservation.appetites,
      ...SymptomObservation.energies,
      ...SymptomObservation.stools
    }) {
      expect(L.t('observation.state.$code'), isNot('observation.state.$code'));
    }
    expect(L.tableDiff().onlyZh, isEmpty);
    expect(L.tableDiff().onlyEn, isEmpty);
  });
}
