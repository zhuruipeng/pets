import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/data/db/schema.dart';
import 'package:pet_app/data/repositories/user_repository.dart';
import 'package:pet_app/data/sync/sync_api.dart';
import 'package:pet_app/data/sync/sync_engine.dart';
import 'package:pet_app/data/sync/token_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Api extends SyncApi {
  _Api() : super(baseUrl: 'http://127.0.0.1:1');
  Future<PullResult> Function(String token, int since)? onPull;
  final uploads = <(String, List<SyncChange>)>[];

  @override
  Future<PushResult> push(
      {required String token,
      required String deviceId,
      required List<SyncChange> changes}) async {
    uploads.add((token, changes));
    return PushResult(applied: changes, rejected: const []);
  }

  @override
  Future<PullResult> pull(
          {required String token, required int since, int limit = 200}) async =>
      onPull == null
          ? PullResult(changes: const [], nextSince: since, hasMore: false)
          : await onPull!(token, since);

  @override
  Future<void> logout(String token) async {}
}

class _FailingStore extends MemoryTokenStore {
  _FailingStore() : super('token-A');
  @override
  Future<void> write(String token) async =>
      throw TokenStoreException('write failed');
}

class _RestoreFailingStore extends MemoryTokenStore {
  _RestoreFailingStore() : super('token-A');
  @override
  Future<void> write(String token) async {
    if (token == 'token-A') throw TokenStoreException('restore failed');
    await super.write(token);
  }
}

