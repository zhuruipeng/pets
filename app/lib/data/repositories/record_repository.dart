/// 记录仓储。
///
/// 本文件唯一需要反复强调的事：
/// **recordedAt（事件发生时间）与 createdAt（入库时间）是两个字段，永远不要互相赋值。**
///
/// 用户会把纸质的疫苗本补录进 App，这条记录 recordedAt 可能是去年 3 月，
/// createdAt 却是今天。时间线按 recordedAt 排，同步按 updatedAt 走。
library;

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../models.dart';

class RecordRepository {
  RecordRepository([Database? db]) : _injected = db;

  final Database? _injected;

  static const _uuid = Uuid();
  static const String _table = 'records';

  Database get _db => _injected ?? AppDatabase.instance.db;

  /// 按宠物查记录，按事件时间倒序。
  Future<List<PetRecord>> listByPet(
    String petId, {
    RecordType? type,
    DateTime? from,
    DateTime? to,
    int? limit,
    bool includeDeleted = false,
  }) async {
    final where = <String>['pet_id = ?'];
    final args = <Object?>[petId];

    if (!includeDeleted) where.add('deleted_at IS NULL');
    if (type != null) {
      where.add('type = ?');
      args.add(type.wireName);
    }
    // 时间区间按 recorded_at 过滤，不是 created_at。
    if (from != null) {
      where.add('recorded_at >= ?');
      args.add(from.millisecondsSinceEpoch);
    }
    if (to != null) {
      where.add('recorded_at <= ?');
      args.add(to.millisecondsSinceEpoch);
    }

    final rows = await _db.query(
      _table,
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'recorded_at DESC, created_at DESC',
      limit: limit,
    );
    return rows.map(PetRecord.fromMap).toList();
  }

  Future<PetRecord?> findById(String id) async {
    final rows = await _db.query(_table, where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return PetRecord.fromMap(rows.first);
  }

  Future<PetRecord> create(PetRecord record) async {
    await _db.insert(_table, record.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort);
    return record;
  }

  /// 便捷新建：显式要求调用方传 recordedAt，避免顺手用 now() 掩盖补录语义。
  Future<PetRecord> createSimple({
    required String petId,
    required RecordType type,
    required DateTime recordedAt,
    required String createdBy,
    double? valueNum,
    String? valueText,
    String? unit,
    Map<String, dynamic> payload = const {},
    String? note,
  }) {
    final now = DateTime.now();
    return create(PetRecord(
      id: _uuid.v4(),
      petId: petId,
      type: type,
      recordedAt: recordedAt,
      valueNum: valueNum,
      valueText: valueText,
      unit: unit,
      payload: payload,
      note: note,
      createdBy: createdBy,
      createdAt: now,
      updatedAt: now,
    ));
  }

  Future<int> update(PetRecord record) async {
    final next = record.toMap()
      ..['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    return _db.update(_table, next, where: 'id = ?', whereArgs: [record.id]);
  }

  /// 只改事件时间，不动 createdAt。
  ///
  /// 为什么单开一个方法而不是调 [update]：详情页只想改「这件事什么时候发生的」，
  /// 而 [update] 要调用方把整行重新拼一遍 —— 漏一个字段就会把它清掉。
  /// createdAt 也刻意保持不变：它记录「什么时候录进来的」，是补录判定的依据。
  Future<PetRecord?> updateRecordedAt(String id, DateTime recordedAt) async {
    final n = await _db.update(
      _table,
      {
        'recorded_at': recordedAt.millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [id],
    );
    if (n == 0) return null;
    return findById(id);
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

  /// 体重序列。图表用，只取有数值的记录。
  Future<List<({DateTime at, double kg})>> weightSeries(String petId) async {
    final rows = await _db.query(
      _table,
      columns: ['recorded_at', 'value_num'],
      where: 'pet_id = ? AND type = ? AND deleted_at IS NULL AND value_num IS NOT NULL',
      whereArgs: [petId, RecordType.weight.wireName],
      orderBy: 'recorded_at ASC',
    );
    return rows
        .map((r) => (
              at: DateTime.fromMillisecondsSinceEpoch(r['recorded_at'] as int),
              kg: (r['value_num'] as num).toDouble(),
            ))
        .toList();
  }

  /// 某类型最近一次记录。提醒引擎用（比如上次驱虫是什么时候）。
  Future<PetRecord?> latestOfType(String petId, RecordType type) async {
    final rows = await _db.query(
      _table,
      where: 'pet_id = ? AND type = ? AND deleted_at IS NULL',
      whereArgs: [petId, type.wireName],
      orderBy: 'recorded_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PetRecord.fromMap(rows.first);
  }

  Future<int> countForPet(String petId) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM $_table WHERE pet_id = ? AND deleted_at IS NULL',
      [petId],
    );
    return (rows.first['c'] as num).toInt();
  }
}
