import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pet_app/core/l10n.dart';
import 'package:pet_app/data/db/schema.dart';
import 'package:pet_app/data/sync/account_data.dart';
import 'package:pet_app/data/sync/sync_api.dart';
import 'package:pet_app/data/sync/sync_engine.dart';
import 'package:pet_app/data/sync/token_store.dart';
import 'package:pet_app/providers.dart';
import 'package:pet_app/ui/delete_account_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Api extends SyncApi {
  _Api() : super(baseUrl: 'http://127.0.0.1:1');
  Future<void> Function()? onDelete;
  int pushes = 0;
  @override
  Future<void> deleteAccount(String token) async {
    expect(token, 'token-A');
    await onDelete?.call();
  }

  @override
  Future<PushResult> push(
      {required String token,
      required String deviceId,
      required List<SyncChange> changes}) async {
    pushes++;
    return PushResult(applied: changes, rejected: const []);
  }

  @override
  Future<PullResult> pull(
          {required String token, required int since, int limit = 200}) async =>
      PullResult(changes: const [], nextSince: since, hasMore: false);
}

class _Actions extends AppActions {
  _Actions(super.ref);
  int calls = 0;
  final done = Completer<void>();
  @override
  Future<void> deleteAccount() async {
    calls++;
    await done.future;
  }
}

class _CannotClear extends MemoryTokenStore {
  @override
  Future<void> clear() async => throw StateError('keychain unavailable');
}

