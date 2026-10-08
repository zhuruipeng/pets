import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/core/l10n.dart';
import 'package:pet_app/core/species.dart';
import 'package:pet_app/data/models.dart';
import 'package:pet_app/data/repositories/member_repository.dart';
import 'package:pet_app/domain/family_care.dart';
import 'package:pet_app/providers.dart';
import 'package:pet_app/services/backup_service.dart';
import 'package:pet_app/ui/backup_page.dart';
import 'package:pet_app/ui/care_handoff.dart';
import 'package:pet_app/ui/family_care_board.dart';
import 'package:pet_app/ui/health_tools.dart';
import 'package:pet_app/ui/reminders_overview.dart';
import 'package:pet_app/ui/today_screen.dart';

final now = DateTime.now();
final pet = Pet(
    id: 'pet',
    name: 'Buddy',
    species: Species.dog,
    createdBy: 'owner',
    createdAt: now,
    updatedAt: now);
final archived = Pet.fromMap({
  ...pet.toMap(),
  'id': 'archived',
  'archived_at': now.millisecondsSinceEpoch
});
Reminder reminder(String id, DateTime at, {bool enabled = true}) => Reminder(
    id: id,
    petId: pet.id,
    type: 'custom',
    title: id,
    nextAt: at,
    rule: const {},
    enabled: enabled,
    createdAt: now,
    updatedAt: now);
final due = reminder('Due care', now.subtract(const Duration(hours: 1)));
final distant =
    reminder('Beyond seven days', now.add(const Duration(days: 30)));

class FixturePets extends PetsNotifier {
  @override
  Future<List<Pet>> build() async => [pet, archived];
}

class FixtureUpcoming extends UpcomingRemindersNotifier {
  @override
  Future<List<Reminder>> build() async => [due];
}

class FixtureSync extends SyncController {
  @override
  SyncStatus build() => const SyncStatus();
}

void main() {
  final day = DateTime(now.year, now.month, now.day);
  final overrides = [
    petsProvider.overrideWith(FixturePets.new),
    currentPetProvider.overrideWithValue(pet),
    currentUserProvider.overrideWith((ref) async => null),
    petRoleProvider(pet.id).overrideWith((ref) async => MemberRole.viewer),
    petRecordsProvider(pet.id).overrideWith((ref) async => []),
    petRemindersProvider(pet.id).overrideWith((ref) async =>
        [due, distant, reminder('Disabled', now, enabled: false)]),
    petRemindersProvider(archived.id)
        .overrideWith((ref) async => [reminder('Archived schedule', now)]),
    activeWalkProvider.overrideWith((ref) => null),
    weightSeriesProvider(pet.id).overrideWith((ref) async => []),
    upcomingRemindersProvider.overrideWith(FixtureUpcoming.new),
    syncControllerProvider.overrideWith(FixtureSync.new),
    careEventsProvider((pet.id, day.millisecondsSinceEpoch))
        .overrideWith((ref) async => [
              for (var i = 0; i < 5; i++)
                CareEvent(
                    at: now,
                    title: 'History $i',
                    actorName: 'Caregiver',
                    detail: 'Detail $i'),
            ]),
    backupInventoryProvider.overrideWith((ref) async =>
        const BackupInventory(pets: 2, records: 8, attachments: 3)),
  ];
  Widget app(Widget page, {double scale = 1}) => ProviderScope(
      overrides: overrides,
      child: MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: page));

  testWidgets('home prioritizes due tasks and view all opens distant reminders',
      (tester) async {
    await tester.pumpWidget(app(const Scaffold(body: TodayScreen())));
    await tester.pumpAndSettle();
    expect(find.text(L.t('care.pending')), findsNothing);
    expect(tester.getTopLeft(find.text(L.t('home.todo'))).dy, lessThan(600));
    await tester.scrollUntilVisible(find.text(L.t('care.historyTitle')), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text(L.t('care.pending')), findsNothing);
    await tester.scrollUntilVisible(find.text(L.t('home.viewAll')), -200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text(L.t('home.viewAll')));
    await tester.pumpAndSettle();
    expect(find.byType(RemindersOverviewPage), findsOneWidget);
    expect(find.text('Beyond seven days'), findsOneWidget);
    expect(find.text('Disabled'), findsNothing);
    expect(find.text('Archived schedule'), findsNothing);
    expect(tester.widget<ListTile>(find.byKey(ValueKey(distant.id))).onTap,
        isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('family history shows three events and can expand then collapse',
      (tester) async {
    await tester.pumpWidget(app(Scaffold(
        body: SingleChildScrollView(
            child: FamilyCareBoard(pet: pet, showPending: false)))));
    await tester.pumpAndSettle();
    expect(find.text('Detail 4', findRichText: true), findsNothing);
    expect(find.byType(ListTile), findsNWidgets(3));
    final all = find.text(L.tp('care.showAll', {'count': 5}));
    await tester.ensureVisible(all);
    await tester.tap(all);
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(5));
    await tester.ensureVisible(find.text(L.t('care.collapse')));
    await tester.tap(find.text(L.t('care.collapse')));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(3));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'tools, handoff templates, backup counts and reminders fit enlarged text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final page in [
      Scaffold(body: SingleChildScrollView(child: HealthToolsCard(pet: pet))),
      const RemindersOverviewPage(),
      CareHandoffPage(pet: pet),
      const BackupPage(),
      const Scaffold(body: TodayScreen()),
    ]) {
      await tester.pumpWidget(app(page, scale: 1.5));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
    await tester.pumpWidget(app(CareHandoffPage(pet: pet), scale: 1.5));
    await tester.pumpAndSettle();
    final chip =
        find.widgetWithText(ActionChip, L.t('handoff.template.feeding'));
    await tester.scrollUntilVisible(chip, 160,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        contains(L.t('handoff.templateText.feeding')));
    expect(find.text(L.t('handoff.preview')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
