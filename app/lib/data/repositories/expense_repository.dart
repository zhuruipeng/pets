/// 费用仓储。
///
/// 与 [RecordRepository] 的分工：**记录是事件，费用是钱的流向。**
/// 一次就诊（事件）可能对应三笔钱（挂号 + 药 + 化验），也可能一分钱没花
/// （朋友送的药）。所以两者不合并、也不互相推导 —— 想关联时用
/// [Expense.recordId] 单边挂上去，不强求一一对应。
///
/// 金额一律用 [double] 存最小货币单位之上（`amount REAL`）。
/// 为什么不用「分」的整数：SQLite 的 REAL 在 1e-2 精度上完全够用，
/// 而换算成整数分会让「12.5 元」这种输入在展示层到处要除 100。
library;

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../models.dart';

class ExpenseRepository {
  ExpenseRepository([Database? db]) : _injected = db;

  final Database? _injected;

  static const _uuid = Uuid();
  static const String _table = 'expenses';

  Database get _db => _injected ?? AppDatabase.instance.db;

  /// 按宠物查支出，按消费日期倒序。
  Future<List<Expense>> listByPet(
    String petId, {
    DateTime? from,
    DateTime? to,
    int? limit,
    bool includeDeleted = false,
  }) async {
    final where = <String>['pet_id = ?'];
    final args = <Object?>[petId];

    if (!includeDeleted) where.add('deleted_at IS NULL');
    // 区间按 spent_at 过滤，不是 created_at —— 补录上个月的账要算进上个月。
    if (from != null) {
      where.add('spent_at >= ?');
      args.add(from.millisecondsSinceEpoch);
    }
    if (to != null) {
      where.add('spent_at < ?');
      args.add(to.millisecondsSinceEpoch);
    }

    final rows = await _db.query(
      _table,
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'spent_at DESC, created_at DESC',
      limit: limit,
    );
    return rows.map(Expense.fromMap).toList();
  }

  Future<Expense?> findById(String id) async {
    final rows =
        await _db.query(_table, where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Expense.fromMap(rows.first);
  }

  Future<Expense> create(Expense expense) async {
    await _db.insert(_table, expense.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort);
    return expense;
  }

  /// 便捷新建。默认币种由区域决定（见 RegionBehavior.defaultCurrency）。
  ///
  /// [spentAt] 默认今天 00:00 而不是 now()：费用是「哪天花」而不是「几点花」，
  /// 存到秒会让「同一天的两笔」在按月聚合之外还会因排序抖动，也没意义。
  Future<Expense> createSimple({
    required String petId,
    required double amount,
    required ExpenseCategory category,
    required DateTime spentAt,
    required String createdBy,
    String currency = 'CNY',
    String? note,
    String? recordId,
  }) {
    final now = DateTime.now();
    return create(Expense(
      id: _uuid.v4(),
      petId: petId,
      amount: amount,
      currency: currency,
      category: category,
      spentAt: DateTime(spentAt.year, spentAt.month, spentAt.day),
      note: note,
      recordId: recordId,
      createdBy: createdBy,
      createdAt: now,
      updatedAt: now,
    ));
  }

  Future<int> update(Expense expense) async {
    final next = expense.toMap()
      ..['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    return _db.update(_table, next, where: 'id = ?', whereArgs: [expense.id]);
  }

  Future<int> softDelete(String id, {DateTime? at}) async {
    final now = at ?? DateTime.now();
    return _db.update(
      _table,
      {
        'deleted_at': now.millisecondsSinceEpoch,
        'updated_at': now.millisecondsSinceEpoch,
      },
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [id],
    );
  }

  Future<int> restore(String id) async {
    return _db.update(
      _table,
      {
        'deleted_at': null,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 区间合计。没有支出时返回 0 —— SQL 的 SUM 会返回 NULL，
  /// 这里必须自己做转换，否则 `double?` 会顺着调用链一路冒到 UI。
  Future<double> totalBetween(
    String petId, {
    DateTime? from,
    DateTime? to,
  }) async {
    final where = <String>['pet_id = ?', 'deleted_at IS NULL'];
    // args 的顺序必须跟着 where 里占位符出现的顺序走，不能先攒后拼。
    final args = <Object?>[petId];
    if (from != null) {
      where.add('spent_at >= ?');
      args.add(from.millisecondsSinceEpoch);
    }
    if (to != null) {
      where.add('spent_at < ?');
      args.add(to.millisecondsSinceEpoch);
    }

    final rows = await _db.rawQuery(
      'SELECT SUM(amount) AS s FROM $_table WHERE ${where.join(' AND ')}',
      args,
    );
    return (rows.first['s'] as num?)?.toDouble() ?? 0;
  }

  Future<int> countForPet(String petId) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM $_table '
      'WHERE pet_id = ? AND deleted_at IS NULL',
      [petId],
    );
    return (rows.first['c'] as num).toInt();
  }
}
