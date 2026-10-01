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
import 'package:pet_app/data/repositories/expense_repository.dart';
import 'package:pet_app/data/repositories/member_repository.dart';
import 'package:pet_app/data/repositories/pet_repository.dart';
import 'package:pet_app/data/repositories/record_repository.dart';
import 'package:pet_app/data/repositories/reminder_repository.dart';
import 'package:pet_app/data/repositories/user_repository.dart';
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

    test('v5 迁移能在老库上跑通，且 expenses 的变更进得了 outbox', () async {
      // 单开一个库 —— 不能用 _memDb()，那个是按最新 DDL 建好的，
      // 「升级」路径就测不到了。而升级恰恰是最容易出事的一条：
      // 语句写错只会在用户手机上炸，我们的开发机永远是全新安装。
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          singleInstance: false,
          version: 1,
        ),
      );

      // v5 建的是新表，但它的同步触发器引用了 sync_meta / sync_outbox，
      // 老库里本来就有 —— 这里补上再跑迁移。
      await db.execute(createSyncMeta);
      await db.execute(createSyncOutbox);

      for (final stmt in migrations[5]!) {
        await db.execute(stmt);
      }

      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='expenses'",
      );
      expect(tables, isNotEmpty, reason: 'v5 迁移应建出 expenses 表');

      // 触发器必须真的把变更记进 outbox —— 漏了的话这笔支出
      // 在本地看得见、却永远同步不出去，而且悄无声息。
      await db.insert('expenses', {
        'id': 'e1',
        'pet_id': 'p1',
        'amount': 120.0,
        'currency': 'CNY',
        'category': 'medical',
        'spent_at': 1000,
        'created_by': 'u1',
        'created_at': 1000,
        'updated_at': 1000,
      });
      final outbox = await db.query('sync_outbox');
      expect(outbox, hasLength(1), reason: 'expenses 的 INSERT 应产生一条 outbox');
      expect(outbox.first['table_name'], 'expenses');
      expect(outbox.first['pet_id'], 'p1', reason: 'pet_id 是同步的分发键');

      await db.close();
    });

    test('v6 迁移后文档原件不进 outbox，照片照常进', () async {
      // 单开一个库，并**手工建一个 v4 时代的老触发器**：v6 要改的正是
      // 已经存在的那个触发器，用 onCreate 建的全新库走不到 DROP/CREATE
      // 这条路径，而这条路径只会在老用户升级时跑一次 —— 出错就是线上事故。
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false, version: 1),
      );
      await db.execute(createSyncMeta);
      await db.execute(createSyncOutbox);
      await db.execute(createRecords);
      await db.execute(createAttachments);
      await db.execute('''
CREATE TRIGGER trg_attachments_outbox_ins AFTER INSERT ON attachments
WHEN (SELECT value FROM sync_meta WHERE key = 'applying') IS NOT '1'
BEGIN
  INSERT OR REPLACE INTO sync_outbox(table_name, row_id, pet_id, op, updated_at)
  VALUES ('attachments', NEW.id,
    (SELECT pet_id FROM records WHERE id = NEW.record_id),
    CASE WHEN NEW.deleted_at IS NULL THEN 'upsert' ELSE 'delete' END,
    NEW.updated_at);
END;
''');

      for (final stmt in migrations[6]!) {
        await db.execute(stmt);
      }

      // 老触发器被换掉了（名字还在，但 WHEN 里多了 local_only 这一条）。
      final triggers = await db.rawQuery(
        "SELECT sql FROM sqlite_master WHERE type='trigger' "
        "AND name='trg_attachments_outbox_ins'",
      );
      expect(triggers, hasLength(1));
      expect(triggers.first['sql'] as String, contains('local_only'),
          reason: '迁移必须把触发器换成带 local_only 条件的那版');

      await db.insert('records', {
        'id': 'rec-1',
        'pet_id': 'p1',
        'type': 'medical',
        'recorded_at': 1000,
        'created_by': 'u1',
        'created_at': 1000,
        'updated_at': 1000,
      });

      await db.insert('attachments', {
        'id': 'doc-1',
        'record_id': 'rec-1',
        'kind': 'document',
        'local_path': '/tmp/fake/vaccine.pdf',
        'file_name': '疫苗本.pdf',
        'local_only': 1,
        'created_at': 1000,
        'updated_at': 1000,
      });
      expect(await db.query('sync_outbox'), isEmpty,
          reason: '文档原件只存本机，不该进同步队列');

      // 照片照常同步 —— 顺带验证 COALESCE 那一层：老行没写过 local_only，
      // 列上是 NULL，`NULL = 0` 在 SQLite 里是 NULL 不是真，漏了 COALESCE
      // 会让所有老照片从此不同步，而全新装的库一列都不缺、测不出来。
      await db.insert('attachments', {
        'id': 'photo-1',
        'record_id': 'rec-1',
        'kind': 'photo',
        'local_path': '/tmp/fake/photo.jpg',
        'created_at': 1000,
        'updated_at': 1000,
      });
      final outbox = await db.query('sync_outbox');
      expect(outbox, hasLength(1));
      expect(outbox.first['table_name'], 'attachments');
      expect(outbox.first['row_id'], 'photo-1');

      await db.close();
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

    test('照片与文档按 kind 分开取，相册里不会混进 PDF', () async {
      final db = await _memDb();
      final repo = AttachmentRepository(db);

      await db.insert('records', {
        'id': 'rec-a',
        'pet_id': 'p1',
        'type': 'medical',
        'recorded_at': 1000,
        'created_by': 'u1',
        'created_at': 1000,
        'updated_at': 1000,
      });

      Future<void> put(String id, String kind, {bool localOnly = false}) =>
          db.insert(
            'attachments',
            RecordAttachment(
              id: id,
              recordId: 'rec-a',
              kind: kind,
              localPath: '/x/$id',
              fileName: '$id.${kind == 'document' ? 'pdf' : 'jpg'}',
              sizeBytes: 2048,
              localOnly: localOnly,
              createdAt: DateTime(2026, 9, 29, 10),
            ).toMap(),
          );

      await put('att-photo', 'photo');
      await put('att-doc', 'document', localOnly: true);

      expect((await repo.listByRecord('rec-a', kind: 'photo')).length, 1);
      expect((await repo.listByRecord('rec-a', kind: 'document')).length, 1);
      expect((await repo.listByRecord('rec-a')).length, 2, reason: '不传 kind 取全部');

      // 跨记录的相册/文档夹同样要分开。
      expect((await repo.listPhotosByPet('p1')).length, 1);
      expect((await repo.listDocumentsByPet('p1')).length, 1);

      // 元数据往返：只存本机这个标记不能丢了 —— 丢了的后果是
      // 文档元数据被推上去，别人那边看到一个点不开的条目。
      final docs = await repo.listDocumentsByPet('p1');
      expect(docs.single.localOnly, isTrue);
      expect(docs.single.isDocument, isTrue);
      expect(docs.single.fileName, 'att-doc.pdf');
      expect(docs.single.sizeBytes, 2048);

      await db.close();
    });

    test('老行没有 local_only 列时读作 false，不能抛', () async {
      // 模型层直接读一行**只有老列**的 map：升级路径上真实存在这种情况，
      // 写成 `(m['local_only'] as int) == 1` 会在这儿直接抛。
      final att = RecordAttachment.fromMap({
        'id': 'att-1',
        'record_id': 'rec-a',
        'kind': 'photo',
        'local_path': '/x/1.jpg',
        'created_at': 1000,
      });
      expect(att.localOnly, isFalse);
      expect(att.isPhoto, isTrue);
      expect(att.fileName, isNull);
    });
  });

  // M2.2 / M2.3 -----------------------------------------------------------------

  group('宠物档案 · 个性特点', () {
    test('personality 以 JSON 数组落库，读回来是同一串 code', () async {
      await pets.create(
        _pet('p1', '豆豆').copyWith(personality: const ['playful', 'foodie']),
      );

      final loaded = await pets.findById('p1');
      expect(loaded!.personality, ['playful', 'foodie']);

      // 库里存的确实是 JSON 字符串，而不是「逗号拼接」之类的临时格式 ——
      // 服务端 M6 同步要按同一形态读写。
      final row = (await db.query('pets', where: 'id = ?', whereArgs: ['p1'])).first;
      expect(row['personality'], '["playful","foodie"]');
    });

    test('没勾任何标签时存 NULL，不是空串', () async {
      await pets.create(_pet('p1', '豆豆'));
      final row = (await db.query('pets', where: 'id = ?', whereArgs: ['p1'])).first;
      expect(row['personality'], isNull);
      expect((await pets.findById('p1'))!.personality, isEmpty);
    });

    test('脏数据（不是 JSON 数组）按空处理，不抛异常', () async {
      await db.insert('pets', _pet('p1', '豆豆').copyWith(personality: const ['a']).toMap());
      await db.update(
        'pets',
        {'personality': '{"not":"a list"}'},
        where: 'id = ?',
        whereArgs: ['p1'],
      );

      // 一条脏数据不该让档案页整页打不开。
      expect((await pets.findById('p1'))!.personality, isEmpty);
    });
  });

  group('宠物档案 · copyWith 语义', () {
    test('clearXxx 才能把可空字段置空，传 null 等于「不改」', () async {
      final base = _pet('p1', '豆豆').copyWith(breed: '金毛', chipNo: '123');

      // 传 null 但没给 clear 标记 → 保持原值。
      expect(base.copyWith(breed: null).breed, '金毛');
      // 显式 clear → 真的清空。
      expect(base.copyWith(clearBreed: true).breed, isNull);
      expect(base.copyWith(clearChipNo: true).chipNo, isNull);
      // 没碰的字段不受影响。
      expect(base.copyWith(clearBreed: true).chipNo, '123');
    });

    test('copyWith 不动身份字段，只更新 updatedAt', () async {
      final origin = _pet('p1', '豆豆');
      final edited = origin.copyWith(name: '豆豆子');

      expect(edited.id, origin.id);
      expect(edited.createdBy, origin.createdBy);
      expect(edited.createdAt, origin.createdAt);
      expect(edited.name, '豆豆子');
    });

    test('改完落库能被读回（编辑保存的核心路径）', () async {
      final origin = await pets.create(_pet('p1', '豆豆'));
      await pets.update(
        origin.copyWith(
          name: '豆豆子',
          breed: '金毛',
          gender: 'female',
          neutered: true,
          weightBaseline: 23.4,
          personality: const ['calm'],
        ),
      );

      final loaded = await pets.findById('p1');
      expect(loaded!.name, '豆豆子');
      expect(loaded.breed, '金毛');
      expect(loaded.gender, 'female');
      expect(loaded.neutered, isTrue);
      expect(loaded.weightBaseline, 23.4);
      expect(loaded.personality, ['calm']);
    });
  });

  group('附件 · 按宠物汇总照片', () {
    test('跨记录 JOIN，只取没被软删的', () async {
      final repo = AttachmentRepository(db);
      // 直接建带固定 id 的记录：这条测试要按 id 断言，不能让仓储随机生成。
      for (final spec in [
        ('rec-a', 'p1', RecordType.medication),
        ('rec-b', 'p2', RecordType.medical),
      ]) {
        await records.create(PetRecord(
          id: spec.$1,
          petId: spec.$2,
          type: spec.$3,
          recordedAt: DateTime(2026, 9, 29, 8),
          createdBy: 'u1',
          createdAt: DateTime(2026, 9, 29, 8),
          updatedAt: DateTime(2026, 9, 29, 8),
        ));
      }

      for (final spec in [('att-1', 'rec-a'), ('att-2', 'rec-a'), ('att-3', 'rec-b')]) {
        await db.insert(
          'attachments',
          RecordAttachment(
            id: spec.$1,
            recordId: spec.$2,
            kind: 'photo',
            localPath: '/x/${spec.$1}.jpg',
            createdAt: DateTime(2026, 9, 29, 10),
          ).toMap(),
        );
      }
      // 软删一张：相册里不该再出现。
      await repo.softDelete('att-2');

      final p1Photos = await repo.listPhotosByPet('p1');
      expect(p1Photos.map((a) => a.id), ['att-1']);
      expect((await repo.listPhotosByPet('p2')).length, 1);

      // 记录被软删时，它下面的照片也一起消失（否则相册会出现无主照片）。
      await records.softDelete('rec-b');
      expect(await repo.listPhotosByPet('p2'), isEmpty);
    });
  });

  // M4：手动提醒 ---------------------------------------------------------------

  group('提醒 · 手动新建与完成', () {
    test('新建周期提醒，rule 存成 interval 天数', () async {
      await pets.create(_pet('p1', '豆豆'));
      final r = await reminders.createInterval(
        petId: 'p1',
        type: 'deworm_internal',
        title: 'reminder.type.deworm_internal',
        everyDays: 90,
        firstAt: DateTime(2026, 10, 1, 9),
      );

      final loaded = await reminders.findById(r.id);
      expect(loaded!.everyDays, 90);
      expect(loaded.isRecurring, isTrue);
      expect(loaded.source, 'manual');
    });

    test('一次性提醒完成后停用，不再有下次', () async {
      await pets.create(_pet('p1', '豆豆'));
      final r = await reminders.createInterval(
        petId: 'p1',
        type: 'other',
        title: '剪指甲',
        everyDays: 0,
        firstAt: DateTime(2026, 9, 1, 9),
      );

      final result = await reminders.completeOnce(r.id, at: DateTime(2026, 9, 1, 10));
      expect(result.nextAt, isNull);

      final loaded = await reminders.findById(r.id);
      expect(loaded!.enabled, isFalse);
      // 是一次性提醒，「间隔天数」读出来是 0，界面据此显示「只提醒一次」。
      expect(loaded.isRecurring, isFalse);
    });

    test('周期提醒完成后 next_at 往后推一个周期', () async {
      await pets.create(_pet('p1', '豆豆'));
      final first = DateTime(2026, 9, 1, 9);
      final r = await reminders.createInterval(
        petId: 'p1',
        type: 'deworm_external',
        title: 'reminder.type.deworm_external',
        everyDays: 30,
        firstAt: first,
      );

      final result = await reminders.completeOnce(r.id);
      expect(result.nextAt, first.add(const Duration(days: 30)));

      final loaded = await reminders.findById(r.id);
      expect(loaded!.enabled, isTrue, reason: '周期提醒不该被停用');
      expect(loaded.nextAt, first.add(const Duration(days: 30)));
    });

    test('编辑会覆写类型/名称/规则/时间，但 id 与 pet_id 不动', () async {
      await pets.create(_pet('p1', '豆豆'));
      await pets.create(_pet('p2', '毛毛'));
      final r = await reminders.createInterval(
        petId: 'p1',
        type: 'other',
        title: '旧名字',
        everyDays: 0,
        firstAt: DateTime(2026, 9, 1, 9),
      );

      await reminders.update(r.copyWith(
        type: 'medication',
        title: '新名字',
        rule: {'mode': 'interval', 'days': 7},
        nextAt: DateTime(2026, 9, 20, 9),
      ));

      final loaded = await reminders.findById(r.id);
      expect(loaded!.id, r.id);
      expect(loaded.petId, 'p1');
      expect(loaded.type, 'medication');
      expect(loaded.title, '新名字');
      expect(loaded.everyDays, 7);
      expect(loaded.nextAt, DateTime(2026, 9, 20, 9));
    });

    test('延后只推 next_at，不写完成日志', () async {
      await pets.create(_pet('p1', '豆豆'));
      final r = await reminders.createInterval(
        petId: 'p1',
        type: 'checkup',
        title: 'reminder.type.checkup',
        everyDays: 365,
        firstAt: DateTime(2026, 9, 1, 9),
      );

      final next = await reminders.snooze(r.id, const Duration(days: 1));
      expect(next, DateTime(2026, 9, 2, 9));
      // 延后不算完成，完成率不能因此上升。
      expect(await reminders.completionRate(), 0);
    });

    test('删除后 listForPet 查不到，findById 仍能查到（软删除语义）', () async {
      await pets.create(_pet('p1', '豆豆'));
      final r = await reminders.createInterval(
        petId: 'p1',
        type: 'other',
        title: '洗澡',
        everyDays: 30,
        firstAt: DateTime(2026, 9, 1, 9),
      );

      await reminders.softDelete(r.id);
      expect(await reminders.listForPet('p1'), isEmpty);
      expect((await reminders.findById(r.id))!.deletedAt, isNotNull);
    });
  });

  // M5 / M6：联系方式、同步底座 -------------------------------------------------

  group('同步底座 · outbox 触发器', () {
    test('任何写入都会自动进 outbox，不需要仓储配合', () async {
      // 关键点：这条走的是 PetRepository.create，仓储里没有任何
      // 「记一笔待同步」的代码 —— 全靠触发器。
      await pets.create(_pet('p1', '豆豆'));

      final rows = await db.query('sync_outbox');
      expect(rows.length, 1);
      expect(rows.first['table_name'], 'pets');
      expect(rows.first['row_id'], 'p1');
      // pets 的分发键就是自己
      expect(rows.first['pet_id'], 'p1');
      expect(rows.first['op'], 'upsert');
    });

    test('软删除记为 delete（墓碑要同步，否则别的设备不知道删过）', () async {
      await pets.create(_pet('p1', '豆豆'));
      await pets.softDelete('p1');

      final rows = await db.query('sync_outbox', where: 'row_id = ?', whereArgs: ['p1']);
      expect(rows.length, 1, reason: '同一行只留最后一次，中间态没有推送价值');
      expect(rows.first['op'], 'delete');
    });

    test('同一行改多次只留一条 outbox', () async {
      final origin = await pets.create(_pet('p1', '豆豆'));
      await pets.update(origin.copyWith(name: '豆豆子'));
      await pets.update(origin.copyWith(name: '豆豆子2'));

      final rows = await db.query('sync_outbox');
      expect(rows.length, 1);
    });

    test('applying=1 期间触发器哑火（防止推拉无限循环）', () async {
      final batch = db.batch();
      batch.insert('sync_meta', {'key': 'applying', 'value': '1'});
      await batch.commit(noResult: true);

      await pets.create(_pet('p1', '豆豆'));
      expect(await db.query('sync_outbox'), isEmpty);

      await db.delete('sync_meta', where: 'key = ?', whereArgs: ['applying']);
      await pets.create(_pet('p2', '毛毛'));
      expect((await db.query('sync_outbox')).length, 1);
    });

    test('附件的 pet_id 经 record 反查', () async {
      await pets.create(_pet('p1', '豆豆'));
      await records.create(PetRecord(
        id: 'rec-a',
        petId: 'p1',
        type: RecordType.medication,
        recordedAt: DateTime(2026, 9, 29, 8),
        createdBy: 'u1',
        createdAt: DateTime(2026, 9, 29, 8),
        updatedAt: DateTime(2026, 9, 29, 8),
      ));
      await db.delete('sync_outbox'); // 清掉前面两条，只看附件这条

      await db.insert(
        'attachments',
        RecordAttachment(
          id: 'att-1',
          recordId: 'rec-a',
          kind: 'photo',
          localPath: '/x/1.jpg',
          createdAt: DateTime(2026, 9, 29, 9),
          updatedAt: DateTime(2026, 9, 29, 9),
        ).toMap(),
      );

      final rows = await db.query('sync_outbox',
          where: 'table_name = ?', whereArgs: ['attachments']);
      expect(rows.length, 1);
      expect(rows.first['pet_id'], 'p1', reason: '附件自己没有 pet_id 列');
    });

    test('不同步的表不产生 outbox', () async {
      await db.insert('walk_points', {
        'id': 'wp1',
        'session_id': 's1',
        'lat': 1.0,
        'lng': 2.0,
        'recorded_at': DateTime(2026, 9, 29).millisecondsSinceEpoch,
      });
      expect(
        await db.query('sync_outbox', where: 'table_name = ?', whereArgs: ['walk_points']),
        isEmpty,
        reason: '轨迹点随 session 一起传，逐点同步会把变更日志撑爆',
      );
    });
  });

  group('联系方式 · users 表', () {
    test('联系方式往返（清空要显式 clear，传 null 等于不改）', () async {
      final users = UserRepository(db);
      final now = DateTime(2026, 9, 30);
      await users.create(LocalUser(
        id: 'u1',
        nickname: '我',
        region: 'local',
        createdAt: now,
        updatedAt: now,
      ));

      final base = (await users.current())!;
      expect(base.hasContact, isFalse);

      await users.update(base.copyWith(
        phone: '13800138000',
        wechat: 'pet-dad',
        contactNote: '小区 3 栋王阿姨',
      ));
      final filled = (await users.current())!;
      expect(filled.phone, '13800138000');
      expect(filled.wechat, 'pet-dad');
      expect(filled.hasContact, isTrue);

      await users.update(filled.copyWith(clearPhone: true));
      final cleared = (await users.current())!;
      expect(cleared.phone, isNull);
      expect(cleared.wechat, 'pet-dad', reason: '没碰的字段不该被清掉');
    });
  });

  group('登录过户 · adoptAccount', () {
    test('账号 id 接管本地数据，created_by 一起改', () async {
      final users = UserRepository(db);
      final now = DateTime(2026, 9, 30);
      await users.create(LocalUser(
        id: UserRepository.localUserId,
        nickname: '我',
        region: 'local',
        createdAt: now,
        updatedAt: now,
        phone: '13800138000',
      ));
      await pets.create(Pet(
        id: 'p1',
        name: '豆豆',
        species: Species.dog,
        createdBy: UserRepository.localUserId,
        createdAt: now,
        updatedAt: now,
      ));
      await records.create(PetRecord(
        id: 'rec-a',
        petId: 'p1',
        type: RecordType.weight,
        recordedAt: now,
        createdBy: UserRepository.localUserId,
        createdAt: now,
        updatedAt: now,
        valueNum: 5,
      ));

      await users.adoptAccount(accountId: 'acct-9', region: 'cn');

      final user = (await users.current())!;
      expect(user.id, 'acct-9');
      expect(user.region, 'cn');
      // 本地填的联系方式不能被服务端那份空值覆盖。
      expect(user.phone, '13800138000');

      final petRows = await db.query('pets', where: 'id = ?', whereArgs: ['p1']);
      expect(petRows.first['created_by'], 'acct-9');
      final recRows = await db.query('records', where: 'id = ?', whereArgs: ['rec-a']);
      expect(recRows.first['created_by'], 'acct-9');
    });
  });

  group('费用仓储', () {
    test('按消费日期倒序，软删的不进列表', () async {
      final db = await _memDb();
      final repo = ExpenseRepository(db);

      await repo.createSimple(
        petId: 'p1',
        amount: 320,
        category: ExpenseCategory.food,
        spentAt: DateTime(2026, 9, 3),
        createdBy: 'u1',
      );
      final second = await repo.createSimple(
        petId: 'p1',
        amount: 120,
        category: ExpenseCategory.vaccine,
        spentAt: DateTime(2026, 9, 28),
        createdBy: 'u1',
      );
      await repo.createSimple(
        petId: 'p2',
        amount: 999,
        category: ExpenseCategory.other,
        spentAt: DateTime(2026, 9, 28),
        createdBy: 'u1',
      );

      var list = await repo.listByPet('p1');
      expect(list, hasLength(2));
      expect(list.first.amount, 120, reason: '最近的排最前');

      await repo.softDelete(second.id);
      list = await repo.listByPet('p1');
      expect(list, hasLength(1), reason: '软删的默认不返回');
      expect(await repo.findById(second.id), isNotNull,
          reason: '软删不是物理删，按 id 仍查得到');

      await db.close();
    });

    test('spentAt 归一化到当天零点，补录旧账不算进今天', () async {
      final db = await _memDb();
      final repo = ExpenseRepository(db);

      final e = await repo.createSimple(
        petId: 'p1',
        amount: 88,
        category: ExpenseCategory.grooming,
        // 带时分秒进来 —— 也会被压到当天 00:00。
        spentAt: DateTime(2026, 9, 9, 21, 37, 12),
        createdBy: 'u1',
      );
      expect(e.spentAt, DateTime(2026, 9, 9));
      expect(e.spentAt.hour, 0);

      final from = DateTime(2026, 9, 1);
      final to = DateTime(2026, 10, 1);
      expect(await repo.totalBetween('p1'), 88);
      expect(await repo.totalBetween('p1', from: from, to: to), 88);
      // 区间是左闭右开：to 本身不在区间内。
      expect(await repo.totalBetween('p1', to: DateTime(2026, 9, 9)), 0,
          reason: '9 月 9 日那笔不应被 9 月 9 日之前的区间算进去');
      // 没有支出时返回 0 而不是 null —— SQL 的 SUM 在空集上给 NULL，
      // 漏了这层转换，UI 上会直接印个 null。
      expect(await repo.totalBetween('p-empty'), 0);

      await db.close();
    });

    test('写入会进 outbox（同步的分发键是 pet_id）', () async {
      final db = await _memDb();
      final repo = ExpenseRepository(db);

      await repo.createSimple(
        petId: 'p1',
        amount: 45.5,
        category: ExpenseCategory.supply,
        spentAt: DateTime(2026, 9, 30),
        createdBy: 'u1',
      );

      final outbox = await db.query('sync_outbox');
      expect(outbox, hasLength(1));
      expect(outbox.first['table_name'], 'expenses');
      expect(outbox.first['pet_id'], 'p1');

      await db.close();
    });
  });

  group('共养角色 · 兼容旧值', () {
    test('老数据里的 caretaker 当 editor 处理', () {
      expect(MemberRoleX.fromWire('owner'), MemberRole.owner);
      expect(MemberRoleX.fromWire('caretaker'), MemberRole.editor);
      expect(MemberRoleX.fromWire('editor'), MemberRole.editor);
      expect(MemberRoleX.fromWire('viewer'), MemberRole.viewer);
      // 认不出来的值按最小权限给（editor），不能给 owner。
      expect(MemberRoleX.fromWire('whatever'), MemberRole.editor);
      expect(MemberRoleX.fromWire(null), MemberRole.editor);
    });

    test('权限判断：viewer 不能写，只有 owner 能管成员', () {
      expect(MemberRole.viewer.canWrite, isFalse);
      expect(MemberRole.editor.canWrite, isTrue);
      expect(MemberRole.editor.canManage, isFalse);
      expect(MemberRole.owner.canManage, isTrue);
    });
  });
}
