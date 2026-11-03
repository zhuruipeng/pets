/// Account working sets share one SQLite file, but never share rows or cursors.
library;

import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';

const _accountTables = [
  'users',
  'pets',
  'members',
  'records',
  'attachments',
  'expenses',
  'reminders',
  'reminder_logs',
  'walk_sessions',
  'walk_points',
  'pet_tags',
  'sync_outbox',
];

bool _accountMeta(String key) =>
    key == 'last_seq' ||
    key == 'last_sync_at' ||
    key == 'photo_sync_enabled' ||
    key.startsWith('backup_');

Set<String> _fileReferences(Object? value) {
  final result = <String>{};
  if (value is Map) {
    for (final entry in value.entries) {
      if ((entry.key == 'local_path' || entry.key == 'avatar_url') &&
          entry.value is String) {
        result.add(entry.value as String);
      } else {
        result.addAll(_fileReferences(entry.value));
      }
    }
  } else if (value is List) {
    for (final item in value) {
      result.addAll(_fileReferences(item));
    }
  }
  return result;
}

/// Erase only the active account, keeping other accounts' snapshots intact.
Future<void> eraseAccountData(DatabaseExecutor txn, String accountId) async {
  final paths = <String>{};
  for (final table in _accountTables) {
    paths.addAll(_fileReferences(await txn.query(table)));
  }
  final oldQueue = await txn.query('sync_meta',
      where: 'key = ?', whereArgs: ['deleted_account_files']);
  if (oldQueue.isNotEmpty) {
    paths.addAll((jsonDecode(oldQueue.single['value'] as String) as List)
        .cast<String>());
  }
  await txn.insert('sync_meta', {'key': 'applying', 'value': '1'},
      conflictAlgorithm: ConflictAlgorithm.replace);
  for (final table in _accountTables.reversed) {
    await txn.delete(table);
  }
  for (final row in await txn.query('sync_meta')) {
    final key = row['key'] as String;
    if (_accountMeta(key) ||
        {
          'account_id',
          'account_region',
          'token',
          'account_deletion_pending',
          'account_snapshot:$accountId'
        }.contains(key)) {
      await txn.delete('sync_meta', where: 'key = ?', whereArgs: [key]);
    }
  }
  // Shared file references in another local account must remain available.
  for (final row in await txn.query('sync_meta')) {
    if ((row['key'] as String).startsWith('account_snapshot:')) {
      paths.removeAll(_fileReferences(jsonDecode(row['value'] as String)));
    }
  }
  final now = DateTime.now().millisecondsSinceEpoch;
  await txn.insert('users', {
    'id': 'local-user',
    'nickname': '',
    'region': 'local',
    'created_at': now,
    'updated_at': now
  });
  // A fresh guest session is a separate working set. The next account login
  // must restore its saved snapshot instead of adopting the empty reset state.
  await txn.insert('sync_meta', {'key': 'account_id', 'value': 'local-reset'},
      conflictAlgorithm: ConflictAlgorithm.replace);
  await txn.insert('sync_meta',
      {'key': 'deleted_account_files', 'value': jsonEncode(paths.toList())},
      conflictAlgorithm: ConflictAlgorithm.replace);
  // Remains until a fresh login commits, even when platform clear() fails.
  await txn.insert(
      'sync_meta', {'key': 'session_pending', 'value': 'deleted-account'},
      conflictAlgorithm: ConflictAlgorithm.replace);
  await txn.delete('sync_meta', where: 'key = ?', whereArgs: ['applying']);
}

/// Retry app-owned file cleanup after a crash; never touch gallery/export files.
Future<void> purgeDeletedAccountFiles(Database db, Directory documents) async {
  final rows = await db.query('sync_meta',
      where: 'key = ?', whereArgs: ['deleted_account_files']);
  if (rows.isEmpty) return;
  final root = await documents.resolveSymbolicLinks();
  final protectedPaths = <String>{};
  for (final table in _accountTables) {
    protectedPaths.addAll(_fileReferences(await db.query(table)));
  }
  for (final row in await db.query('sync_meta')) {
    if ((row['key'] as String).startsWith('account_snapshot:')) {
      protectedPaths
          .addAll(_fileReferences(jsonDecode(row['value'] as String)));
    }
  }
  final protectedFiles = <String>{};
  for (final path in protectedPaths) {
    if (!p.isAbsolute(path)) continue;
    try {
      protectedFiles.add(await File(path).resolveSymbolicLinks());
    } on FileSystemException {
      // No file exists to protect.
    }
  }
  final remaining = <String>[];
  for (final path
      in (jsonDecode(rows.single['value'] as String) as List).cast<String>()) {
    if (!p.isAbsolute(path)) continue;
    try {
      final file = File(path);
      if (!await file.exists()) continue;
      final resolved = await file.resolveSymbolicLinks();
      if (!p.isWithin(root, resolved) || protectedFiles.contains(resolved)) {
        continue;
      }
      final parts = p.split(p.relative(resolved, from: root));
      if (parts.isEmpty ||
          !{'avatars', 'attachments', 'documents', 'synced-photos', 'restored'}
              .contains(parts.first)) {
        continue;
      }
      await file.delete();
    } on FileSystemException {
      remaining.add(path);
    }
  }
  if (remaining.isEmpty) {
    await db.delete('sync_meta',
        where: 'key = ?', whereArgs: ['deleted_account_files']);
  } else {
    await db.update('sync_meta', {'value': jsonEncode(remaining)},
        where: 'key = ?', whereArgs: ['deleted_account_files']);
  }
}

