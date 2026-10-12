import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pet_app/data/db/schema.dart';
import 'package:pet_app/data/sync/sync_api.dart';
import 'package:pet_app/data/sync/sync_engine.dart';
import 'package:pet_app/data/sync/token_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Api extends SyncApi {
  _Api() : super(baseUrl: 'http://127.0.0.1:1');
  final batches = <List<SyncChange>>[];
  Future<PushResult> Function(List<SyncChange>)? onPush;
  Future<PullResult> Function(int)? onPull;

  @override
  Future<PushResult> push(
      {required String token,
      required String deviceId,
      required List<SyncChange> changes}) async {
    batches.add(changes);
    return onPush == null
        ? PushResult(applied: changes, rejected: const [])
        : await onPush!(changes);
  }

  @override
  Future<PullResult> pull(
          {required String token, required int since, int limit = 200}) async =>
      onPull == null
          ? PullResult(changes: const [], nextSince: since, hasMore: false)
          : await onPull!(since);
}

Map<String, dynamic> _expense(Map<String, dynamic> money,
        {int timestamp = 1000}) =>
    {
      'id': 'e1',
      'pet_id': 'p1',
      ...money,
      'currency': 'CNY',
      'category': 'food',
      'spent_at': 100,
      'note': 'original',
      'created_by': 'u1',
      'created_at': 100,
      'updated_at': timestamp,
    };

Future<Database> _open(String path, int version) =>
    databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
          version: version,
          singleInstance: false,
          onCreate: (db, _) async {
            for (final sql in onCreate) {
              await db.execute(version == 7 && sql == createExpenses
                  ? sql.replaceFirst(
                      'amount_cents   INTEGER', 'amount         REAL')
                  : sql);
            }
          },
          onUpgrade: (db, from, to) async {
            for (var version = from + 1; version <= to; version++) {
              for (final sql in migrations[version] ?? <String>[]) {
                await db.execute(sql);
              }
            }
          },
        ));

Future<void> _pet(Database db) async {
  await db.insert('pets', {
    'id': 'p1',
    'name': 'Pet',
    'species': 'dog',
    'created_by': 'u1',
    'created_at': 100,
    'updated_at': 100
  });
  await db.delete('sync_outbox');
}

