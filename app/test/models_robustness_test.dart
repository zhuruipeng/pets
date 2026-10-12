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
      // 必填时间给合法值（没有时间的记录本来就无意义，见下方 fromMap 的 `_dt(...)!`），
      // 其余字段全给脏数据 —— 结果必须是「能解析出来的部分照常、坏的退化」。
      expect(
        () => PetRecord.fromMap({
          'id': 'r1',
          'pet_id': 'p1',
          'type': 'weight',
          'recorded_at': 0,
          'created_by': 'local-user',
          'created_at': '1712345678000',
          'updated_at': '1712345678000',
          'payload': '{{{',
          'value_num': 'not-a-number',
        }),
        returnsNormally,
      );
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
