import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pet_app/data/db/schema.dart';
import 'package:pet_app/data/repositories/user_repository.dart';
import 'package:pet_app/data/sync/photo_sync.dart';
import 'package:pet_app/data/sync/sync_api.dart';
import 'package:pet_app/data/sync/sync_engine.dart';
import 'package:pet_app/data/sync/token_store.dart';
import 'package:pet_app/core/l10n.dart';
import 'package:pet_app/data/models.dart';
import 'package:pet_app/providers.dart';
import 'package:pet_app/ui/me_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aS1sAAAAASUVORK5CYII=');

class _SignedIn extends SyncController {
  @override
  SyncStatus build() => const SyncStatus(phase: SyncPhase.idle);
  @override
  Future<void> refresh() async {}
}

class _NoPets extends PetsNotifier {
  @override
  Future<List<Pet>> build() async => [];
}

class _Cloud extends SyncApi {
  _Cloud() : super(baseUrl: 'http://127.0.0.1:1');
  final changes = <SyncChange>[];
  final files = <String, Uint8List>{};
  var uploads = 0;
  var failPhotoPush = false;
  var deleteParentBeforeUpload = false;
  @override
  Future<String> uploadPhoto(
      {required String token,
      required String attachmentId,
      required String petId,
      required String recordId,
      required Uint8List bytes}) async {
    expect(changes.any((c) => c.table == 'pets' && c.rowId == petId), isTrue);
    expect(changes.any((c) => c.table == 'records' && c.rowId == recordId),
        isTrue);
    if (deleteParentBeforeUpload) {
      final pet = changes.firstWhere((c) => c.table == 'pets');
      changes.add(SyncChange(
          table: 'pets',
          rowId: petId,
          op: 'delete',
          updatedAt: 2,
          payload: {...pet.payload, 'updated_at': 2, 'deleted_at': 2},
          seq: changes.length + 1));
      throw SyncApiException(404, 'Parent was deleted by another device');
    }
    final path = '/media/photos/$attachmentId/${sha256.convert(bytes)}';
    files[path] = bytes;
    uploads++;
    return path;
  }

  @override
  Future<Uint8List> downloadPhoto(
          {required String token, required String remoteUrl}) async =>
      files[remoteUrl]!;
  @override
  Future<PushResult> push(
      {required String token,
      required String deviceId,
      required List<SyncChange> changes}) async {
    if (failPhotoPush && changes.any((c) => c.table == 'attachments')) {
      throw StateError('network disconnected after upload');
    }
    for (final c in changes) {
      if (c.table == 'attachments') {
        expect(c.payload.containsKey('local_path'), isFalse);
      }
      this.changes.add(SyncChange(
          table: c.table,
          rowId: c.rowId,
          op: c.op,
          payload: c.payload,
          updatedAt: c.updatedAt,
          seq: this.changes.length + 1));
    }
    return PushResult(applied: changes, rejected: const []);
  }

  @override
  Future<PullResult> pull(
          {required String token, required int since, int limit = 200}) async =>
      PullResult(
          changes: changes.where((c) => c.seq! > since).toList(),
          nextSince: changes.length,
          hasMore: false);
}

