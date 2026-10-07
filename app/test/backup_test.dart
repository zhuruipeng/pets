import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pet_app/core/region.dart';
import 'package:pet_app/data/db/schema.dart';
import 'package:pet_app/data/models.dart';
import 'package:pet_app/data/repositories/pet_repository.dart';
import 'package:pet_app/data/repositories/record_repository.dart';
import 'package:pet_app/data/repositories/reminder_repository.dart';
import 'package:pet_app/domain/medication_course.dart';
import 'package:pet_app/domain/symptom_observation.dart';
import 'package:pet_app/services/backup_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> database(String userId) async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(
          singleInstance: false,
          onCreate: (db, _) async {
            for (final sql in onCreate) {
              await db.execute(sql);
            }
          },
          version: kSchemaVersion));
  await db.insert('users', {
    'id': userId,
    'nickname': userId,
    'region': 'intl',
    'email': '$userId@example.com',
    'phone': userId == 'source' ? '12345' : null,
    'created_at': 1,
    'updated_at': 1
  });
  return db;
}

Future<File> rewrite(File original, File output,
    {void Function(Map<String, dynamic>)? manifestChange,
    bool damageFile = false,
    String? extraName}) async {
  final decoded = ZipDecoder().decodeBytes(await original.readAsBytes());
  final archive = Archive();
  for (final file in decoded) {
    List<int> bytes = file.content;
    if (file.name == 'manifest.json' && manifestChange != null) {
      final manifest =
          Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
      manifestChange(manifest);
      bytes = utf8.encode(jsonEncode(manifest));
    } else if (file.name.startsWith('files/') && damageFile) {
      bytes = List<int>.filled(file.size, 42);
    }
    archive.addFile(ArchiveFile(file.name, bytes.length, bytes));
  }
  if (extraName != null) archive.addFile(ArchiveFile(extraName, 1, [1]));
  return output..writeAsBytesSync(ZipEncoder().encode(archive));
}

