import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/data/db/schema.dart';
import 'package:pet_app/data/repositories/member_repository.dart';
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
  Future<PushResult> push({
    required String token,
    required String deviceId,
    required List<SyncChange> changes,
  }) async {
    batches.add(changes);
    return onPush == null
        ? PushResult(applied: changes, rejected: const [])
        : await onPush!(changes);
  }

  @override
  Future<PullResult> pull({
    required String token,
    required int since,
    int limit = 200,
  }) async =>
      onPull == null
          ? PullResult(changes: const [], nextSince: since, hasMore: false)
          : await onPull!(since);
}

void main() {
  late Database db;
  late _Api api;
  late MemoryTokenStore tokens;
  late SyncEngine engine;

  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
            onCreate: (db, _) async {
              for (final statement in onCreate) {
                await db.execute(statement);
              }
            },
            version: kSchemaVersion));
    api = _Api();
    tokens = MemoryTokenStore('token');
    engine = SyncEngine(dbProvider: () => db, tokenStore: tokens, api: api);
  });
  tearDown(() async => db.close());

  Future<void> pet(String id, {int timestamp = 1000}) => db.insert('pets', {
        'id': id,
        'name': id,
        'species': 'dog',
        'created_by': 'u1',
        'created_at': timestamp,
        'updated_at': timestamp,
      });

  for (final serverTime in [1000, 900]) {
    test(
        'stale conflict applies canonical row even when cursor already passed ($serverTime)',
        () async {
      await pet('p1');
      await db.insert('sync_meta', {'key': 'last_seq', 'value': '99'});
      api.onPush = (changes) async => PushResult(applied: const [], rejected: [
            for (final c in changes) (change: c, reason: 'stale')
          ], canonical: [
            SyncChange(
                table: 'pets',
                rowId: 'p1',
                op: 'upsert',
                updatedAt: serverTime,
                payload: {
                  'id': 'p1',
                  'name': 'server winner',
                  'updated_at': serverTime
                })
          ]);
      final result = await engine.sync();
      expect(result.ok, isTrue, reason: '${result.error}');
      expect((await db.query('pets')).single['name'], 'server winner');
      expect(await engine.pendingCount(), 0);
      expect(
          (await db.query('sync_meta',
                  where: 'key = ?', whereArgs: ['last_seq']))
              .single['value'],
          '99');
    });
  }

  test(
      'canonical stale response preserves an edit made during upload in the same millisecond',
      () async {
    await pet('p1');
    api.onPush = (changes) async {
      if (api.batches.length > 1) throw StateError('offline');
      await db.update('pets', {'name': 'new edit', 'updated_at': 1000},
          where: 'id = ?', whereArgs: ['p1']);
      return PushResult(applied: const [], rejected: [
        (change: changes.single, reason: 'stale')
      ], canonical: const [
        SyncChange(
            table: 'pets',
            rowId: 'p1',
            op: 'upsert',
            updatedAt: 1000,
            payload: {'id': 'p1', 'name': 'server winner', 'updated_at': 1000})
      ]);
    };
    expect((await engine.sync()).ok, isFalse);
    expect((await db.query('pets')).single['name'], 'new edit');
    expect(await engine.pendingCount(), 1);
    expect(api.batches.last.single.payload['name'], 'new edit');
  });

  test(
      'equal timestamp pull converges after acknowledgement from an older server',
      () async {
    await pet('p1');
    api.onPush = (changes) async => PushResult(
        applied: const [],
        rejected: [for (final c in changes) (change: c, reason: 'stale')]);
    api.onPull = (_) async => const PullResult(changes: [
          SyncChange(
              table: 'pets',
              rowId: 'p1',
              op: 'upsert',
              updatedAt: 1000,
              payload: {'id': 'p1', 'name': 'winner', 'updated_at': 1000})
        ], nextSince: 1, hasMore: false);
    expect((await engine.sync()).ok, isTrue);
    expect((await db.query('pets')).single['name'], 'winner');
    expect(await engine.pendingCount(), 0);
  });

  test(
      'own revocation overrides a local future timestamp and removes pet outbox',
      () async {
    await pet('p1');
    await db.insert('sync_meta', {'key': 'account_id', 'value': 'u1'});
    await db.insert('members', {
      'id': 'm1',
      'pet_id': 'p1',
      'user_id': 'u1',
      'role': 'editor',
      'status': 'active',
      'joined_at': 1,
      'updated_at': 9000
    });
    api.onPush = (changes) async => const PushResult(applied: [], rejected: []);
    api.onPull = (_) async => const PullResult(changes: [
          SyncChange(
              table: 'members',
              rowId: 'm1',
              op: 'delete',
              updatedAt: 2000,
              payload: {
                'id': 'm1',
                'pet_id': 'p1',
                'user_id': 'u1',
                'role': 'editor',
                'status': 'active',
                'joined_at': 1,
                'updated_at': 2000,
                'deleted_at': 2000
              })
        ], nextSince: 2, hasMore: false);
    expect((await engine.sync()).ok, isTrue);
    expect(await MemberRepository(db).roleFor('p1', 'u1'), isNull);
    expect(await engine.pendingCount(), 0);
    expect(await db.query('pets'), hasLength(1));
  });

  test('first-seen own revocation inserts the complete member tombstone',
      () async {
    await pet('p1');
    await db.insert('sync_meta', {'key': 'account_id', 'value': 'u1'});
    api.onPush = (changes) async => const PushResult(applied: [], rejected: []);
    api.onPull = (_) async => const PullResult(changes: [
          SyncChange(
              table: 'members',
              rowId: 'm1',
              op: 'delete',
              updatedAt: 2000,
              payload: {
                'id': 'm1',
                'pet_id': 'p1',
                'user_id': 'u1',
                'role': 'editor',
                'status': 'active',
                'joined_at': 1,
                'updated_at': 2000,
                'deleted_at': 2000
              })
        ], nextSince: 2, hasMore: false);
    final result = await engine.sync();
    expect(result.ok, isTrue, reason: '${result.error}');
    expect(await MemberRepository(db).roleFor('p1', 'u1'), isNull);
    expect((await db.query('members')).single['deleted_at'], 2000);
    expect(await engine.pendingCount(), 0);
  });

  test('canonical shared completion replaces a later offline duplicate',
      () async {
    await pet('p1');
    final dose = {
      'id': 'dose_course_9',
      'pet_id': 'p1',
      'type': 'medication',
      'recorded_at': 9,
      'created_at': 9,
      'updated_at': 3000,
      'created_by': 'u1',
      'payload': '{"course_id":"course","due_at":9,"actor_name":"Alice"}'
    };
    final log = {
      'id': 'log_course_9',
      'pet_id': 'p1',
      'reminder_id': 'course',
      'due_at': 9,
      'done_at': 9,
      'action': 'done',
      'record_id': 'dose_course_9',
      'created_at': 9,
      'updated_at': 3000,
      'stock_used': 1.0,
      'created_by': 'u1',
      'actor_name': 'Alice'
    };
    await db.insert('records', dose);
    await db.insert('reminder_logs', log);
    api.onPush = (changes) async => PushResult(
            applied: changes.where((c) => c.table == 'pets').toList(),
            rejected: [
              for (final c in changes.where((c) => c.table != 'pets'))
                (change: c, reason: 'stale')
            ]);
    api.onPull = (_) async => PullResult(changes: [
          SyncChange(
              table: 'records',
              rowId: 'dose_course_9',
              op: 'upsert',
              updatedAt: 2000,
              payload: {
                ...dose,
                'updated_at': 2000,
                'created_by': 'u2',
                'payload':
                    '{"course_id":"course","due_at":9,"actor_name":"Bob"}'
              }),
          SyncChange(
              table: 'reminder_logs',
              rowId: 'log_course_9',
              op: 'upsert',
              updatedAt: 2000,
              payload: {
                ...log,
                'updated_at': 2000,
                'created_by': 'u2',
                'actor_name': 'Bob'
              }),
        ], nextSince: 2, hasMore: false);
    final result = await engine.sync();
    expect(result.ok, isTrue, reason: '${result.error}');
    expect((await db.query('reminder_logs')).single['actor_name'], 'Bob');
    expect((await db.query('records')).single['created_by'], 'u2');
    expect(await engine.pendingCount(), 0);
  });

  test(
      'course dependencies are pushed before logs even across a batch boundary',
      () async {
    await pet('p1', timestamp: 9000);
    await db.insert('reminders', {
      'id': 'course',
      'pet_id': 'p1',
      'type': 'medication',
      'title': 'Medicine',
      'rule': '{}',
      'next_at': 9,
      'created_at': 9,
      'updated_at': 9000
    });
    for (var i = 0; i < 201; i++) {
      await db.insert('records', {
        'id': 'record-$i',
        'pet_id': 'p1',
        'type': 'medication',
        'recorded_at': 1,
        'created_at': 1,
        'updated_at': 1,
        'created_by': 'u1'
      });
    }
    await db.insert('reminder_logs', {
      'id': 'log_course_9',
      'pet_id': 'p1',
      'reminder_id': 'course',
      'due_at': 9,
      'done_at': 9,
      'action': 'done',
      'record_id': 'record-200',
      'created_at': 9,
      'updated_at': 2
    });
    final received = <String>{};
    api.onPush = (changes) async {
      for (final change in changes) {
        if (change.table == 'reminder_logs') {
          expect(
              received,
              containsAll(
                  ['pets:p1', 'reminders:course', 'records:record-200']));
        }
        received.add('${change.table}:${change.rowId}');
      }
      return PushResult(applied: changes, rejected: const []);
    };
    expect((await engine.sync()).ok, isTrue);
    expect(api.batches, hasLength(2));
    expect(received, contains('reminder_logs:log_course_9'));
    expect(await engine.pendingCount(), 0);
  });

  for (final timestamp in [1000, 2000]) {
    test('上传中的再次编辑不能被旧响应从队列中删除（$timestamp）', () async {
      await pet('p1');
      api.onPush = (changes) async {
        if (api.batches.length == 1) {
          await db.update('pets', {'name': '新名字', 'updated_at': timestamp},
              where: 'id = ?', whereArgs: ['p1']);
          return PushResult(applied: changes, rejected: const []);
        }
        throw StateError('第二批断网');
      };

      final result = await engine.sync();

      expect(api.batches.length, 2);
      expect(api.batches.last.single.payload['name'], '新名字');
      expect(result.ok, isFalse);
      expect(await engine.pendingCount(), 1);
    });
  }

  test('前一批失效条目不能清掉后一批有效变更', () async {
    for (var i = 0; i < 200; i++) {
      await db.insert('sync_outbox', {
        'table_name': 'pets',
        'row_id': 'missing-$i',
        'pet_id': 'missing-$i',
        'op': 'upsert',
        'updated_at': 1,
      });
    }
    await pet('real');

    final result = await engine.sync();

    expect(result.ok, isTrue);
    expect(api.batches, hasLength(1));
    expect(api.batches.single.single.rowId, 'real');
    expect(await engine.pendingCount(), 0);
  });

  test('已改为仅本机保存的附件不能从遗留队列上传', () async {
    await db.insert('sync_outbox', {
      'table_name': 'attachments',
      'row_id': 'a1',
      'pet_id': 'p1',
      'op': 'upsert',
      'updated_at': 1000,
    });
    await db.insert('attachments', {
      'id': 'a1',
      'record_id': 'r1',
      'kind': 'document',
      'local_only': 1,
      'local_path': '/private/report.pdf',
      'created_at': 1000,
      'updated_at': 1000,
    });

    expect((await engine.sync()).ok, isTrue);
    expect(api.batches, isEmpty);
    expect(await engine.pendingCount(), 0);
    expect(await db.query('attachments'), hasLength(1));
  });

  test('整批被拒之后仍应推送后面的有效条目', () async {
    for (var i = 0; i < 201; i++) {
      await pet('p$i', timestamp: i + 1);
    }
    api.onPush = (changes) async => api.batches.length == 1
        ? PushResult(applied: const [], rejected: [
            for (final change in changes) (change: change, reason: 'stale'),
          ])
        : PushResult(applied: changes, rejected: const []);

    final result = await engine.sync();

    expect(result.ok, isTrue);
    expect(result.pushed, 1);
    expect(result.rejected, 200);
    expect(await engine.pendingCount(), 0);
  });

  test('pull 返回 401 时也必须清理失效登录令牌', () async {
    api.onPull = (_) async => throw SyncApiException(401, 'expired');

    final result = await engine.sync();

    expect(result.ok, isFalse);
    expect(tokens.value, isNull);
    expect(await engine.isLoggedIn(), isFalse);
  });

  test('照片同步携带所属宠物，远端应用不写入本地不存在的 pet_id 列', () async {
    await pet('p1');
    await db.insert('records', {
      'id': 'r1',
      'pet_id': 'p1',
      'type': 'note',
      'recorded_at': 1000,
      'created_by': 'u1',
      'created_at': 1000,
      'updated_at': 1000,
    });
    await db.insert('attachments', {
      'id': 'a1',
      'record_id': 'r1',
      'kind': 'photo',
      'remote_url': 'https://example.com/photo.jpg',
      'created_at': 1000,
      'updated_at': 1000,
    });
    api.onPull = (_) async => const PullResult(changes: [
          SyncChange(
              table: 'attachments',
              rowId: 'a2',
              op: 'upsert',
              updatedAt: 2000,
              payload: {
                'id': 'a2',
                'record_id': 'r1',
                'pet_id': 'p1',
                'kind': 'photo',
                'created_at': 2000,
                'updated_at': 2000,
              }),
        ], nextSince: 1, hasMore: false);

    final result = await engine.sync();

    expect(
        api.batches.first
            .where((c) => c.table == 'attachments')
            .single
            .payload['pet_id'],
        'p1');
    expect(result.ok, isTrue, reason: '${result.error}');
    expect(
        (await db.query('attachments', where: 'id = ?', whereArgs: ['a2']))
            .single['record_id'],
        'r1');
    expect(await engine.pendingCount(), 0);
  });
}
