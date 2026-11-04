import 'dart:io';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/core/l10n.dart';
import 'package:pet_app/core/region.dart';
import 'package:pet_app/data/db/app_database.dart';
import 'package:pet_app/data/models.dart';
import 'package:pet_app/data/sync/photo_sync.dart';
import 'package:pet_app/data/sync/sync_api.dart';
import 'package:pet_app/data/sync/sync_engine.dart';
import 'package:pet_app/data/sync/token_store.dart';
import 'package:pet_app/domain/expense_stats.dart';
import 'package:pet_app/providers.dart';
import 'package:pet_app/ui/profile_screen.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RemoteExpenses extends SyncApi {
  _RemoteExpenses() : super(baseUrl: 'http://127.0.0.1:1');
  final changes = <SyncChange>[];
  int pulls = 0;

  @override
  Future<PushResult> push(
          {required String token,
          required String deviceId,
          required List<SyncChange> changes}) async =>
      PushResult(applied: changes, rejected: const []);

  @override
  Future<PullResult> pull(
      {required String token, required int since, int limit = 200}) async {
    pulls++;
    return PullResult(
        changes: changes.where((c) => c.seq! > since).toList(),
        nextSince: changes.isEmpty ? since : changes.last.seq!,
        hasMore: false);
  }
}

class _Photos extends PhotoSync {
  _Photos(this.fail) : super(cacheDirectory: () async => Directory.systemTemp);
  final bool fail;

  @override
  Future<void> downloadMissing(Database db, SyncApi api, String token) async {
    if (fail) throw const FileSystemException('Photo download failed');
    await super.downloadMissing(db, api, token);
  }
}

class _Actions extends AppActions {
  _Actions(super.ref);
  // Platform notifications are unrelated to expense cache refresh.
  @override
  Future<void> refreshNotifications() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DatabaseFactory? previousFactory;
  late Database db;
  late ProviderContainer container;
  late SyncEngine engine;
  late _RemoteExpenses api;
  late DateTime now;

  Map<String, Object?> expense(String id, int cents, DateTime spentAt,
          {String category = 'food'}) =>
      {
        'id': id,
        'pet_id': 'p1',
        'amount_cents': cents,
        'currency': AppRegion.current.defaultCurrency,
        'category': category,
        'spent_at': spentAt.millisecondsSinceEpoch,
        'note': id,
        'created_by': 'u1',
        'created_at': 1,
        'updated_at': 1,
      };

  setUp(() async {
    sqfliteFfiInit();
    previousFactory = sqflite.databaseFactoryOrNull;
    sqflite.databaseFactoryOrNull = databaseFactoryFfi;
    db = await AppDatabase.instance.open(overridePath: inMemoryDatabasePath);
    now = DateTime.now();
    await db.insert('users', {
      'id': 'u1',
      'nickname': 'Owner',
      'region': AppRegion.current.name,
      'created_at': 1,
      'updated_at': 1
    });
    await db.insert('pets', {
      'id': 'p1',
      'name': 'Buddy',
      'species': 'dog',
      'created_by': 'u1',
      'created_at': 1,
      'updated_at': 1
    });
    await db.insert('expenses',
        expense('cached food', 1235, DateTime(now.year, now.month, 1)));
    await db.insert('expenses',
        expense('previous month', 2000, DateTime(now.year, now.month - 1, 1)));
    await db.delete('sync_outbox');
    api = _RemoteExpenses();
  });

  tearDown(() async {
    container.dispose();
    await AppDatabase.instance.close();
    sqflite.databaseFactoryOrNull = previousFactory;
  });

  for (final photoFails in [false, true]) {
    testWidgets(
        'cached expense page refreshes after remote add and delete '
        '(photo failure: $photoFails)', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      engine = SyncEngine(
          dbProvider: () => db,
          api: api,
          tokenStore: MemoryTokenStore(),
          photoSync: _Photos(photoFails));
      await tester.runAsync(() async {
        await engine.saveSession(
            const AuthSession(
                token: 'token', user: RemoteUser(id: 'u1', nickname: 'Owner')),
            accountRegion: AppRegion.current.name);
        await engine.setPhotoSyncEnabled(true);
      });
      container = ProviderContainer(overrides: [
        dbReadyProvider.overrideWith((ref) async {}),
        syncEngineProvider.overrideWithValue(engine),
        appActionsProvider.overrideWith(_Actions.new),
      ]);
      await tester.runAsync(() => container.read(petsProvider.future));
      await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: ProfileScreen()))));
      await tester.pumpAndSettle();
      await tester.tap(find.text(L.t('profile.tab.expense')));

      Future<void> waitForExpenses() async {
        await tester.runAsync(() async {
          await container.read(petExpensesProvider('p1').future);
          await container.read(expenseSummaryProvider('p1').future);
        });
        await tester.pumpAndSettle();
      }

      void expectSummary(
          double month, double total, Map<ExpenseCategory, double> categories) {
        final summary =
            container.read(expenseSummaryProvider('p1')).requireValue;
        expect(summary.monthTotal, month);
        expect(summary.allTotal, total);
        expect({for (final s in summary.byCategory) s.category: s.total},
            categories);
        expect(summary.months[summary.months.length - 2].total, 20);
        expect(summary.months.last.total, month);
        expect(find.text(formatMoney(total, AppRegion.current.defaultCurrency)),
            findsWidgets);
        final chart = tester.widget<BarChart>(find.byType(BarChart));
        expect(chart.data.barGroups.last.barRods.single.toY, month);
      }

      // Load the real expense tab first, so both production providers are cached.
      await waitForExpenses();
      expect(find.textContaining('cached food'), findsOneWidget);
      expectSummary(12.35, 32.35, {ExpenseCategory.food: 12.35});

      final remote = expense(
          'remote vet', 765, DateTime(now.year, now.month, 1),
          category: 'medical');
      api.changes.add(SyncChange(
          table: 'expenses',
          rowId: 'remote vet',
          op: 'upsert',
          updatedAt: 2,
          seq: 1,
          payload: remote));
      final controller = container.read(syncControllerProvider.notifier);
      await tester.runAsync(() => controller.runSync());
      await waitForExpenses();
      expect(
          (await tester.runAsync(() => db.query('expenses')))!, hasLength(3));
      expect(
          container
              .read(petExpensesProvider('p1'))
              .requireValue
              .map((e) => e.id),
          contains('remote vet'));
      expect(find.textContaining('remote vet'), findsOneWidget);
      expectSummary(
          20, 40, {ExpenseCategory.food: 12.35, ExpenseCategory.medical: 7.65});

      api.changes.add(SyncChange(
          table: 'expenses',
          rowId: 'cached food',
          op: 'delete',
          updatedAt: 3,
          seq: 2,
          payload: {
            ...expense('cached food', 1235, DateTime(now.year, now.month, 1)),
            'deleted_at': 3
          }));
      await tester.runAsync(() => controller.runSync());
      await waitForExpenses();
      expect(
          container
              .read(petExpensesProvider('p1'))
              .requireValue
              .map((e) => e.id),
          unorderedEquals(['remote vet', 'previous month']));
      expect(find.textContaining('cached food'), findsNothing);
      expect(find.textContaining('remote vet'), findsOneWidget);
      expectSummary(7.65, 27.65, {ExpenseCategory.medical: 7.65});
      expect(api.pulls, 2);
      expect(container.read(syncControllerProvider).phase,
          photoFails ? SyncPhase.error : SyncPhase.idle);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
