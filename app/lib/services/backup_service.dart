import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../core/region.dart';
import '../data/db/schema.dart';

const _tables = [
  'pets',
  'records',
  'reminders',
  'attachments',
  'expenses',
  'reminder_logs',
  'walk_sessions',
  'walk_points',
  'pet_tags'
];
const _maxBytes = 512 * 1024 * 1024;
const _maxManifestBytes = 16 * 1024 * 1024;
const _maxEntries = 20000;
const _format = 'mypet-local-backup';

class BackupPreview {
  const BackupPreview(
      {required this.id,
      required this.createdAt,
      required this.pets,
      required this.records,
      required this.files,
      required this.region});
  factory BackupPreview.fromManifest(Map<String, dynamic> manifest) {
    final tables = manifest['tables'] as Map;
    return BackupPreview(
        id: manifest['id'] as String,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(manifest['created_at'] as int),
        pets: (tables['pets'] as List).length,
        records: (tables['records'] as List).length,
        files: (manifest['files'] as List).length,
        region: manifest['region'] as String);
  }
  final String id, region;
  final DateTime createdAt;
  final int pets, records, files;
}

class BackupInventory {
  const BackupInventory(
      {required this.pets,
      required this.records,
      required this.attachments,
      this.lastGenerated});
  final int pets, records, attachments;
  final DateTime? lastGenerated;
}

/// Portable data, never session credentials, membership grants or sync cursors.
/// Restores independent UUID copies so old snapshots cannot overwrite shared data.
class BackupService {
  BackupService(
      {required this.db,
      required this.documentsPath,
      this.region = AppRegion.current});
  final Database db;
  final String documentsPath;
  final Region region;
  bool _running = false;

  Future<BackupInventory> inventory() => db.transaction((txn) async {
        Future<int> count(String sql) async =>
            Sqflite.firstIntValue(await txn.rawQuery(sql)) ?? 0;
        final pets = await count('SELECT COUNT(*) FROM pets');
        final records = await count(
            'SELECT COUNT(*) FROM records WHERE pet_id IN (SELECT id FROM pets)');
        final attachments = await count(
            'SELECT COUNT(*) FROM attachments WHERE record_id IN (SELECT id FROM records WHERE pet_id IN (SELECT id FROM pets))');
        final rows = await txn.query('sync_meta',
            where: 'key = ?', whereArgs: ['backup_last_generated']);
        final time = rows.isEmpty
            ? null
            : int.tryParse(rows.first['value'] as String? ?? '');
        return BackupInventory(
            pets: pets,
            records: records,
            attachments: attachments,
            lastGenerated: time == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(time));
      });