void main() {
  late Database source, target;
  late Directory temp;
  late BackupService exporter, importer;
  late File backup;
  late Pet pet;
  late String medicalId, courseId;
  final eventAt = DateTime(2026, 10, 7, 9);
  setUp(() async {
    source = await database('source');
    target = await database('target');
    temp = await Directory.systemTemp.createTemp('mypet-backup-test-');
    exporter = BackupService(
        db: source, documentsPath: temp.path, region: Region.intl);
    importer = BackupService(
        db: target,
        documentsPath: p.join(temp.path, 'new-device'),
        region: Region.intl);
    pet = await PetRepository(source)
        .createSimple(name: 'Buddy', speciesWire: 'dog', createdBy: 'source');
    final visit = await RecordRepository(source).createSimple(
        petId: pet.id,
        type: RecordType.medical,
        recordedAt: eventAt,
        createdBy: 'source',
        valueText: 'Visit');
    medicalId = visit.id;
    final course = await ReminderRepository(source).createCourse(
        petId: pet.id,
        now: eventAt,
        course: MedicationCourse(
            name: 'Medicine',
            dose: '1 tablet',
            start: eventAt,
            end: DateTime(2026, 10, 10),
            times: [600],
            stock: 8));
    courseId = course.id;
    final observation = await RecordRepository(source).createSimple(
        petId: pet.id,
        type: RecordType.symptom,
        recordedAt: eventAt,
        createdBy: 'source',
        payload: SymptomObservation(
                count: 2,
                medicalRecordId: visit.id,
                courseReminderId: course.id)
            .toPayload());
    final photo = File(p.join(temp.path, 'photo.jpg'))
      ..writeAsBytesSync([1, 2, 3, 4]);
    await source.update('pets', {'avatar_url': photo.path},
        where: 'id = ?', whereArgs: [pet.id]);
    final document = File(p.join(temp.path, 'report.pdf'))
      ..writeAsBytesSync(utf8.encode('vet document'));
    for (final entry in [(photo, 'photo'), (document, 'document')]) {
      await source.insert('attachments', {
        'id': entry.$2,
        'record_id': observation.id,
        'kind': entry.$2,
        'local_path': entry.$1.path,
        'file_name': p.basename(entry.$1.path),
        'local_only': 1,
        'created_at': 1,
        'updated_at': 1
      });
    }
    await source.insert('expenses', {
      'id': 'expense',
      'pet_id': pet.id,
      'amount': 10,
      'currency': 'USD',
      'category': 'medical',
      'spent_at': 1,
      'record_id': visit.id,
      'created_by': 'source',
      'created_at': 1,
      'updated_at': 1
    });
    await ReminderRepository(source).completeOnce(course.id,
        at: DateTime(2026, 10, 7, 10, 3),
        createdBy: 'source',
        actorName: 'Original caregiver');
    await source.insert('walk_sessions', {
      'id': 'walk',
      'pet_id': pet.id,
      'started_at': 1,
      'ended_at': 2,
      'region': 'intl',
      'created_by': 'source',
      'created_at': 1,
      'updated_at': 1
    });
    await source.insert('walk_points', {
      'id': 'point',
      'session_id': 'walk',
      'lat': 1,
      'lng': 2,
      'recorded_at': 1
    });
    await source.insert('pet_tags',
        {'id': 'tag', 'pet_id': pet.id, 'tag_type': 'airtag', 'created_at': 1});
    await source.insert('members', {
      'id': 'foreign-permission',
      'pet_id': pet.id,
      'user_id': 'someone',
      'role': 'owner',
      'status': 'active',
      'joined_at': 1,
      'updated_at': 1
    });
    await source
        .insert('sync_meta', {'key': 'token', 'value': 'DO-NOT-EXPORT'});
    backup = await exporter.exportTo(p.join(temp.path, 'backup.zip'));
  });
  tearDown(() async {
    await source.close();
    await target.close();
    if (p.isWithin(
        p.absolute(Directory.systemTemp.path), p.absolute(temp.path))) {
      await temp.delete(recursive: true);
    }
  });

  test(
      'inventory tracks generated backups locally without exporting that status',
      () async {
    final initial = await exporter.inventory();
    expect(initial.pets, 1);
    expect(initial.records, 3);
    expect(initial.attachments, 2);
    expect(initial.lastGenerated, isNull);
    final before = await source.query('sync_outbox');
    final preview = await exporter.inspect(backup.path);
    await exporter.markGenerated(preview);
    expect((await exporter.inventory()).lastGenerated, preview.createdAt);
    expect(await source.query('sync_outbox'), before);
    final regenerated =
        await exporter.exportTo(p.join(temp.path, 'second.zip'));
    final archive = ZipDecoder().decodeBytes(await regenerated.readAsBytes());
    expect(utf8.decode(archive.find('manifest.json')!.content),
        isNot(contains('backup_last_generated')));
    await importer.restore(regenerated.path,
        expectedId: (await importer.inspect(regenerated.path)).id);
    expect((await importer.inventory()).lastGenerated, isNull);
    expect((await importer.inventory()).records, 3);
  });

  test(
      'portable backup contains media and data but no credentials or membership grants',
      () async {
    final preview = await exporter.inspect(backup.path);
    expect(preview.pets, 1);
    expect(preview.records, 3);
    expect(preview.files, 2);
    final archive = ZipDecoder().decodeBytes(await backup.readAsBytes());
    final json = utf8.decode(archive.find('manifest.json')!.content);
    expect(json, isNot(contains('DO-NOT-EXPORT')));
    expect(json, isNot(contains('foreign-permission')));
    expect(json, isNot(contains(temp.path)));
  });

  test(
      'cross-device restore preserves history, remaps links and files, pauses schedules and keeps existing data',
      () async {
    final existing = await PetRepository(target).createSimple(
        name: 'Existing', speciesWire: 'cat', createdBy: 'target');
    final preview = await importer.inspect(backup.path);
    final ids = await importer.restore(backup.path,
        expectedId: preview.id, restoreContact: true);
    expect(ids.single, isNot(pet.id));
    expect((await PetRepository(target).listAll()).length, 2);
    expect(
        (await PetRepository(target).findById(existing.id))!.name, 'Existing');
    final rows = await RecordRepository(target).listByPet(ids.single);
    final symptom = rows.firstWhere((r) => r.type == RecordType.symptom);
    expect(symptom.recordedAt, eventAt);
    expect(symptom.createdBy, 'target');
    expect(symptom.payload['medical_record_id'],
        rows.firstWhere((r) => r.type == RecordType.medical).id);
    expect(symptom.payload['medical_record_id'], isNot(medicalId));
    final reminders = await ReminderRepository(target).listForPet(ids.single);
    expect(reminders.single.enabled, isFalse);
    expect(reminders.single.id, isNot(courseId));
    expect(symptom.payload['course_reminder_id'], reminders.single.id);
    final dose = rows.firstWhere((r) => r.type == RecordType.medication);
    expect(dose.payload['course_id'], reminders.single.id);
    expect(dose.id, 'dose_${reminders.single.id}_${dose.payload['due_at']}');
    expect(dose.payload['backup_actor_name'], 'Original caregiver');
    final files = await target.query('attachments');
    for (final file in files) {
      final path = file['local_path'] as String;
      expect(p.isWithin(p.join(temp.path, 'new-device'), path), isTrue);
      expect(await File(path).exists(), isTrue);
    }
    expect(await File(files.first['local_path'] as String).readAsBytes(),
        [1, 2, 3, 4]);
    final restoredPet = (await PetRepository(target).findById(ids.single))!;
    expect(restoredPet.avatarUrl, files.first['local_path']);
    final logs = await target.query('reminder_logs');
    expect(logs.single['reminder_id'], reminders.single.id);
    expect(logs.single['actor_name'], 'Original caregiver');
    expect(logs.single['created_by'], isNull);
    expect(logs.single['stock_used'], 1);
    expect(logs.single['id'],
        'log_${reminders.single.id}_${logs.single['due_at']}');
    expect(logs.single['record_id'], dose.id);
    expect((await target.query('expenses')).single['record_id'],
        symptom.payload['medical_record_id']);
    expect((await target.query('walk_points')).single['session_id'],
        (await target.query('walk_sessions')).single['id']);
    expect((await target.query('pet_tags')).single['pet_id'], ids.single);
    expect(await target.query('members'), isEmpty);
    expect((await target.query('users')).single['id'], 'target');
    expect((await target.query('users')).single['email'], 'target@example.com');
    expect((await target.query('users')).single['phone'], '12345');
    expect(
        await target.query('sync_meta', where: 'key = ?', whereArgs: ['token']),
        isEmpty);
    expect(
        await target
            .query('sync_outbox', where: 'table_name = ?', whereArgs: ['pets']),
        isNotEmpty);
  });

  test('restoring the same snapshot twice does not duplicate pets', () async {
    final preview = await importer.inspect(backup.path);
    await importer.restore(backup.path, expectedId: preview.id);
    await expectLater(importer.restore(backup.path, expectedId: preview.id),
        throwsStateError);
    expect((await target.query('pets')).length, 1);
  });

  test(
      'archived and deleted data stay archived and deleted without blocked tombstone uploads',
      () async {
    await source.update('pets', {'archived_at': 10, 'updated_at': 10},
        where: 'id = ?', whereArgs: [pet.id]);
    final deleted = await PetRepository(source)
        .createSimple(name: 'Deleted', speciesWire: 'cat', createdBy: 'source');
    await source.update('pets', {'deleted_at': 20, 'updated_at': 20},
        where: 'id = ?', whereArgs: [deleted.id]);
    final file = await exporter.exportTo(p.join(temp.path, 'archived.zip'));
    final preview = await importer.inspect(file.path);
    expect(preview.pets, 2);
    expect(await importer.restore(file.path, expectedId: preview.id), isEmpty);
    final pets = await target.query('pets');
    expect(pets.firstWhere((row) => row['name'] == 'Buddy')['archived_at'], 10);
    final tombstone = pets.firstWhere((row) => row['name'] == 'Deleted');
    expect(tombstone['deleted_at'], 20);
    expect(
        await target.query('sync_outbox',
            where: 'pet_id = ?', whereArgs: [tombstone['id']]),
        isEmpty);
  });

  test(
      'hash corruption, traversal paths, unsupported versions and mismatched regions fail before changing data',
      () async {
    final broken = await rewrite(backup, File(p.join(temp.path, 'broken.zip')),
        damageFile: true);
    await expectLater(importer.inspect(broken.path), throwsStateError);
    final traversal = await rewrite(
        backup, File(p.join(temp.path, 'traversal.zip')),
        extraName: '../escape.txt');
    await expectLater(importer.inspect(traversal.path), throwsStateError);
    final version = await rewrite(
        backup, File(p.join(temp.path, 'version.zip')),
        manifestChange: (m) => m['version'] = 99);
    await expectLater(importer.inspect(version.path), throwsStateError);
    await expectLater(
        BackupService(db: target, documentsPath: temp.path, region: Region.cn)
            .inspect(backup.path),
        throwsStateError);
    expect(await target.query('pets'), isEmpty);
    expect(await File(p.join(temp.path, 'escape.txt')).exists(), isFalse);
  });

  test(
      'decompression rejects a forged ZIP header that understates the real output size',
      () async {
    final bytes = await backup.readAsBytes();
    for (var i = 0; i < bytes.length - 46; i++) {
      if (bytes[i] == 0x50 &&
          bytes[i + 1] == 0x4b &&
          bytes[i + 2] == 1 &&
          bytes[i + 3] == 2) {
        ByteData.sublistView(bytes).setUint32(i + 24, 1, Endian.little);
        break;
      }
    }
    final file = File(p.join(temp.path, 'forged-size.zip'));
    await file.writeAsBytes(bytes);
    await expectLater(importer.inspect(file.path), throwsStateError);
    expect(await target.query('pets'), isEmpty);
  });

  test('invalid references roll back rows, queue changes and staged files',
      () async {
    final invalid = await rewrite(
        backup, File(p.join(temp.path, 'invalid.zip')), manifestChange: (m) {
      (m['tables']['records'] as List).last['pet_id'] = 'missing-pet';
    });
    final preview = await importer.inspect(invalid.path);
    final queueBefore = await target.query('sync_outbox');
    await expectLater(importer.restore(invalid.path, expectedId: preview.id),
        throwsStateError);
    expect(await target.query('pets'), isEmpty);
    expect(await target.query('records'), isEmpty);
    expect(await target.query('sync_outbox'), queueBefore);
    final restored = Directory(p.join(temp.path, 'new-device', 'restored'));
    expect(await restored.list().toList(), isEmpty);
  });

  test(
      'preview identity is rechecked and missing local media prevents an incomplete export',
      () async {
    await expectLater(
        importer.restore(backup.path, expectedId: 'wrong-preview'),
        throwsStateError);
    await File(p.join(temp.path, 'photo.jpg')).delete();
    final destination = p.join(temp.path, 'incomplete.zip');
    await expectLater(exporter.exportTo(destination), throwsStateError);
    expect(await File(destination).exists(), isFalse);
    expect(await target.query('pets'), isEmpty);
  });
}
