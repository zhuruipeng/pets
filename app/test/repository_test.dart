/// 仓储层测试 —— 跑在内存 SQLite 上，不需要平台通道。
///
/// 三条铁律各有一个测试兜着：
/// 1. 软删除语义（listAll 不返回，findById 能查到）
/// 2. recordedAt 与 createdAt 分离
/// 3. 轨迹点批量写入
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/core/species.dart';
import 'package:pet_app/data/db/schema.dart';
import 'package:pet_app/data/models.dart';
import 'package:pet_app/data/repositories/attachment_repository.dart';
import 'package:pet_app/data/repositories/pet_repository.dart';
import 'package:pet_app/data/repositories/record_repository.dart';
import 'package:pet_app/data/repositories/reminder_repository.dart';
import 'package:pet_app/data/repositories/walk_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 建一个内存库，用生产 DDL。
Future<Database> _memDb() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      // 版本号和语句都取自生产 schema —— 测试再抄一份 DDL 迟早会漏掉新列。
      version: kSchemaVersion,
      onCreate: (db, _) async {
        final batch = db.batch();
        for (final stmt in onCreate) {
          batch.execute(stmt);
        }
        await batch.commit(noResult: true);
      },
    ),
  );
  return db;
}


Pet _pet(String id, String name, {DateTime? birthday}) => Pet(
      id: id,
      name: name,
      species: Species.dog,
      birthday: birthday,
      createdBy: 'u1',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

void main() {
  late Database db;
  late PetRepository pets;
  late RecordRepository records;
  late ReminderRepository reminders;
  late WalkRepository walks;

  setUp(() async {
    db = await _memDb();
    pets = PetRepository(db);
    records = RecordRepository(db);
    reminders = ReminderRepository(db);
    walks = WalkRepository(db);
  });

  tearDown(() async => db.close());

  group('宠物仓储 · 软删除语义', () {
    test('软删除后 listAll 不返回，findById 仍能查到', () async {
      await pets.create(_pet('p1', '豆豆'));
      await pets.create(_pet('p2', '毛毛'));

      expect((await pets.listAll()).length, 2);

      await pets.softDelete('p1');

      final list = await pets.listAll();
      expect(list.length, 1);
      expect(list.first.id, 'p2');

      // 关键：findById 必须还能查到，用于同步与恢复
      final found = await pets.findById('p1');
      expect(found, isNotNull);
      expect(found!.deletedAt, isNotNull);
    });

    test('restore 后重新出现在列表里', () async {
      await pets.create(_pet('p1', '豆豆'));
      await pets.softDelete('p1');
      expect((await pets.listAll()).isEmpty, isTrue);

      await pets.restore('p1');
      expect((await pets.listAll()).length, 1);
    });

    test('归档不出现在列表，但找回仍在', () async {
      await pets.create(_pet('p1', '豆豆'));
      await pets.archive('p1');

      expect((await pets.listAll()).isEmpty, isTrue);
      expect((await pets.listAll(includeArchived: true)).length, 1);

      final found = await pets.findById('p1');
      expect(found!.archivedAt, isNotNull);
      // 归档 ≠ 删除
      expect(found.deletedAt, isNull);
    });

    test('重复软删除只影响第一行', () async {
      await pets.create(_pet('p1', '豆豆'));
      expect(await pets.softDelete('p1'), 1);
      expect(await pets.softDelete('p1'), 0);
    });

    test('count 默认排除软删除', () async {
      await pets.create(_pet('p1', 'a'));
      await pets.create(_pet('p2', 'b'));
      await pets.softDelete('p1');

      expect(await pets.count(), 1);
      expect(await pets.count(includeDeleted: true), 2);
    });
  });

  group('记录仓储 · 时间字段分离', () {
    test('补录的历史记录按 recordedAt 排在正确位置', () async {
      await pets.create(_pet('p1', '豆豆'));

      final now = DateTime.now();

      // 今天新增，记录的是今天的体重
      await records.createSimple(
        petId: 'p1',
        type: RecordType.weight,
        recordedAt: now,
        createdBy: 'u1',
        valueNum: 5.2,
      );

      // 今天入库，但事件发生在两个月前（补录）
      await records.createSimple(
        petId: 'p1',
        type: RecordType.vaccine,
        recordedAt: now.subtract(const Duration(days: 60)),
        createdBy: 'u1',
        valueText: '狂犬',
      );

      final list = await records.listByPet('p1');

      // 补录项必须排在后面，而不是因为它 created_at 是今天排在最前
      expect(list.first.type, RecordType.weight);
      expect(list.last.type, RecordType.vaccine);
      expect(list.last.recordedAt.isBefore(list.first.recordedAt), isTrue);
    });

    test('recordedAt 与 createdAt 确实是不同的值', () async {
      await pets.create(_pet('p1', '豆豆'));
      final backdated = DateTime(2026, 3, 15, 10, 30);

      final r = await records.createSimple(
        petId: 'p1',
        type: RecordType.vaccine,
        recordedAt: backdated,
        createdBy: 'u1',
      );

      final loaded = await records.findById(r.id);
      expect(loaded!.recordedAt, backdated);
      expect(
        loaded.createdAt.isAfter(backdated),
        isTrue,
        reason: 'createdAt 应该是入库的当下，不是事件时间',
      );
      // 两者相差应该很大（几个月），不能是同一个值
      expect(
        loaded.createdAt.difference(loaded.recordedAt).inDays,
        greaterThan(30),
      );
    });

    test('时间区间查询按 recordedAt 过滤，不是 createdAt', () async {
      await pets.create(_pet('p1', '豆豆'));
      final now = DateTime.now();

      await records.createSimple(
        petId: 'p1',
        type: RecordType.weight,
        recordedAt: now.subtract(const Duration(days: 100)),
        createdBy: 'u1',
        valueNum: 4.0,
      );
      await records.createSimple(
        petId: 'p1',
        type: RecordType.weight,
        recordedAt: now.subtract(const Duration(days: 5)),
        createdBy: 'u1',
        valueNum: 5.0,
      );

      final recent = await records.listByPet(
        'p1',
        from: now.subtract(const Duration(days: 10)),
      );
      expect(recent.length, 1);
      expect(recent.first.valueNum, 5.0);
    });

    test('软删除后不再出现在时间线', () async {
      await pets.create(_pet('p1', '豆豆'));
      final r = await records.createSimple(
        petId: 'p1',
        type: RecordType.weight,
        recordedAt: DateTime.now(),
        createdBy: 'u1',
        valueNum: 5,
      );

      expect((await records.listByPet('p1')).length, 1);
      await records.softDelete(r.id);
      expect((await records.listByPet('p1')).isEmpty, isTrue);
      // 但直接查还在
      expect(await records.findById(r.id), isNotNull);
    });

    test('体重序列只取有数值的项，且升序', () async {
      await pets.create(_pet('p1', '豆豆'));
      final now = DateTime.now();

      await records.createSimple(
        petId: 'p1',
        type: RecordType.weight,
        recordedAt: now.subtract(const Duration(days: 10)),
        createdBy: 'u1',
        valueNum: 4.5,
      );
      await records.createSimple(
        petId: 'p1',
        type: RecordType.weight,
        recordedAt: now,
        createdBy: 'u1',
        valueNum: 5.5,
      );
      // 没有数值的记录不该进序列
      await records.createSimple(
        petId: 'p1',
        type: RecordType.weight,
        recordedAt: now,
        createdBy: 'u1',
        valueText: '没称',
      );

      final series = await records.weightSeries('p1');
      expect(series.length, 2);
      expect(series.first.kg, 4.5);
      expect(series.last.kg, 5.5);
      expect(series.first.at.isBefore(series.last.at), isTrue);
    });

    test('payload 往返一致', () async {
      await pets.create(_pet('p1', '豆豆'));
      final r = await records.createSimple(
        petId: 'p1',
        type: RecordType.medication,
        recordedAt: DateTime.now(),
        createdBy: 'u1',
        payload: {'drug': '阿莫西林', 'dose': 0.5, 'days': 7},
      );

      final loaded = await records.findById(r.id);
      expect(loaded!.payload['drug'], '阿莫西林');
      expect(loaded.payload['days'], 7);
    });
  });

  group('记录仓储 · 改事件时间', () {
    test('updateRecordedAt 只动 recordedAt，createdAt 保持不动', () async {
      await pets.create(_pet('p1', '豆豆'));
      final r = await records.createSimple(
        petId: 'p1',
        type: RecordType.vaccine,
        recordedAt: DateTime(2026, 9, 1, 9),
        createdBy: 'u1',
        valueText: '狂犬',
      );
      final createdBefore = (await records.findById(r.id))!.createdAt;

      final fixed = DateTime(2026, 8, 20, 14, 30);
      final updated = await records.updateRecordedAt(r.id, fixed);

      expect(updated, isNotNull);
      expect(updated!.recordedAt, fixed);
      // createdAt 是「什么时候录进来的」的事实，改时间不该抹掉它。
      expect(updated.createdAt, createdBefore);
      expect(updated.valueText, '狂犬', reason: '其他字段不能被顺手清掉');
    });

    test('改完时间后列表顺序跟着变', () async {
      await pets.create(_pet('p1', '豆豆'));
      final a = await records.createSimple(
        petId: 'p1',
        type: RecordType.weight,
        recordedAt: DateTime(2026, 9, 10),
        createdBy: 'u1',
        valueNum: 5.0,
      );
      await records.createSimple(
        petId: 'p1',
        type: RecordType.weight,
        recordedAt: DateTime(2026, 9, 20),
        createdBy: 'u1',
        valueNum: 5.4,
      );

      // 把早的那条改到更晚，它应该排到最前
      await records.updateRecordedAt(a.id, DateTime(2026, 9, 25));

      final list = await records.listByPet('p1');
      expect(list.first.id, a.id);
    });

    test('改已软删除的记录返回 null，不复活它', () async {
      await pets.create(_pet('p1', '豆豆'));
      final r = await records.createSimple(
        petId: 'p1',
        type: RecordType.weight,
        recordedAt: DateTime(2026, 9, 10),
        createdBy: 'u1',
        valueNum: 5.0,
      );
      await records.softDelete(r.id);

      expect(await records.updateRecordedAt(r.id, DateTime(2026, 9, 11)),
          isNull);
    });
  });

  group('提醒仓储 · 完成即排下次', () {
    test('周期提醒完成后 next_at 按间隔推进，并写日志', () async {
      await pets.create(_pet('p1', '豆豆'));
      final first = DateTime(2026, 9, 28, 9);

      final r = await reminders.createInterval(
        petId: 'p1',
        type: 'deworm_internal',
        title: 'plan.deworm.internal',
        everyDays: 90,
        firstAt: first,
      );

      final result = await reminders.completeOnce(r.id, at: first);

      expect(result.nextAt, isNotNull);
      expect(result.nextAt!.difference(first).inDays, 90);

      final reloaded = await reminders.findById(r.id);
      expect(reloaded!.nextAt, result.nextAt);

      // 完成率：1 完成 / 1 总数
      expect(await reminders.completionRate(), 1.0);
    });

    test('一次性提醒完成后停用而非删除', () async {
      await pets.create(_pet('p1', '豆豆'));
      final now = DateTime.now();
      await reminders.create(Reminder(
        id: 'r1',
        petId: 'p1',
        type: 'vaccine',
        title: 'plan.vaccine.rabies',
        rule: const {'mode': 'once', 'at': 0},
        nextAt: now,
        createdAt: now,
        updatedAt: now,
      ));

      final result = await reminders.completeOnce('r1', at: now);
      expect(result.nextAt, isNull);

      final reloaded = await reminders.findById('r1');
      expect(reloaded!.enabled, isFalse);
      // 还在库里，不是删了
      expect(reloaded.deletedAt, isNull);
    });

    test('延后只改 next_at，不写完成日志', () async {
      await pets.create(_pet('p1', '豆豆'));
      final first = DateTime(2026, 9, 28, 9);
      final r = await reminders.createInterval(
        petId: 'p1',
        type: 'deworm_internal',
        title: 'x',
        everyDays: 30,
        firstAt: first,
      );

      final next = await reminders.snooze(r.id, const Duration(days: 1), at: first);
      expect(next!.difference(first).inDays, 1);

      // 没有完成记录，完成率仍是 0
      expect(await reminders.completionRate(), 0.0);
    });

    test('upcoming 按时间窗口筛选且排除已停用', () async {
      await pets.create(_pet('p1', '豆豆'));
      final base = DateTime(2026, 9, 28, 9);

      await reminders.createInterval(
        petId: 'p1', type: 'a', title: 'a',
        everyDays: 30, firstAt: base.add(const Duration(days: 3)),
      );
      await reminders.createInterval(
        petId: 'p1', type: 'b', title: 'b',
        everyDays: 30, firstAt: base.add(const Duration(days: 60)),
      );

      final soon = await reminders.upcoming(
        from: base,
        to: base.add(const Duration(days: 7)),
      );
      expect(soon.length, 1);
      expect(soon.first.type, 'a');
    });
  });

  group('遛狗仓储 · 批量写入', () {
    test('批量写入 600 个点', () async {
      await pets.create(_pet('p1', '豆豆'));
      final s = await walks.startSession(petId: 'p1', createdBy: 'u1');

      final points = [
        for (var i = 0; i < 600; i++)
          WalkPoint(
            id: 'pt$i',
            sessionId: s.id,
            lat: 35.05 + i * 0.0001,
            lng: 118.35 + i * 0.0001,
            accuracy: 8,
            recordedAt: s.startedAt.add(Duration(seconds: i)),
          ),
      ];

      final written = await walks.appendPoints(s.id, points);
      expect(written, 600);

      final stored = await walks.pointsOf(s.id);
      expect(stored.length, 600);
    });

    test('漂移点被过滤掉', () async {
      await pets.create(_pet('p1', '豆豆'));
      final s = await walks.startSession(petId: 'p1', createdBy: 'u1');

      final written = await walks.appendPoints(s.id, [
        WalkPoint(id: 'a', sessionId: s.id, lat: 35.0, lng: 118.0,
            accuracy: 10, recordedAt: s.startedAt),
        WalkPoint(id: 'b', sessionId: s.id, lat: 35.01, lng: 118.01,
            accuracy: 200, recordedAt: s.startedAt), // 漂移
        WalkPoint(id: 'c', sessionId: s.id, lat: 35.02, lng: 118.02,
            accuracy: null, recordedAt: s.startedAt), // 无精度信息，保留
      ]);

      expect(written, 2);
      final stored = await walks.pointsOf(s.id);
      expect(stored.map((p) => p.id).toSet(), {'a', 'c'});
    });

    test('结束 session 回算距离与时长', () async {
      await pets.create(_pet('p1', '豆豆'));
      final start = DateTime(2026, 9, 28, 8);
      final s = await walks.startSession(
        petId: 'p1', createdBy: 'u1', startedAt: start,
      );

      // 两个点，相距约 111 米（0.001 度纬度）
      await walks.appendPoints(s.id, [
        WalkPoint(id: 'a', sessionId: s.id, lat: 35.000, lng: 118.000,
            accuracy: 5, recordedAt: start),
        WalkPoint(id: 'b', sessionId: s.id, lat: 35.001, lng: 118.000,
            accuracy: 5, recordedAt: start.add(const Duration(minutes: 1))),
      ]);

      final ended = await walks.endSession(
        s.id, endedAt: start.add(const Duration(minutes: 30)),
      );

      expect(ended.endedAt, isNotNull);
      expect(ended.durationS, 1800);
      // 0.001 度纬度 ≈ 111 米
      expect(ended.distanceM, closeTo(111, 5));
      expect(ended.isActive, isFalse);
    });

    test('同一宠物不会同时有两个进行中的 session', () async {
      await pets.create(_pet('p1', '豆豆'));
      final a = await walks.startSession(petId: 'p1', createdBy: 'u1');
      final b = await walks.startSession(petId: 'p1', createdBy: 'u1');

      expect(b.id, a.id);
      expect((await walks.listSessions('p1')).isEmpty, isTrue); // 未结束不计入
    });

    test('哈弗辛距离：0 个点或 1 个点返回 0', () {
      expect(WalkRepository.totalDistanceM([]), 0);
      expect(
        WalkRepository.totalDistanceM([
          WalkPoint(id: 'a', sessionId: 's', lat: 35, lng: 118,
              recordedAt: DateTime(2026)),
        ]),
        0,
      );
    });

    test('批量写入确实快于逐条写入', () async {
      await pets.create(_pet('p1', '豆豆'));

      // 两个来源的 id 必须不同，否则会撞主键。
      List<WalkPoint> gen(String sid, String prefix) => [
            for (var i = 0; i < 400; i++)
              WalkPoint(
                id: '$prefix$i',
                sessionId: sid,
                lat: 35 + i * 0.0001,
                lng: 118 + i * 0.0001,
                accuracy: 5,
                recordedAt: DateTime(2026, 9, 28).add(Duration(seconds: i)),
              ),
          ];

      // 批量路径
      final s1 = await walks.startSession(petId: 'p1', createdBy: 'u1');
      final sw1 = Stopwatch()..start();
      await walks.appendPoints(s1.id, gen(s1.id, 'batch'));
      sw1.stop();

      // 逐条路径：不用 batch，一条条 await
      final sw2 = Stopwatch()..start();
      for (final pt in gen('single', 'one')) {
        await db.insert('walk_points', pt.toMap());
      }
      sw2.stop();

      expect(await walks.pointsOf(s1.id), hasLength(400));

      // 批量不应慢于逐条；这里给一点余量避免机器抖动
      expect(sw1.elapsedMilliseconds <= sw2.elapsedMilliseconds + 50, isTrue,
          reason: '批量 ${sw1.elapsedMilliseconds}ms vs 逐条 ${sw2.elapsedMilliseconds}ms');
    });
  });

  group('遛狗仓储 · 结束后补录心情', () {
    test('setFeedback 写入 mood/note，回读能拿到', () async {
      await pets.create(_pet('p1', '豆豆'));
      final s = await walks.startSession(petId: 'p1', createdBy: 'u1');
      final done = await walks.endSession(s.id);

      // 结束时只算距离和时长，心情还没填
      expect(done.mood, isNull);
      expect(done.note, isNull);

      final updated =
          await walks.setFeedback(s.id, mood: 'great', note: '遇到了邻居家的金毛');
      expect(updated!.mood, 'great');
      expect(updated.note, '遇到了邻居家的金毛');

      // 关键：必须真的落到库里，而不是只在内存对象上改了
      final back = await walks.findSession(s.id);
      expect(back!.mood, 'great');
      expect(back.note, '遇到了邻居家的金毛');
    });

    test('只填心情不填备注时，备注保持 null', () async {
      await pets.create(_pet('p1', '豆豆'));
      final s = await walks.startSession(petId: 'p1', createdBy: 'u1');
      await walks.endSession(s.id);

      final updated = await walks.setFeedback(s.id, mood: 'tired');
      expect(updated!.mood, 'tired');
      expect(updated.note, isNull);
    });
  });

  group('schema 迁移', () {
    test('新建的库已经带 mood / note 两列', () async {
      final cols = await db.rawQuery('PRAGMA table_info(walk_sessions)');
      final names = cols.map((r) => r['name'] as String).toSet();
      expect(names, contains('mood'));
      expect(names, contains('note'));
    });

    test('v2 迁移语句作用在 v1 的老表上能成功', () async {
      // v1 的快照固化在这里：walk_sessions 还没有 mood / note。
      // 迁移一旦发出去就不能再改，所以需要有一条「对历史版本回放」的测试兜着。
      final old = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          // ⚠️ 必须关掉单例缓存，否则这个「老库」是假的。
          // sqflite 按**数据库路径**缓存已打开的连接，而 inMemoryDatabasePath
          // 永远是固定的 ':memory:' —— 不关的话这里拿到的就是 setUp 里那个
          // 已经按生产 DDL 建好的 v2 库，`old` 名不副实，
          // 迁移语句会撞上已存在的 mood 列报 duplicate column name。
          singleInstance: false,
          version: 1,
          onCreate: (d, _) => d.execute('CREATE TABLE walk_sessions ('
              ' id TEXT PRIMARY KEY, pet_id TEXT NOT NULL,'
              ' started_at INTEGER NOT NULL, ended_at INTEGER,'
              ' distance_m REAL NOT NULL DEFAULT 0,'
              ' duration_s INTEGER NOT NULL DEFAULT 0, region TEXT NOT NULL,'
              ' created_by TEXT NOT NULL, created_at INTEGER NOT NULL,'
              ' updated_at INTEGER NOT NULL, deleted_at INTEGER)'),
        ),
      );

      for (final stmt in migrations[2]!) {
        await old.execute(stmt);
      }

      final cols = await old.rawQuery('PRAGMA table_info(walk_sessions)');
      final names = cols.map((r) => r['name'] as String).toSet();
      expect(names, contains('mood'));
      expect(names, contains('note'));
      await old.close();
    });

    test('每个中间版本都有对应的迁移语句', () {
      for (var v = 2; v <= kSchemaVersion; v++) {
        expect(migrations[v], isNotNull, reason: '缺少 v$v 的迁移');
        expect(migrations[v], isNotEmpty);
      }
    });
  });

  group('附件仓储', () {
    test('软删除后 listByRecord 不返回，物理路径不受影响', () async {
      final db = await _memDb();
      final repo = AttachmentRepository(db);

      const recordId = 'rec-1';
      final att = RecordAttachment(
        id: 'att-1',
        recordId: recordId,
        kind: 'photo',
        localPath: '/tmp/fake/photo.jpg',
        createdAt: DateTime(2026, 9, 29, 10),
      );
      await db.insert('attachments', att.toMap());

      expect((await repo.listByRecord(recordId)).length, 1);
      expect(await repo.countForRecord(recordId), 1);

      await repo.softDelete('att-1');
      expect(await repo.listByRecord(recordId), isEmpty);
      expect(await repo.countForRecord(recordId), 0);

      // 软删不等于销毁：恢复后必须原样回来。
      expect((await repo.listByRecord(recordId, includeDeleted: true)).length, 1);
      await repo.restore('att-1');
      final restored = await repo.listByRecord(recordId);
      expect(restored.single.id, 'att-1');
      expect(restored.single.localPath, '/tmp/fake/photo.jpg');
      await db.close();
    });

    test('附件按 record 隔离，不串到别的记录', () async {
      final db = await _memDb();
      final repo = AttachmentRepository(db);

      for (var i = 0; i < 3; i++) {
        await db.insert(
          'attachments',
          RecordAttachment(
            id: 'att-$i',
            recordId: i < 2 ? 'rec-a' : 'rec-b',
            kind: 'photo',
            localPath: '/x/$i.jpg',
            createdAt: DateTime(2026, 9, 29, 10 + i),
          ).toMap(),
        );
      }

      expect((await repo.listByRecord('rec-a')).length, 2);
      expect((await repo.listByRecord('rec-b')).length, 1);

      // 按 created_at 升序，缩略图按添加顺序展示。
      final a = await repo.listByRecord('rec-a');
      expect(a.first.id, 'att-0');
      expect(a.last.id, 'att-1');
      await db.close();
    });
  });
}