void main() {
  late Database db;
  late _Api api;
  late SyncEngine engine;
  setUp(() async {
    sqfliteFfiInit();
    db = await _open(inMemoryDatabasePath, kSchemaVersion);
    await _pet(db);
    api = _Api();
    engine = SyncEngine(
        dbProvider: () => db, tokenStore: MemoryTokenStore('token'), api: api);
  });
  tearDown(() async => db.close());

  for (final money in [
    <String, dynamic>{'amount': 12.35},
    <String, dynamic>{'amount_cents': 1235},
    <String, dynamic>{'amount': 12.35, 'amount_cents': 1235}
  ]) {
    test('pull normalizes expense money $money to cents-only SQLite', () async {
      api.onPull = (_) async => PullResult(changes: [
            SyncChange(
                table: 'expenses',
                rowId: 'e1',
                op: 'upsert',
                updatedAt: 1000,
                payload: _expense(money))
          ], nextSince: 20, hasMore: false);
      final result = await engine.sync();
      expect(result.ok, isTrue, reason: '${result.error}');
      expect((await db.query('expenses')).single['amount_cents'], 1235);
      expect(await db.query('sync_outbox'), isEmpty);
    });
  }

  for (final entry in [(12.35, 1235), (0.07, 7), (-12.5, -1250), (0.0, 0)]) {
    test('actual v7 upgrade ${entry.$1} keeps timestamp and old-client wire',
        () async {
      final temp = await Directory.systemTemp.createTemp('expense-upgrade-');
      final path = p.join(temp.path, 'upgrade.db');
      var migrated = await _open(path, 7);
      addTearDown(() async {
        await migrated.close();
        await temp.delete(recursive: true);
      });
      await _pet(migrated);
      await migrated.insert('expenses', _expense({'amount': entry.$1}));
      await migrated.delete('sync_outbox');
      await migrated.close();
      migrated = await _open(path, kSchemaVersion);
      expect(
          (await migrated.query('expenses')).single['amount_cents'], entry.$2);
      final upgraded = SyncEngine(
          dbProvider: () => migrated,
          tokenStore: MemoryTokenStore('token'),
          api: api);
      final result = await upgraded.sync();
      expect(result.ok, isTrue, reason: '${result.error}');
      final pushed = api.batches.single.single;
      expect(pushed.updatedAt, 1000);
      expect(pushed.payload['amount'], entry.$1);
      expect(pushed.payload, isNot(contains('amount_cents')));
      final legacy = await _open(inMemoryDatabasePath, 7);
      try {
        await _pet(legacy);
        await legacy.insert('expenses', pushed.payload);
        expect((await legacy.query('expenses')).single['amount'], entry.$1);
      } finally {
        await legacy.close();
      }
    });
  }

  for (final serverTime in [1000, 900]) {
    test('migration stale canonical at $serverTime survives advanced cursor',
        () async {
      await db.insert('expenses', _expense({'amount_cents': 1235}));
      await db.insert('sync_meta', {'key': 'last_seq', 'value': '99'});
      api.onPush = (changes) async => PushResult(applied: const [], rejected: [
            for (final change in changes) (change: change, reason: 'stale')
          ], canonical: [
            SyncChange(
                table: 'expenses',
                rowId: 'e1',
                op: 'upsert',
                updatedAt: serverTime,
                payload: {
                  ..._expense({'amount': 12.35}, timestamp: serverTime),
                  'note': 'server winner'
                })
          ]);
      final result = await engine.sync();
      expect(result.ok, isTrue, reason: '${result.error}');
      final row = (await db.query('expenses')).single;
      expect(row['amount_cents'], 1235);
      expect(row['note'], 'server winner');
      expect(row['updated_at'], serverTime);
      expect(await engine.pendingCount(), 0);
      expect(
          (await db.query('sync_meta',
                  where: 'key = ?', whereArgs: ['last_seq']))
              .single['value'],
          '99');
    });
  }

  test('a same-millisecond money edit during stale upload stays queued',
      () async {
    await db.insert('expenses', _expense({'amount_cents': 1235}));
    api.onPush = (changes) async {
      if (api.batches.length > 1) throw StateError('offline');
      await db.update('expenses', {'amount_cents': 1400, 'updated_at': 1000},
          where: 'id = ?', whereArgs: ['e1']);
      return PushResult(applied: const [], rejected: [
        (change: changes.single, reason: 'stale')
      ], canonical: [
        SyncChange(
            table: 'expenses',
            rowId: 'e1',
            op: 'upsert',
            updatedAt: 1000,
            payload: _expense({'amount': 12.35}))
      ]);
    };
    expect((await engine.sync()).ok, isFalse);
    expect((await db.query('expenses')).single['amount_cents'], 1400);
    expect(await engine.pendingCount(), 1);
    expect(api.batches.last.single.payload['amount'], 14.0);
  });

  test('legacy expense tombstone converts money and does not re-upload',
      () async {
    await db.insert('expenses', _expense({'amount_cents': 1235}));
    await db.delete('sync_outbox');
    api.onPull = (_) async => PullResult(changes: [
          SyncChange(
              table: 'expenses',
              rowId: 'e1',
              op: 'delete',
              updatedAt: 2000,
              payload: _expense({'amount': 12.35}, timestamp: 2000))
        ], nextSince: 20, hasMore: false);
    final result = await engine.sync();
    expect(result.ok, isTrue, reason: '${result.error}');
    expect((await db.query('expenses')).single['deleted_at'], 2000);
    expect((await db.query('expenses')).single['amount_cents'], 1235);
    expect(await db.query('sync_outbox'), isEmpty);
  });

  for (final invalid in ['bad', null, true, double.nan, double.infinity]) {
    test('invalid legacy money $invalid rolls back pull cursor', () async {
      await db.insert('sync_meta', {'key': 'last_seq', 'value': '9'});
      api.onPull = (_) async => PullResult(changes: [
            SyncChange(
                table: 'expenses',
                rowId: 'e1',
                op: 'upsert',
                updatedAt: 1000,
                payload: _expense({'amount': invalid}))
          ], nextSince: 20, hasMore: false);
      expect((await engine.sync()).ok, isFalse);
      expect(await db.query('expenses'), isEmpty);
      expect(
          (await db.query('sync_meta',
                  where: 'key = ?', whereArgs: ['last_seq']))
              .single['value'],
          '9');
    });
  }
}
