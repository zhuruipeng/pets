/// File transfer is separate from row synchronization and never runs inside a DB transaction.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

import 'sync_api.dart';

class PhotoSync {
  PhotoSync({required this.cacheDirectory});
  final Future<Directory> Function() cacheDirectory;

  Future<void> enqueueLegacyPhotos(Database db) async {
    final rows = await db.rawQuery('''
      SELECT a.*, r.pet_id FROM attachments a JOIN records r ON a.record_id = r.id
      JOIN pets p ON p.id = r.pet_id
      WHERE a.kind = 'photo' AND a.local_only = 0 AND a.deleted_at IS NULL
      AND r.deleted_at IS NULL AND p.deleted_at IS NULL
      AND (a.remote_url IS NULL OR a.remote_url = '') AND a.local_path IS NOT NULL
    ''');
    for (final row in rows) {
      if (!await File(row['local_path'] as String).exists()) {
        continue;
      }
      await db.insert(
          'sync_outbox',
          {
            'table_name': 'attachments',
            'row_id': row['id'],
            'pet_id': row['pet_id'],
            'op': 'upsert',
            'updated_at': row['updated_at'] ?? row['created_at']
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<void> prepare(
      Database db, SyncApi api, String token, SyncChange change) async {
    final payload = change.payload;
    if (change.table != 'attachments' ||
        change.isDelete ||
        payload['kind'] != 'photo' ||
        payload['local_only'] == 1 ||
        (payload['remote_url'] as String? ?? '').isNotEmpty) {
      return;
    }
    // Read the device-local path separately; it must never enter a wire snapshot.
    final rows = await db
        .query('attachments', where: 'id = ?', whereArgs: [change.rowId]);
    final path = rows.isEmpty ? null : rows.single['local_path'] as String?;
    if (path == null) {
      return;
    } // Historical metadata from another device has no original bytes.
    final file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('Photo file is missing', path);
    }
    if (await file.length() > SyncApi.maxPhotoBytes) {
      throw SyncApiException(413, 'Photo exceeds size limit');
    }
    final String remoteUrl;
    try {
      remoteUrl = await api.uploadPhoto(
          token: token,
          attachmentId: change.rowId,
          petId: change.petId!,
          recordId: payload['record_id'] as String,
          bytes: await file.readAsBytes());
    } on SyncApiException catch (error) {
      // Let row push and pull deliver authoritative revocations/deletions.
      if (error.statusCode == 403 || error.statusCode == 409) {
        return;
      }
      rethrow;
    }
    await db.transaction((txn) async {
      final current = await txn
          .query('attachments', where: 'id = ?', whereArgs: [change.rowId]);
      if (current.isEmpty ||
          current.single['local_path'] != path ||
          current.single['deleted_at'] != null ||
          current.single['local_only'] == 1) {
        return;
      }
      final timestamp = math.max(
          DateTime.now().millisecondsSinceEpoch,
          ((current.single['updated_at'] ?? current.single['created_at'])
                      as num)
                  .toInt() +
              1);
      // Updating the timestamp also upgrades old metadata already stored on the server.
      await txn.update(
          'attachments', {'remote_url': remoteUrl, 'updated_at': timestamp},
          where: 'id = ?', whereArgs: [change.rowId]);
    });
  }

  Future<void> downloadMissing(Database db, SyncApi api, String token) async {
    final rows = await db.rawQuery('''
      SELECT a.* FROM attachments a JOIN records r ON a.record_id = r.id
      JOIN pets p ON p.id = r.pet_id
      WHERE a.kind = 'photo' AND a.local_only = 0 AND a.deleted_at IS NULL
      AND r.deleted_at IS NULL AND p.deleted_at IS NULL AND a.remote_url IS NOT NULL
      AND (NOT EXISTS (SELECT 1 FROM members m WHERE m.pet_id = p.id)
        OR EXISTS (SELECT 1 FROM members m WHERE m.pet_id = p.id AND m.status = 'active'
          AND m.deleted_at IS NULL AND m.user_id = (SELECT value FROM sync_meta WHERE key = 'account_id')))
    ''');
    for (final row in rows) {
      final local = row['local_path'] as String?;
      if (local != null && await File(local).exists()) {
        continue;
      }
      final url = row['remote_url'] as String;
      final bytes = await api.downloadPhoto(token: token, remoteUrl: url);
      final directory = await cacheDirectory();
      await directory.create(recursive: true);
      final destination =
          File('${directory.path}/${row['id']}_${url.split('/').last}.img');
      final temporary = File('${destination.path}.${const Uuid().v4()}.part');
      try {
        await temporary.writeAsBytes(bytes, flush: true);
        if (await destination.exists()) {
          await destination.delete();
        }
        await temporary.rename(destination.path);
        await db.transaction((txn) async {
          await txn.insert('sync_meta', {'key': 'applying', 'value': '1'},
              conflictAlgorithm: ConflictAlgorithm.replace);
          await txn.update('attachments', {'local_path': destination.path},
              where: 'id = ? AND remote_url = ? AND deleted_at IS NULL',
              whereArgs: [row['id'], url]);
          await txn
              .delete('sync_meta', where: 'key = ?', whereArgs: ['applying']);
        });
      } finally {
        if (await temporary.exists()) {
          await temporary.delete();
        }
      }
    }
  }
}