void main() {
  late Database db;
  late _Api api;
  late MemoryTokenStore tokens;
  late SyncEngine engine;
  late Directory docs;

  Future<void> meta(String key, String value) async =>
      db.insert('sync_meta', {'key': key, 'value': value},
          conflictAlgorithm: ConflictAlgorithm.replace);
  Future<void> login(String id) => engine.saveSession(
      AuthSession(token: 'token-$id', user: RemoteUser(id: id, nickname: id)),
      accountRegion: 'intl',
      prepareAccount: (txn) =>
          adoptAccountData(txn, accountId: id, region: 'intl', nickname: id));
  Future<void> pet(String id, String owner) async => db.insert('pets', {
        'id': id,
        'name': id,
        'species': 'dog',
        'created_by': owner,
        'created_at': 1,
        'updated_at': 1
      });

  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
            onConfigure: (db) async => db.execute('PRAGMA foreign_keys=ON'),
            version: kSchemaVersion,
            onCreate: (db, _) async {
              for (final statement in onCreate) {
                await db.execute(statement);
              }
            }));
    api = _Api();
    tokens = MemoryTokenStore();
    engine = SyncEngine(dbProvider: () => db, tokenStore: tokens, api: api);
    docs = await Directory.systemTemp.createTemp('pet-account-deletion-');
    await login('A');
    await pet('pet-A', 'A');
  });
  tearDown(() async {
    await db.close();
    await docs.delete(recursive: true);
  });

  test(
      'erases account, outbox and cursor without preserving a deleted snapshot',
      () async {
    await meta('last_seq', '123');
    await meta('photo_sync_enabled', '1');
    await engine.deleteAccount();
    expect(await engine.token(), isNull);
    expect(await tokens.read(), isNull);
    expect(await db.query('pets'), isEmpty);
    expect(await db.query('sync_outbox'), isEmpty);
    expect((await db.query('users')).single['id'], 'local-user');
    expect(
        await db.query('sync_meta', where: 'key IN (?, ?, ?)', whereArgs: [
          'last_seq',
          'photo_sync_enabled',
          'account_snapshot:A'
        ]),
        isEmpty);
    await login('NEW');
    expect(await db.query('pets'), isEmpty);
    expect((await db.query('users')).single['id'], 'NEW');
  });

  test('other local accounts and their referenced files survive deletion',
      () async {
    await login('B');
    await pet('pet-B', 'B');
    await login('A');
    await engine.deleteAccount();
    expect(
        await db.query('sync_meta',
            where: 'key = ?', whereArgs: ['account_snapshot:B']),
        hasLength(1));
    await login('B');
    expect((await db.query('pets')).single['id'], 'pet-B');
  });

  test('failure retains local rows and supports retry after a lost response',
      () async {
    api.onDelete = () async => throw const SocketException('response lost');
    await expectLater(engine.deleteAccount(), throwsA(isA<SocketException>()));
    expect(await engine.token(), 'token-A');
    expect(await db.query('pets'), hasLength(1));
    await expectLater(login('B'), throwsStateError);
    await expectLater(engine.signOut(), throwsStateError);
    await engine.sync();
    expect(api.pushes, 0);
    api.onDelete = null;
    await engine.deleteAccount();
    expect(await db.query('pets'), isEmpty);
  });

  test('shared-pet rejection leaves the session and data usable', () async {
    api.onDelete =
        () async => throw SyncApiException(409, 'account_has_shared_pets');
    await expectLater(engine.deleteAccount(), throwsA(isA<SyncApiException>()));
    expect(await engine.token(), 'token-A');
    expect(await db.query('pets'), hasLength(1));
    await engine.sync();
    expect(api.pushes, 1);
  });

  test('local cleanup rollback keeps the retry token after remote success',
      () async {
    await db.execute(
        "CREATE TRIGGER block_erasure BEFORE DELETE ON pets BEGIN SELECT RAISE(ABORT, 'storage failure'); END");
    await expectLater(
        engine.deleteAccount(), throwsA(isA<DatabaseException>()));
    expect(await db.query('pets'), hasLength(1));
    expect(await engine.token(), 'token-A');
    expect(await engine.accountDeletionPending(), isTrue);
    await db.execute('DROP TRIGGER block_erasure');
    await engine.deleteAccount();
    expect(await db.query('pets'), isEmpty);
    expect(await engine.token(), isNull);
  });

  test('failed keychain clear cannot revive deleted credentials after restart',
      () async {
    tokens = _CannotClear();
    engine = SyncEngine(dbProvider: () => db, tokenStore: tokens, api: api);
    await login('A');
    await engine.deleteAccount();
    expect(await engine.token(), isNull);
    // The startup journal rejects the token even if its platform clear fails.
    final restarted =
        SyncEngine(dbProvider: () => db, tokenStore: tokens, api: api);
    expect(await restarted.token(), isNull);
    expect(await db.query('pets'), isEmpty);
  });

  test(
      'cleanup deletes only app copies, preserving exports and another account file',
      () async {
    final folder = Directory('${docs.path}/attachments')..createSync();
    final erase = File('${folder.path}/erase.jpg')..writeAsStringSync('erase');
    final keep = File('${folder.path}/keep.jpg')..writeAsStringSync('keep');
    final exported = File('${docs.path}/my-backup.zip')
      ..writeAsStringSync('backup');
    await meta(
        'account_snapshot:B',
        jsonEncode({
          'attachments': [
            {'local_path': keep.path}
          ]
        }));
    await meta(
        'deleted_account_files', jsonEncode([erase.path, exported.path]));
    await db.insert('pets', {
      'id': 'with-avatar',
      'name': 'p',
      'species': 'cat',
      'created_by': 'A',
      'avatar_url': keep.path,
      'created_at': 1,
      'updated_at': 1
    });
    await engine.deleteAccount();
    await purgeDeletedAccountFiles(db, docs);
    expect(erase.existsSync(), isFalse);
    expect(keep.existsSync(), isTrue);
    expect(exported.existsSync(), isTrue);
  });

  test('HTTP erasure requires bearer token and confirmation', () async {
    final client = MockClient((request) async {
      expect(request.method, 'DELETE');
      expect(request.followRedirects, isFalse);
      expect(request.url.path, '/api/v1/me');
      expect(request.headers['Authorization'], 'Bearer token-A');
      expect(jsonDecode(request.body), {'confirmation': 'DELETE'});
      return http.Response('{"ok":true}', 200);
    });
    await SyncApi(baseUrl: 'http://test/api/v1', client: client)
        .deleteAccount('token-A');
  });

  testWidgets(
      'explicit confirmation, shared blocker and duplicate submit prevention',
      (tester) async {
    late _Actions actions;
    await tester.pumpWidget(ProviderScope(overrides: [
      appActionsProvider.overrideWith((ref) => actions = _Actions(ref)),
    ], child: const MaterialApp(home: DeleteAccountPage())));
    final button =
        find.widgetWithText(FilledButton, L.t('account.deleteForever'));
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'DELETE');
    await tester.pump();
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    expect(actions.calls, 1);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    actions.done
        .completeError(SyncApiException(409, 'account_has_shared_pets'));
    await tester.pumpAndSettle();
    expect(find.text(L.t('account.sharedBlock')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('method-not-allowed shows "unavailable", not "check network"',
      (tester) async {
    late _Actions actions;
    await tester.pumpWidget(ProviderScope(overrides: [
      appActionsProvider.overrideWith((ref) => actions = _Actions(ref)),
    ], child: const MaterialApp(home: DeleteAccountPage())));
    final button =
        find.widgetWithText(FilledButton, L.t('account.deleteForever'));
    await tester.enterText(find.byType(TextField), 'DELETE');
    await tester.pump();
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    actions.done.completeError(SyncApiException(405, 'Method Not Allowed'));
    await tester.pumpAndSettle();
    expect(find.text(L.t('account.deleteUnavailable')), findsOneWidget);
    expect(find.text(L.t('account.deleteFailed')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('success returns to settings on a small screen with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late _Actions actions;
    await tester.pumpWidget(ProviderScope(
        overrides: [
          appActionsProvider.overrideWith((ref) => actions = _Actions(ref)),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!),
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                              builder: (_) => const DeleteAccountPage())),
                      child: const Text('settings')))),
        )));
    await tester.tap(find.text('settings'));
    await tester.pumpAndSettle();
    final scrollable = find.descendant(of: find.byType(ListView),
        matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.byType(TextField), 200,
        scrollable: scrollable);
    await tester.enterText(find.byType(TextField), 'DELETE');
    await tester.pump();
    final button =
        find.widgetWithText(FilledButton, L.t('account.deleteForever'));
    await tester.scrollUntilVisible(button, 200, scrollable: scrollable);
    await tester.tap(button);
    await tester.pump();
    actions.done.complete();
    await tester.pumpAndSettle();
    expect(find.byType(DeleteAccountPage), findsNothing);
    expect(find.text(L.t('account.deleted')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
