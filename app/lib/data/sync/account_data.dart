/// Account working sets share one SQLite file, but never share rows or cursors.
library;

import 'dart:convert';
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
    key == 'last_seq' || key == 'last_sync_at' || key.startsWith('backup_');

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
  final switching =
      previous != null && previous != guest && previous != accountId;
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