void main() {
  late Database db;
  late UserRepository users;
  late MemoryTokenStore tokens;
  late SyncEngine engine;
  late _Api api;

  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
            version: kSchemaVersion,
            onCreate: (db, _) async {
              for (final statement in onCreate) {
                await db.execute(statement);
              }
            }));
    users = UserRepository(db);
    api = _Api();
    tokens = MemoryTokenStore();
    engine = SyncEngine(dbProvider: () => db, tokenStore: tokens, api: api);
  });
  tearDown(() async => db.close());

  Future<void> meta(String key, String value) =>
      db.insert('sync_meta', {'key': key, 'value': value},
          conflictAlgorithm: ConflictAlgorithm.replace);
  Future<String?> readMeta(String key) async {
    final rows =
        await db.query('sync_meta', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.single['value'] as String?;
  }

  Future<void> login(String id) => engine.saveSession(
      AuthSession(token: 'token-$id', user: RemoteUser(id: id, nickname: id)),
      accountRegion: 'intl',
      prepareAccount: (txn) => users.adoptAccountIn(txn,
          accountId: id, region: 'intl', nickname: id));
  Future<void> pet(String id, String owner) => db.insert('pets', {
        'id': id,
        'name': id,
        'species': 'dog',
        'created_by': owner,
        'created_at': 1,
        'updated_at': 100,
      });

  test('A to B to A preserves pending rows, local files and per-account cursor',
      () async {
    await login('A');
    await pet('pet-A', 'A');
    await db.insert('attachments', {
      'id': 'file-A',
      'record_id': 'record-A',
      'kind': 'document',
      'local_only': 1,
      'local_path': '/private/report.pdf',
      'created_at': 1
    });
    await meta('last_seq', '44');
    await meta('last_sync_at', '123');
    await meta('backup_last_generated', '456');
    await meta('device_id', 'same-device');
    await engine.signOut();
    await login('B');
    expect((await users.current())!.id, 'B');
    expect(await db.query('pets'), isEmpty);
    expect(await db.query('attachments'), isEmpty);
    expect(await engine.pendingCount(), 0);
    expect(await readMeta('last_seq'), isNull);
    expect(await readMeta('backup_last_generated'), isNull);
    expect(await readMeta('device_id'), 'same-device');
    final archive = await readMeta('account_snapshot:A');
    expect(archive, isNot(contains('token-A')));

    await pet('pet-B', 'B');
    api.onPull = (token, since) async {
      expect(token, 'token-B');
      expect(since, 0);
      return const PullResult(changes: [], nextSince: 77, hasMore: false);
    };
    expect((await engine.sync()).ok, isTrue);
    expect(api.uploads.single.$1, 'token-B');
    expect(api.uploads.single.$2.single.rowId, 'pet-B');
    await login('A');
    expect((await users.current())!.id, 'A');
    expect((await db.query('pets')).single['id'], 'pet-A');
    expect((await db.query('attachments')).single['local_path'],
        '/private/report.pdf');
    expect(await engine.pendingCount(), 1);
    expect(await readMeta('last_seq'), '44');
    expect(await readMeta('last_sync_at'), '123');
    expect(await readMeta('backup_last_generated'), '456');
    await login('B');
    expect((await db.query('pets')).single['id'], 'pet-B');
    expect(await readMeta('last_seq'), '77');
  });

  test('same-account relogin preserves offline work and cursor', () async {
    await login('A');
    await pet('pet-A', 'A');
    await meta('last_seq', '44');
    await engine.signOut();
    await login('A');
    expect(await engine.pendingCount(), 1);
    expect(await readMeta('last_seq'), '44');
    expect((await db.query('pets')).single['created_by'], 'A');
  });

  test('first guest login adopts pets and expenses without losing ownership',
      () async {
    await db.insert('users', {
      'id': 'local-user',
      'nickname': 'guest',
      'region': 'local',
      'created_at': 1,
      'updated_at': 1
    });
    await pet('guest-pet', 'local-user');
    await db.insert('expenses', {
      'id': 'expense',
      'pet_id': 'guest-pet',
      'amount': 5,
      'currency': 'USD',
      'category': 'food',
      'spent_at': 1,
      'created_at': 1,
      'updated_at': 1,
      'created_by': 'local-user'
    });
    await login('A');
    expect((await users.current())!.id, 'A');
    expect((await db.query('pets')).single['created_by'], 'A');
    expect((await db.query('expenses')).single['created_by'], 'A');
    expect(
        await db.query('sync_outbox',
            where: 'row_id = ?', whereArgs: ['local-user']),
        isEmpty);
  });

  test('failed account transaction restores data and previous token', () async {
    await login('A');
    await pet('pet-A', 'A');
    await meta('last_seq', '44');
    await expectLater(
        engine.saveSession(
            const AuthSession(
                token: 'token-B', user: RemoteUser(id: 'B', nickname: 'B')),
            accountRegion: 'intl', prepareAccount: (txn) async {
          await users.adoptAccountIn(txn, accountId: 'B', region: 'intl');
          throw StateError('disk failure');
        }),
        throwsStateError);
    expect(await engine.token(), 'token-A');
    expect(tokens.value, 'token-A');
    expect((await users.current())!.id, 'A');
    expect((await db.query('pets')).single['id'], 'pet-A');
    expect(await readMeta('last_seq'), '44');
    expect(await readMeta('account_snapshot:A'), isNull);
  });

  test('token write failure never starts the account switch', () async {
    await login('A');
    final failing =
        SyncEngine(dbProvider: () => db, tokenStore: _FailingStore(), api: api);
    var prepared = false;
    await expectLater(
        failing.saveSession(
            const AuthSession(
                token: 'token-B', user: RemoteUser(id: 'B', nickname: 'B')),
            accountRegion: 'intl', prepareAccount: (_) async {
          prepared = true;
        }),
        throwsA(isA<TokenStoreException>()));
    expect(prepared, isFalse);
    expect((await users.current())!.id, 'A');
  });

  test(
      'interrupted key-store/database commit signs out before uploading old data',
      () async {
    await login('A');
    await pet('pet-A', 'A');
    await meta('session_pending', 'B');
    await tokens.write('token-B');
    final reopened =
        SyncEngine(dbProvider: () => db, tokenStore: tokens, api: api);
    expect(await reopened.token(), isNull);
    expect(tokens.value, isNull);
    expect((await users.current())!.id, 'A');
    expect(await reopened.pendingCount(), 1);
    expect(await readMeta('session_pending'), 'B');
  });

  test('failed token restoration blocks sync and leaves a recovery journal',
      () async {
    await login('A');
    final store = _RestoreFailingStore();
    final failing =
        SyncEngine(dbProvider: () => db, tokenStore: store, api: api);
    await expectLater(
        failing.saveSession(
            const AuthSession(
                token: 'token-B', user: RemoteUser(id: 'B', nickname: 'B')),
            accountRegion: 'intl', prepareAccount: (_) async {
          throw StateError('disk failure');
        }),
        throwsA(isA<TokenStoreException>()));
    expect(await failing.token(), isNull);
    expect(await readMeta('session_pending'), 'B');
    final reopened =
        SyncEngine(dbProvider: () => db, tokenStore: store, api: api);
    expect(await reopened.token(), isNull);
    expect(store.value, isNull);
    expect((await users.current())!.id, 'A');
  });

  test('switch waits for active sync before replacing the working set',
      () async {
    await login('A');
    final started = Completer<void>(), release = Completer<void>();
    api.onPull = (token, since) async {
      expect(token, 'token-A');
      started.complete();
      await release.future;
      return const PullResult(changes: [], nextSince: 88, hasMore: false);
    };
    final syncing = engine.sync();
    await started.future;
    final switching = login('B');
    await Future<void>.delayed(Duration.zero);
    expect(tokens.value, 'token-A');
    expect((await users.current())!.id, 'A');
    release.complete();
    expect((await syncing).ok, isTrue);
    await switching;
    expect(tokens.value, 'token-B');
    expect(await readMeta('last_seq'), isNull);
    await login('A');
    expect(await readMeta('last_seq'), '88');
  });
}
