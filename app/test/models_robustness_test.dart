/// 数据健壮性测试（2026-10-11 P2）。
///
/// 覆盖两件「不修就静默出错」的事：
///
/// 1. `models.dart` 的转换助手对**脏数据**必须当缺省值处理，不能抛 ——
///    抛了会让整个 `fromMap` 失败，`FutureProvider` 变 error，用户**打不开
///    自己的宠物页**。抽之前 `_strList` 有 try/catch 而 `_json` / `_dt` /
///    `_bool` 是硬 cast，同一个风险四个函数只防了一个。
///
/// 2. 同步表清单只能有**一处真值** —— 抽之前 `kSyncedTables`（谁产生变更）
///    与 `kSyncableTables`（谁能被应用）是两份手写列表，加表只改一处就
///    某类数据静默不同步。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/data/db/schema.dart';
import 'package:pet_app/data/models.dart';
import 'package:pet_app/data/sync/sync_engine.dart';
import 'package:pet_app/domain/sync_ids.dart';

void main() {
  group('models 转换助手 — 脏数据不抛异常', () {
    // fromMap 是唯一入口，直接喂坏数据进去看会不会炸。
    // PetRecord.fromMap 里 _dt / _json / _bool 全都会走到。

    test('时间戳是字符串也能解析（SQLite INTEGER 经 JSON 往返会变字符串）', () {
      final r = PetRecord.fromMap({
        'id': 'r1',
        'pet_id': 'p1',
        'type': 'weight',
        'recorded_at': '1712345678000', // 字符串
        'created_by': 'local-user',
        'created_at': 1712345678000,
        'updated_at': 1712345678000,
      });
      expect(r.recordedAt.millisecondsSinceEpoch, 1712345678000);
    });

    test('可选时间戳是垃圾值 → 静默退化成 null，而不是崩溃', () {
      // deleted_at / birthday 这类**可选**时间字段走 _dt 后没有 `!`，
      // 所以坏数据应该安静地变成 null。抽之前是 `v as int` → 直接抛。
      final p = Pet.fromMap({
        'id': 'p1',
        'name': '团子',
        'species': 'dog',
        'birthday': 'not-a-number',
        'created_by': 'local-user',
        'created_at': 0,
        'updated_at': 0,
      });
      expect(p.birthday, isNull);
    });

    test('payload 是坏 JSON → 当空 Map，不抛', () {
      final r = PetRecord.fromMap({
        'id': 'r1',
        'pet_id': 'p1',
        'type': 'weight',
        'recorded_at': 0,
        'created_by': 'local-user',
        'created_at': 0,
        'updated_at': 0,
        'payload': '{不是合法 JSON',
      });
      expect(r.payload, isEmpty);
    });

    test('payload 是合法 JSON 但不是对象 → 当空 Map，不抛', () {
      final r = PetRecord.fromMap({
        'id': 'r1',
        'pet_id': 'p1',
        'type': 'weight',
        'recorded_at': 0,
        'created_by': 'local-user',
        'created_at': 0,
        'updated_at': 0,
        'payload': '[1,2,3]',
      });
      expect(r.payload, isEmpty);
    });

    test('payload 类型完全不对（数字）→ 当空 Map，不抛', () {
      final r = PetRecord.fromMap({
        'id': 'r1',
        'pet_id': 'p1',
        'type': 'weight',
        'recorded_at': 0,
        'created_by': 'local-user',
        'created_at': 0,
        'updated_at': 0,
        'payload': 42,
      });
      expect(r.payload, isEmpty);
    });

    test('布尔字段是 0/1/字符串 → 都能读出正确结果，不抛', () {
      // Pet.neutered 走 _bool。
      Pet parse(Object? v) => Pet.fromMap({
            'id': 'p1',
            'name': '团子',
            'species': 'dog',
            'neutered': v,
            'created_by': 'local-user',
            'created_at': 0,
            'updated_at': 0,
          });
      expect(parse(1).neutered, isTrue);
      expect(parse(true).neutered, isTrue);
      expect(parse('1').neutered, isTrue);
      expect(parse(0).neutered, isFalse);
      expect(parse(null).neutered, isFalse);
      expect(parse('垃圾').neutered, isFalse); // 不抛
    });

    test('整条脏行也不让 fromMap 炸（这是用户「打不开页面」的直接原因）', () {
      // 每一个非 id 字段全给脏数据 —— 结果必须是「能解析出来的部分照常、
      // 坏的退化」，**绝不抛**。
      //
      // 为什么这条测试重要：`RecordRepository.listByPet` 是
      // `rows.map(PetRecord.fromMap).toList()`，**一行脏数据就会让整个
      // `FutureProvider` 变 error ⇒ 整页显示「出错了」**。
      // 用户看到的是「我的宠物页坏了」，而不是「有一条记录时间不对」。
      late PetRecord r;
      expect(
        () => r = PetRecord.fromMap({
          'id': 'r1',
          'pet_id': 'p1',
          'type': 'weight',
          'recorded_at': 0,
          'created_by': 'local-user',
          'created_at': '1712345678000', // 数字字符串：能救回来
          'updated_at': '', // 救不回来 → epoch 0
          'payload': '{{{', // 坏 JSON → 空 Map
          'value_num': 'not-a-number', // 坏数值 → null
        }),
        returnsNormally,
      );

      // ⚠️ 光断言「不抛」不够 —— 它管不住兜底**兜到了哪儿**。
      // 下面这几条才是契约：能救的救回来，救不回来的退化成**显眼**的
      // 缺省值（epoch 0 → 界面显示 1970 年，用户看得见、改得回来），
      // 而不是编一个「看着合理」的时间把错误盖住。
      //
      // ⚠️ 比 `millisecondsSinceEpoch` 而不是 `DateTime(1970, 1, 1)`：
      // 后者是**本地**零点，在 UTC+8 机器上是 epoch 0 的 08:00，
      // 直接比 DateTime 会挂（实测踩过）。比毫秒值与运行机器时区无关。
      expect(r.recordedAt.millisecondsSinceEpoch, 0, reason: '坏时间 → epoch 0');
      expect(r.createdAt.millisecondsSinceEpoch, 1712345678000);
      expect(r.updatedAt.millisecondsSinceEpoch, 0,
          reason: '坏时间 → epoch 0，不编造');
      expect(r.payload, isEmpty);
      expect(r.valueNum, isNull);
      expect(r.id, 'r1');

      // 反向：合法行必须原样解析，别把兜底写成了「一律 epoch 0」。
      final ok = PetRecord.fromMap({
        'id': 'r2',
        'pet_id': 'p1',
        'type': 'weight',
        'recorded_at': 1712345678000,
        'created_by': 'local-user',
        'created_at': 1712345678000,
        'updated_at': 1712345678000,
        'value_num': 4.5,
      });
      expect(ok.recordedAt.millisecondsSinceEpoch, 1712345678000);
      expect(ok.updatedAt.millisecondsSinceEpoch, 1712345678000);
      expect(ok.valueNum, 4.5);
    });

    test('时间列脏数据退化成 epoch 0，不 fallback 到「看着合理」的值', () {
      // 这条是上面那条的**设计意图**锁定：如果哪天有人把 `?? _epoch`
      // 改成 `?? DateTime.now()` 或 `?? created_at`，会在这里被拦下。
      //
      // 理由（写给未来的自己）：补录旧账时「这笔钱花在哪天」是账务事实。
      // fallback 到 created_at 会把补录的旧账**静默算进当月**，
      // 这是一笔看不见的错账；epoch 0 显示成 1970 年会被一眼发现。
      final e = Expense.fromMap({
        'id': 'x',
        'pet_id': 'p1',
        'amount_cents': 100,
        'currency': 'CNY',
        'category': 'food',
        'spent_at': 'garbage',
        'created_by': 'u',
        'created_at': 1712345678000,
        'updated_at': 1712345678000,
      });
      expect(e.spentAt.millisecondsSinceEpoch, 0,
          reason: '坏 spent_at 不能借用 created_at —— 那会静默错账');
      expect(e.spentAt.millisecondsSinceEpoch,
          isNot(e.createdAt.millisecondsSinceEpoch));
      expect(e.createdAt.millisecondsSinceEpoch, 1712345678000);
    });
  });

  group('同步表清单 —— 单一来源', () {
    test('kSyncableTables 就是 kSyncedTables 的表名投影', () {
      // 这条断言的意义：以后有人在 schema.dart 加表，sync_engine 自动跟上，
      // 不会出现「产生变更但应用不了」的静默失效。
      expect(kSyncableTables, kSyncedTableNames);
    });

    test('两份清单元素个数一致（防住「改了一处」）', () {
      expect(kSyncableTables.length, kSyncedTables.length);
    });

    test('表名不重复（重复会让触发器名冲突、建库失败）', () {
      expect(kSyncedTables.map((t) => t.table).toSet().length,
          kSyncedTables.length);
    });

    test('每张同步表都带 deleted_at 或显式声明没有（不留未决项）', () {
      // users 是唯一没有 deleted_at 的表（账号不做软删除）。
      final withoutDeletedAt =
          kSyncedTables.where((t) => !t.hasDeletedAt).map((t) => t.table);
      expect(withoutDeletedAt, ['users']);
    });
  });

  group('sync_ids —— 给药完成行 id', () {    test('拼法：dose_{reminderId}_{dueMillis}', () {
      final id = doseRecordId(
        reminderId: 'rem-1',
        dueAt: DateTime.fromMillisecondsSinceEpoch(1712345678000),
      );
      expect(id, 'dose_rem-1_1712345678000');
    });

    test('同一方案同一时刻 → 幂等（多设备离线各记一次仍是同一行）', () {
      final a = doseRecordId(
        reminderId: 'rem-1',
        dueAt: DateTime.fromMillisecondsSinceEpoch(1712345678000),
      );
      final b = doseRecordId(
        reminderId: 'rem-1',
        dueAt: DateTime.fromMillisecondsSinceEpoch(1712345678000),
      );
      expect(a, b);
    });

    test('不同应服时刻 → 不同 id（两次给药不能被合并成一次）', () {
      final a = doseRecordId(
        reminderId: 'rem-1',
        dueAt: DateTime.fromMillisecondsSinceEpoch(1712345678000),
      );
      final b = doseRecordId(
        reminderId: 'rem-1',
        dueAt: DateTime.fromMillisecondsSinceEpoch(1712345679000),
      );
      expect(a, isNot(b));
    });

    test('isDoseRecordId 认得自己拼出来的、认不出普通 uuid', () {
      expect(
        isDoseRecordId(doseRecordId(
            reminderId: 'r', dueAt: DateTime.fromMillisecondsSinceEpoch(1))),
        isTrue,
      );
      expect(isDoseRecordId('3f9c1e2a-0000-4000-8000-000000000000'), isFalse);
      expect(isDoseRecordId('log_r_1'), isFalse);
    });

    test('提醒日志 id 同理，且与给药 id 不混淆', () {
      final log = reminderLogId(
          reminderId: 'r', dueAt: DateTime.fromMillisecondsSinceEpoch(1));
      expect(isReminderLogId(log), isTrue);
      expect(isDoseRecordId(log), isFalse);
    });
  });

  group('金额 —— 整数分（P2 数据正确性）', () {
    test('元 → 分：两位小数必须精确，不能截断', () {
      // 12.35 * 100 在 IEEE754 里是 1234.9999999999998，
      // 直接 toInt() 会截成 1234 —— 每笔少一分。必须 round()。
      expect(yuanToCents(12.35), 1235);
      expect(yuanToCents(12.34), 1234);
      expect(yuanToCents(0.07), 7);
      expect(yuanToCents(0.1), 10);
      expect(yuanToCents(120), 12000);
      expect(yuanToCents(0), 0);
      expect(yuanToCents(-12.5), -1250);
    });

    test('元 ⇄ 分 往返无损（两位以内的值）', () {
      for (final v in <double>[0, 1, 12.34, 12.35, 99.99, 0.07, 1234.56]) {
        expect(centsToYuan(yuanToCents(v)), v, reason: '往返失败：$v');
      }
    });

    test('NaN / 无穷 必须抛，不能静默变 0', () {
      // 静默变 0 的后果：用户清空金额框 → 静默记一笔 0 元支出。
      expect(() => yuanToCents(double.nan), throwsArgumentError);
      expect(() => yuanToCents(double.infinity), throwsArgumentError);
      expect(() => yuanToCents(double.negativeInfinity), throwsArgumentError);
    });

    test('Expense.amount getter 由 amountCents 派生（不存独立 double）', () {
      final e = Expense(
        id: 'e1',
        petId: 'p1',
        amountCents: 1235,
        currency: 'CNY',
        category: ExpenseCategory.food,
        spentAt: DateTime(2026, 9, 1),
        createdBy: 'u1',
        createdAt: DateTime(2026, 9, 1),
        updatedAt: DateTime(2026, 9, 1),
      );
      expect(e.amount, 12.35);
      expect(e.amountCents, 1235);
    });

    test('toMap 写的是 amount_cents（列名必须与 schema 一致）', () {
      final e = Expense.fromYuan(
        id: 'e1',
        petId: 'p1',
        yuan: 12.35,
        currency: 'CNY',
        category: ExpenseCategory.food,
        spentAt: DateTime(2026, 9, 1),
        createdBy: 'u1',
        createdAt: DateTime(2026, 9, 1),
        updatedAt: DateTime(2026, 9, 1),
      );
      expect(e.toMap()['amount_cents'], 1235);
      expect(e.toMap().containsKey('amount'), isFalse,
          reason: '旧列名不该再出现，否则 schema v8 迁移后会写进不存在的列');
    });

    test('fromMap 读 amount_cents', () {
      final e = Expense.fromMap({
        'id': 'e1',
        'pet_id': 'p1',
        'amount_cents': 1235,
        'currency': 'CNY',
        'category': 'food',
        'spent_at': 0,
        'created_by': 'u1',
        'created_at': 0,
        'updated_at': 0,
      });
      expect(e.amountCents, 1235);
      expect(e.amount, 12.35);
    });
  });
}