  // Generation is confirmed; the native share sheet cannot confirm file saving.
  Future<void> markGenerated(BackupPreview preview) async {
    await db.insert(
        'sync_meta',
        {
          'key': 'backup_last_generated',
          'value': preview.createdAt.millisecondsSinceEpoch.toString()
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    if (_running) throw StateError('backup.busy');
    _running = true;
    try {
      return await action();
    } finally {
      _running = false;
    }
  }

  Future<File> exportTo(String outputPath) => _exclusive(() async {
        final snapshot = await db.transaction((txn) async {
          final tables = <String, List<Map<String, Object?>>>{};
          for (final table in _tables) {
            // Only rows related to locally available pets belong to this snapshot.
            final scope = switch (table) {
              'pets' => '',
              'attachments' =>
                ' WHERE record_id IN (SELECT id FROM records WHERE pet_id IN (SELECT id FROM pets))',
              'walk_points' =>
                ' WHERE session_id IN (SELECT id FROM walk_sessions WHERE pet_id IN (SELECT id FROM pets))',
              _ => ' WHERE pet_id IN (SELECT id FROM pets)',
            };
            tables[table] = (await txn.rawQuery('SELECT * FROM $table$scope'))
                .map((row) => Map<String, Object?>.from(row))
                .toList();
          }
          final users = await txn.query('users', limit: 1);
          final contact = users.isEmpty
              ? <String, Object?>{}
              : {
                  for (final key in [
                    'nickname',
                    'phone',
                    'email',
                    'wechat',
                    'contact_note'
                  ])
                    key: users.first[key],
                };
          return <String, dynamic>{
            'format': _format,
            'version': 1,
            'schema': kSchemaVersion,
            'id': const Uuid().v4(),
            'created_at': DateTime.now().millisecondsSinceEpoch,
            'region': region.name,
            'tables': tables,
            'contact': contact
          };
        });
        // File IO and compression stay off the UI isolate. No SQLite handles cross it.
        final job = {'snapshot': snapshot, 'output': outputPath};
        await Isolate.run(() => _writeBackup(job));
        return File(outputPath);
      });

  Future<BackupPreview> inspect(String path) async {
    final manifest = await Isolate.run(() => _readBackup(path));
    _checkManifest(manifest, region);
    return BackupPreview.fromManifest(manifest);
  }

  Future<List<String>> restore(String path,
          {required String expectedId, bool restoreContact = false}) =>
      _exclusive(() async {
        final stage = p.join(documentsPath, 'restored', const Uuid().v4());
        try {
          final manifest =
              await Isolate.run(() => _readBackup(path, destination: stage));
          _checkManifest(manifest, region);
          if (manifest['id'] != expectedId) throw StateError('backup.changed');
          final snapshotId = manifest['id'] as String;
          final rawTables = manifest['tables'] as Map;
          final tables = <String, List<Map<String, Object?>>>{
            for (final table in _tables)
              table: (rawTables[table] as List)
                  .map((r) => Map<String, Object?>.from(r as Map))
                  .toList(),
          };
          final ids = <String, Map<String, String>>{};
          for (final table in _tables) {
            ids[table] = {};
            final columns = (await db.rawQuery('PRAGMA table_info($table)'))
                .map((r) => r['name'])
                .toSet();
            for (final row in tables[table]!) {
              final id = row['id'];
              if (id is! String ||
                  id.isEmpty ||
                  ids[table]!.containsKey(id) ||
                  row.keys.any((key) => !columns.contains(key)) ||
                  row.values
                      .any((v) => v != null && v is! String && v is! num)) {
                throw StateError('backup.invalid');
              }
              ids[table]![id] = const Uuid().v4();
            }
          }
          String remap(String table, Object? old) {
            final value = ids[table]?[old];
            if (value == null) throw StateError('backup.invalid');
            return value;
          }

          // Completion IDs encode the reminder and occurrence. Keep the sync
          // protocol's identity rule while assigning each restored course a new UUID.
          for (final row in tables['records']!) {
            if (row['payload'] is! String) continue;
            final payload = jsonDecode(row['payload'] as String);
            if (payload is! Map) throw StateError('backup.invalid');
            if (payload['course_id'] != null) {
              if (payload['due_at'] is! int) throw StateError('backup.invalid');
              final courseId = remap('reminders', payload['course_id']);
              ids['records']![row['id'] as String] =
                  'dose_${courseId}_${payload['due_at']}';
            }
          }
          for (final row in tables['reminder_logs']!) {
            if (row['due_at'] is! int) throw StateError('backup.invalid');
            final reminderId = remap('reminders', row['reminder_id']);
            ids['reminder_logs']![row['id'] as String] =
                'log_${reminderId}_${row['due_at']}';
          }
          if (ids.values
              .any((map) => map.values.toSet().length != map.length)) {
            throw StateError('backup.invalid');
          }

          final now = DateTime.now().millisecondsSinceEpoch;
          return await db.transaction((txn) async {
            final duplicate = await txn.query('sync_meta',
                where: 'key = ?', whereArgs: ['backup_restored:$snapshotId']);
            if (duplicate.isNotEmpty) {
              throw StateError('backup.alreadyRestored');
            }
            final users = await txn.query('users', limit: 1);
            if (users.isEmpty) throw StateError('backup.noUser');
            final currentUserId = users.first['id'];
            for (final table in _tables) {
              for (final source in tables[table]!) {
                final row = Map<String, Object?>.from(source);
                row['id'] = remap(table, source['id']);
                if (row.containsKey('pet_id') && row['pet_id'] != null) {
                  row['pet_id'] = remap('pets', row['pet_id']);
                }
                if (table == 'attachments') {
                  row['record_id'] = remap('records', row['record_id']);
                }
                if (table == 'walk_points') {
                  row['session_id'] = remap('walk_sessions', row['session_id']);
                }
                if (table == 'reminder_logs') {
                  row['reminder_id'] = remap('reminders', row['reminder_id']);
                }
                if ((table == 'expenses' || table == 'reminder_logs') &&
                    row['record_id'] != null) {
                  row['record_id'] = remap('records', row['record_id']);
                }
                if (row.containsKey('created_by')) {
                  // Historical completion names are data, not a new assertion
                  // that the importing account performed the original care.
                  row['created_by'] =
                      table == 'reminder_logs' ? null : currentUserId;
                }
                if (row.containsKey('updated_at')) row['updated_at'] = now;
                if (table == 'walk_sessions') row['region'] = region.name;
                // Pause recovered schedules until the owner reviews them, avoiding duplicate doses.
                if (table == 'reminders') row['enabled'] = 0;
                if (table == 'records' && row['payload'] is String) {
                  final payload = Map<String, dynamic>.from(
                      jsonDecode(row['payload'] as String) as Map);
                  if (payload['actor_name'] is String) {
                    payload['backup_actor_name'] ??= payload['actor_name'];
                  }
                  for (final entry in {
                    'medical_record_id': 'records',
                    'course_reminder_id': 'reminders',
                    'course_id': 'reminders'
                  }.entries) {
                    if (payload[entry.key] != null) {
                      payload[entry.key] =
                          ids[entry.value]?[payload[entry.key]];
                    }
                  }
                  row['payload'] = jsonEncode(payload);
                }
                for (final field in table == 'pets'
                    ? ['avatar_url']
                    : table == 'attachments'
                        ? ['local_path']
                        : <String>[]) {
                  final value = row[field];
                  if (value is String && value.startsWith('backup:files/')) {
                    row[field] = p.join(stage, p.basename(value.substring(7)));
                  } else if (field == 'local_path' && value != null) {
                    throw StateError('backup.invalid');
                  } else if (field == 'avatar_url' &&
                      value is String &&
                      !value.startsWith('https://') &&
                      !value.startsWith('http://')) {
                    throw StateError('backup.invalid');
                  }
                }
                await txn.insert(table, row,
                    conflictAlgorithm: ConflictAlgorithm.abort);
              }
            }
            if (restoreContact) {
              final contact = manifest['contact'] as Map;
              final values = <String, Object?>{};
              // Email belongs to the signed-in identity. Do not change it during a restore.
              for (final key in [
                'nickname',
                'phone',
                'wechat',
                'contact_note'
              ]) {
                final value = contact[key];
                if (value != null && value is! String) {
                  throw StateError('backup.invalid');
                }
                if (value != null) values[key] = value;
              }
              if (values.isNotEmpty) {
                await txn.update('users', {...values, 'updated_at': now},
                    where: 'id = ?', whereArgs: [currentUserId]);
              }
            }
            await txn.insert('sync_meta',
                {'key': 'backup_restored:$snapshotId', 'value': '$now'});
            // Deleted pets have no owner bootstrap on the server. Keep these
            // tombstones locally without creating permanently forbidden uploads.
            for (final pet
                in tables['pets']!.where((row) => row['deleted_at'] != null)) {
              await txn.delete('sync_outbox',
                  where: 'pet_id = ?', whereArgs: [ids['pets']![pet['id']]]);
            }
            return tables['pets']!
                .where(
                    (r) => r['deleted_at'] == null && r['archived_at'] == null)
                .map((r) => ids['pets']![r['id']]!)
                .toList();
          });
        } catch (_) {
          final dir = Directory(stage);
          if (await dir.exists() &&
              p.isWithin(p.absolute(documentsPath), p.absolute(stage))) {
            await dir.delete(recursive: true);
          }
          rethrow;
        }
      });
}

void _checkManifest(Map<String, dynamic> manifest, Region region) {
  if (manifest['format'] != _format ||
      manifest['version'] != 1 ||
      manifest['schema'] != kSchemaVersion ||
      manifest['id'] is! String ||
      manifest['created_at'] is! int ||
      manifest['contact'] is! Map ||
      manifest['tables'] is! Map ||
      manifest['files'] is! List ||
      _tables.any((table) => (manifest['tables'] as Map)[table] is! List)) {
    throw StateError('backup.invalid');
  }
  if (manifest['region'] != region.name) {
    throw StateError('backup.regionMismatch');
  }
}

Future<void> _writeBackup(Map<String, dynamic> job) async {
  final snapshot = job['snapshot'] as Map<String, dynamic>;
  final files = <Map<String, dynamic>>[];
  final paths = <String, String>{};
  var total = 0;
  final tables = snapshot['tables'] as Map;
  for (final table in ['pets', 'attachments']) {
    final field = table == 'pets' ? 'avatar_url' : 'local_path';
    for (final raw in tables[table] as List) {
      final row = raw as Map;
      final value = row[field];
      if (value == null ||
          value == '' ||
          (value as String).startsWith('https://') ||
          value.startsWith('http://')) {
        continue;
      }
      final source = File(value);
      if (!await source.exists()) {
        // Metadata from another device may have a remote URL but no local cache.
        if (table == 'attachments' &&
            row['remote_url'] is String &&
            (row['remote_url'] as String).isNotEmpty) {
          row[field] = null;
          continue;
        }
        throw StateError('backup.missingFile');
      }
      var key = paths[value];
      if (key == null) {
        final size = await source.length();
        total += size;
        if (total > _maxBytes || files.length >= _maxEntries) {
          throw StateError('backup.tooLarge');
        }
        final ext = p.extension(value).toLowerCase();
        key =
            'files/${const Uuid().v4()}${RegExp(r'^\.[a-z0-9]{1,10}$').hasMatch(ext) ? ext : '.bin'}';
        final digest = await sha256.bind(source.openRead()).first;
        files.add({
          'name': key,
          'size': size,
          'sha256': digest.toString(),
          'source': value
        });
        paths[value] = key;
      }
      row[field] = 'backup:$key';
    }
  }
  snapshot['files'] = [
    for (final file in files)
      {
        for (final key in ['name', 'size', 'sha256']) key: file[key]
      }
  ];
  final bytes = utf8.encode(jsonEncode(snapshot));
  if (bytes.length > _maxManifestBytes || total + bytes.length > _maxBytes) {
    throw StateError('backup.tooLarge');
  }
  final output = File(job['output'] as String);
  await output.parent.create(recursive: true);
  final encoder = ZipFileEncoder();
  encoder.create(output.path);
  try {
    encoder.addArchiveFile(ArchiveFile('manifest.json', bytes.length, bytes));
    for (final file in files) {
      await encoder.addFile(
          File(file['source'] as String), file['name'] as String);
    }
    await encoder.close();
    if (await output.length() > _maxBytes) throw StateError('backup.tooLarge');
  } catch (_) {
    try {
      await encoder.close();
    } catch (_) {/* Preserve the original failure. */}
    if (await output.exists()) await output.delete();
    rethrow;
  }
}

/// Preflight ZIP headers before decompression; never extract archive-controlled paths.
Future<Map<String, dynamic>> _readBackup(String path,
    {String? destination}) async {
  final source = File(path);
  if (await source.length() > _maxBytes) throw StateError('backup.tooLarge');
  final input = InputFileStream(path);
  try {
    final directory = ZipDirectory()..read(input);
    final names = <String>{};
    var total = 0;
    if (directory.fileHeaders.length > _maxEntries + 1) {
      throw StateError('backup.tooLarge');
    }
    for (final header in directory.fileHeaders) {
      final name = header.filename;
      total += header.uncompressedSize;
      if (total > _maxBytes ||
          (name == 'manifest.json' &&
              header.uncompressedSize > _maxManifestBytes)) {
        throw StateError('backup.tooLarge');
      }
      if (!names.add(name) ||
          (header.externalFileAttributes >> 16 & 0xf000) == 0xa000 ||
          (name != 'manifest.json' &&
              !RegExp(r'^files/[a-f0-9-]{36}\.[a-z0-9]{1,10}$')
                  .hasMatch(name))) {
        throw StateError('backup.invalid');
      }
    }
    input.position = 0;
    final archive = ZipDecoder().decodeStream(input);
    final entry = archive.find('manifest.json');
    if (entry == null || !entry.isFile) throw StateError('backup.invalid');
    final bytes = (await _unpackEntry(entry, entry.size))!;
    if (bytes.length != entry.size || getCrc32(bytes) != entry.crc32) {
      throw StateError('backup.invalid');
    }
    final manifest =
        Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
    if (manifest['files'] is! List) throw StateError('backup.invalid');
    final declared = <String>{'manifest.json'};
    for (final raw in manifest['files'] as List) {
      final spec = raw as Map;
      final name = spec['name'];
      final file = name is String ? archive.find(name) : null;
      if (file == null ||
          !file.isFile ||
          file.isSymbolicLink ||
          !declared.add(name as String) ||
          file.size != spec['size'] ||
          spec['sha256'] is! String) {
        throw StateError('backup.invalid');
      }
      // Bound actual decompressed bytes as well as the ZIP header's claimed size.
      final temporary = destination == null
          ? await Directory.systemTemp.createTemp('mypet-verify-')
          : Directory(destination);
      await temporary.create(recursive: true);
      final out = File(p.join(temporary.path, p.basename(name)));
      try {
        await _unpackEntry(file, file.size, output: out);
        if (await out.length() != spec['size'] ||
            (await sha256.bind(out.openRead()).first).toString() !=
                spec['sha256']) {
          throw StateError('backup.invalid');
        }
      } finally {
        if (destination == null &&
            p.isWithin(p.absolute(Directory.systemTemp.path),
                p.absolute(temporary.path))) {
          await temporary.delete(recursive: true);
        }
      }
    }
    if (declared.length != names.length) throw StateError('backup.invalid');
    // Every portable local path must reference an actual packaged file.
    if (manifest['tables'] is! Map) throw StateError('backup.invalid');
    final tables = manifest['tables'] as Map;
    for (final table in ['pets', 'attachments']) {
      if (tables[table] is! List) throw StateError('backup.invalid');
      final field = table == 'pets' ? 'avatar_url' : 'local_path';
      for (final raw in tables[table] as List) {
        final value = (raw as Map)[field];
        if (value is String &&
            value.startsWith('backup:') &&
            !declared.contains(value.substring(7))) {
          throw StateError('backup.invalid');
        }
      }
    }
    return manifest;
  } on StateError {
    rethrow;
  } catch (_) {
    throw StateError('backup.invalid');
  } finally {
    await input.close();
  }
}

/// archive's native decodeStream buffers all output until close. Use dart:io's
/// asynchronous decoder to enforce real limits before allocation or disk writes.
Future<List<int>?> _unpackEntry(ArchiveFile file, int limit,
    {File? output}) async {
  final raw = file.rawContent?.getStream(decompress: false);
  if (raw == null) throw StateError('backup.invalid');
  Stream<List<int>> chunks() async* {
    while (!raw.isEOS) {
      yield raw
          .readBytes(raw.length > 65536 ? 65536 : raw.length)
          .toUint8List();
    }
  }

  final Stream<List<int>> decoded;
  if (file.compression == CompressionType.deflate) {
    decoded = chunks().transform(ZLibCodec(raw: true).decoder);
  } else if (file.compression == CompressionType.none) {
    decoded = chunks();
  } else {
    throw StateError('backup.invalid');
  }
  var size = 0;
  final bytes = output == null ? BytesBuilder(copy: false) : null;
  final sink = output?.openWrite();
  try {
    await for (final chunk in decoded) {
      size += chunk.length;
      if (size > limit) throw StateError('backup.invalid');
      if (sink == null) {
        bytes!.add(chunk);
      } else {
        sink.add(chunk);
        await sink.flush();
      }
    }
    if (size != limit) throw StateError('backup.invalid');
    return bytes?.takeBytes();
  } finally {
    await sink?.close();
  }
}