void main() {
  testWidgets(
      'photo consent and sharing explanation fit a narrow screen with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
        overrides: [
          syncControllerProvider.overrideWith(_SignedIn.new),
          petsProvider.overrideWith(_NoPets.new),
          currentUserProvider.overrideWith((ref) async => null),
          myInvitesProvider.overrideWith((ref) async => []),
          photoSyncEnabledProvider.overrideWith((ref) async => false),
        ],
        child: MaterialApp(
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!),
            home: const Scaffold(body: MeScreen()))));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text(L.t('sync.photos')), 150,
        scrollable: find.byType(Scrollable).first);
    expect(find.text(L.t('sync.photosHint')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  late Directory directory;
  final databases = <Database>[];
  late _Cloud cloud;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pet-photo-test-');
    cloud = _Cloud();
  });
  tearDown(() async {
    for (final db in databases) {
      await db.close();
    }
    databases.clear();
    await directory.delete(recursive: true);
  });

  Future<(Database, SyncEngine)> device(String name) async {
    sqfliteFfiInit();
    final db =
        await databaseFactoryFfi.openDatabase('${directory.path}/$name.db',
            options: OpenDatabaseOptions(
                version: kSchemaVersion,
                onCreate: (db, _) async {
                  for (final statement in onCreate) {
                    await db.execute(statement);
                  }
                }));
    databases.add(db);
    return (
      db,
      SyncEngine(
          dbProvider: () => db,
          tokenStore: MemoryTokenStore('token'),
          api: cloud,
          photoSync: PhotoSync(
              cacheDirectory: () async => Directory('${directory.path}/$name')))
    );
  }

  Future<void> seed(Database db) async {
    final original = File('${directory.path}/original.png');
    await original.writeAsBytes(_png);
    await db.insert('pets', {
      'id': 'pet',
      'name': 'Pet',
      'species': 'dog',
      'created_by': 'user',
      'created_at': 1,
      'updated_at': 1
    });
    await db.insert('records', {
      'id': 'record',
      'pet_id': 'pet',
      'type': 'note',
      'recorded_at': 1,
      'created_by': 'user',
      'created_at': 1,
      'updated_at': 1
    });
    await db.insert('attachments', {
      'id': 'photo',
      'record_id': 'record',
      'kind': 'photo',
      'local_path': original.path,
      'created_at': 1,
      'updated_at': 1
    });
    await db.insert('attachments', {
      'id': 'document',
      'record_id': 'record',
      'kind': 'document',
      'local_path': '${directory.path}/private.pdf',
      'local_only': 1,
      'created_at': 1,
      'updated_at': 1
    });
  }

  test('two devices share actual photo bytes; local documents never upload',
      () async {
    final (a, engineA) = await device('A');
    await seed(a);
    await engineA.setPhotoSyncEnabled(true);
    final reportA = await engineA.sync();
    expect(reportA.ok, isTrue, reason: '${reportA.error}');
    expect(cloud.uploads, 1);
    expect(await engineA.pendingCount(), 0);
    final (b, engineB) = await device('B');
    await engineB.setPhotoSyncEnabled(true);
    final reportB = await engineB.sync();
    expect(reportB.ok, isTrue, reason: '${reportB.error}');
    final photo = (await b.query('attachments')).single;
    final downloaded = File(photo['local_path'] as String);
    expect(await downloaded.readAsBytes(), _png);
    expect(
        downloaded.path,
        isNot((await a.query('attachments', where: "kind = 'photo'"))
            .single['local_path']));
    expect(await engineB.pendingCount(), 0,
        reason: 'Downloaded paths must not loop back into sync');
  });

  test(
      'upload succeeds but metadata push fails; retry preserves queue and reuses blob',
      () async {
    final (db, engine) = await device('retry');
    await seed(db);
    await engine.setPhotoSyncEnabled(true);
    cloud.failPhotoPush = true;
    expect((await engine.sync()).ok, isFalse);
    expect(await engine.pendingCount(), 1);
    expect(cloud.uploads, 1);
    cloud.failPhotoPush = false;
    expect((await engine.sync()).ok, isTrue);
    expect(cloud.uploads, 1);
    expect(await engine.pendingCount(), 0);
  });

  test(
      'photo upload error still receives parent deletion and clears obsolete queue on retry',
      () async {
    final (db, engine) = await device('deleted-parent');
    await seed(db);
    await engine.setPhotoSyncEnabled(true);
    cloud.deleteParentBeforeUpload = true;
    final report = await engine.sync();
    expect(report.ok, isFalse);
    expect(report.pulled, greaterThan(0));
    expect((await db.query('pets')).single['deleted_at'], 2);
    expect((await engine.sync()).ok, isTrue);
    expect(await engine.pendingCount(), 0);
  });

  test(
      'photo transfer requires opt-in and upgrades already acknowledged old metadata',
      () async {
    final (db, engine) = await device('consent');
    await seed(db);
    expect(await engine.photoSyncEnabled(), isFalse);
    expect((await engine.sync()).ok, isTrue);
    expect(cloud.uploads, 0);
    expect(await engine.pendingCount(), 0);
    await engine.setPhotoSyncEnabled(true);
    expect((await engine.sync()).ok, isTrue);
    expect(cloud.uploads, 1);
    expect(
        (await db.query('attachments', where: "kind = 'photo'"))
            .single['remote_url'],
        isNotNull);
  });

  test(
      'photo consent follows each account rather than the previous signed-in user',
      () async {
    final (db, engine) = await device('accounts');
    await db.insert('users', {
      'id': 'local-user',
      'nickname': 'Guest',
      'region': 'local',
      'created_at': 1,
      'updated_at': 1
    });
    final users = UserRepository(db);
    await users.adoptAccount(accountId: 'A', region: 'intl');
    await engine.setPhotoSyncEnabled(true);
    await users.adoptAccount(accountId: 'B', region: 'intl');
    expect(await engine.photoSyncEnabled(), isFalse);
    await users.adoptAccount(accountId: 'A', region: 'intl');
    expect(await engine.photoSyncEnabled(), isTrue);
  });

  test(
      'HTTP upload and download carry authentication and verify original bytes',
      () async {
    final digest = sha256.convert(_png).toString();
    final path = '/media/photos/photo/$digest';
    final api = SyncApi(
        baseUrl: 'https://regional.example/api/v1',
        client: MockClient((request) async {
          expect(request.headers['Authorization'], 'Bearer secret');
          expect(request.url.host, 'regional.example');
          if (request.method == 'PUT') {
            expect(request.bodyBytes, _png);
            expect(request.url.queryParameters['record_id'], 'record');
            return http.Response(
                jsonEncode({
                  'remote_url': path,
                  'sha256': digest,
                  'size_bytes': _png.length
                }),
                200);
          }
          return http.Response.bytes(_png, 200);
        }));
    expect(
        await api.uploadPhoto(
            token: 'secret',
            attachmentId: 'photo',
            petId: 'pet',
            recordId: 'record',
            bytes: _png),
        path);
    expect(await api.downloadPhoto(token: 'secret', remoteUrl: path), _png);
  });

  test(
      'download rejects tampered bytes, redirects and external token destinations',
      () async {
    var status = 200;
    var calls = 0;
    final api = SyncApi(
        baseUrl: 'https://regional.example/api/v1',
        client: MockClient((request) async {
          calls++;
          expect(request.followRedirects, isFalse);
          return http.Response.bytes([1, 2, 3], status,
              headers: {'location': 'https://evil.example'});
        }));
    final path = '/media/photos/photo/${sha256.convert(_png)}';
    await expectLater(api.downloadPhoto(token: 'secret', remoteUrl: path),
        throwsA(isA<SyncApiException>()));
    status = 302;
    await expectLater(api.downloadPhoto(token: 'secret', remoteUrl: path),
        throwsA(isA<SyncApiException>()));
    await expectLater(
        api.downloadPhoto(
            token: 'secret', remoteUrl: 'https://evil.example/photo'),
        throwsA(isA<SyncApiException>()));
    expect(calls, 2);
  });
}