/// Called inside the same transaction as the session metadata update.
/// Snapshots contain local rows/file paths and pending writes, never tokens.
Future<void> adoptAccountData(
  DatabaseExecutor txn, {
  required String accountId,
  required String region,
  String? nickname,
  String? phone,
  String? email,
}) async {
  const guest = 'local-user';
  if (accountId == guest) return;
  final metadata = await txn.query('sync_meta');
  final users = await txn.query('users');
  final accountRows = metadata.where((r) => r['key'] == 'account_id');
  final previous = accountRows.isEmpty
      ? (users.isEmpty ? null : users.first['id'] as String?)
      : accountRows.first['value'] as String?;
  final targetSnapshot = await txn.query('sync_meta',
      where: 'key = ?', whereArgs: ['account_snapshot:$accountId'], limit: 1);
  final switching = previous != null &&
      previous != guest &&
      previous != accountId &&
      (previous != 'local-reset' || targetSnapshot.isNotEmpty);
  if (switching) {
    final snapshot = <String, dynamic>{};
    for (final table in _accountTables) {
      snapshot[table] = await txn.query(table);
    }
    snapshot['metadata'] = [
      for (final row in metadata)
        if (_accountMeta(row['key'] as String)) row
    ];
    await txn.insert(
        'sync_meta',
        {
          'key': 'account_snapshot:$previous',
          'value': jsonEncode(snapshot),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await txn.insert('sync_meta', {'key': 'applying', 'value': '1'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    for (final table in _accountTables.reversed) {
      await txn.delete(table);
    }
    for (final row in metadata) {
      if (_accountMeta(row['key'] as String)) {
        await txn
            .delete('sync_meta', where: 'key = ?', whereArgs: [row['key']]);
      }
    }
    final saved = await txn.query('sync_meta',
        where: 'key = ?', whereArgs: ['account_snapshot:$accountId'], limit: 1);
    if (saved.isNotEmpty) {
      final restored = jsonDecode(saved.first['value'] as String) as Map;
      for (final table in _accountTables) {
        for (final row in restored[table] as List) {
          await txn.insert(table, (row as Map).cast<String, Object?>());
        }
      }
      for (final row in restored['metadata'] as List) {
        await txn.insert('sync_meta', (row as Map).cast<String, Object?>(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await txn.delete('sync_meta',
          where: 'key = ?', whereArgs: ['account_snapshot:$accountId']);
    }
    await txn.delete('sync_meta', where: 'key = ?', whereArgs: ['applying']);
  }

  final existing = await txn.query('users',
      where: 'id = ?', whereArgs: [accountId], limit: 1);
  if (existing.isEmpty) {
    final local =
        await txn.query('users', where: 'id = ?', whereArgs: [guest], limit: 1);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (local.isNotEmpty) {
      await txn.update(
          'users',
          {
            'id': accountId,
            'region': region,
            if (nickname != null && nickname.trim().isNotEmpty)
              'nickname': nickname,
            'phone': local.first['phone'] ?? phone,
            'email': local.first['email'] ?? email,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [guest]);
      // The old placeholder outbox key no longer identifies a row.
      await txn.delete('sync_outbox',
          where: 'table_name = ? AND row_id = ?', whereArgs: ['users', guest]);
      for (final table in [
        'pets',
        'records',
        'expenses',
        'walk_sessions',
        'reminder_logs'
      ]) {
        await txn.update(table, {'created_by': accountId},
            where: 'created_by = ?', whereArgs: [guest]);
      }
    } else {
      // A fresh account profile is only a login placeholder; pull owns its
      // canonical timestamp. Do not upload it over a newer server profile.
      await txn.insert('sync_meta', {'key': 'applying', 'value': '1'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('users', {
        'id': accountId,
        'nickname': nickname ?? '',
        'region': region,
        'phone': phone,
        'email': email,
        'created_at': now,
        'updated_at': 0,
      });
      await txn.delete('sync_meta', where: 'key = ?', whereArgs: ['applying']);
    }
  }
  await txn.insert('sync_meta', {'key': 'account_id', 'value': accountId},
      conflictAlgorithm: ConflictAlgorithm.replace);
  await txn.insert('sync_meta', {'key': 'account_region', 'value': region},
      conflictAlgorithm: ConflictAlgorithm.replace);
}
