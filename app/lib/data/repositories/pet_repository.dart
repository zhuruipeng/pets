/// 宠物仓储。所有查询默认过滤软删除。
///
/// 约定：仓储只做数据存取，不写业务判断。业务规则放 domain/。
library;

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../../core/species.dart';

class PetRepository {
  PetRepository([Database? db]) : _injected = db;

  final Database? _injected;

  static const _uuid = Uuid();

  Database get _db => _injected ?? AppDatabase.instance.db;

  static const String _table = 'pets';

  /// 列表。默认不含已归档（离世归档）与已删除。
  Future<List<Pet>> listAll({
    bool includeArchived = false,
    bool includeDeleted = false,
  }) async {
    final where = <String>[];
    if (!includeDeleted) where.add('deleted_at IS NULL');
    if (!includeArchived) where.add('archived_at IS NULL');

    final rows = await _db.query(
      _table,
      where: where.isEmpty ? null : where.join(' AND '),
      orderBy: 'created_at ASC',
    );
    return rows.map(Pet.fromMap).toList();
  }

  /// 按 id 查。软删除后仍能查到（带 deletedAt 标记），用于同步与恢复。
  Future<Pet?> findById(String id, {bool includeDeleted = true}) async {
    final rows = await _db.query(
      _table,
      where: includeDeleted ? 'id = ?' : 'id = ? AND deleted_at IS NULL',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Pet.fromMap(rows.first);
  }

  /// 新建。id 与时间戳由调用方给定，仓储不擅自生成，
  /// 便于离线创建后再同步到服务端时保持 id 稳定。
  Future<Pet> create(Pet pet) async {
    await _db.insert(_table, pet.toMap(), conflictAlgorithm: ConflictAlgorithm.abort);
    return pet;
  }

  /// 便捷新建：给最少信息就能落库。
  Future<Pet> createSimple({
    required String name,
    required String speciesWire,
    required String createdBy,
    DateTime? birthday,
    String? breed,
  }) {
    final now = DateTime.now();
    return create(Pet(
      id: _uuid.v4(),
      name: name,
      species: speciesFromWireLoose(speciesWire),
      createdBy: createdBy,
      createdAt: now,
      updatedAt: now,
      birthday: birthday,
      breed: breed,
    ));
  }

  Future<int> update(Pet pet) async {
    final next = pet.toMap()
      ..['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    return _db.update(_table, next, where: 'id = ?', whereArgs: [pet.id]);
  }

  /// 离世归档。不硬删，数据仍可导出。
  Future<int> archive(String id, {DateTime? at}) async {
    final now = at ?? DateTime.now();
    return _db.update(
      _table,
      {
        'archived_at': now.millisecondsSinceEpoch,
        'updated_at': now.millisecondsSinceEpoch,
      },
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [id],
    );
  }

  Future<int> unarchive(String id) async {
    return _db.update(
      _table,
      {
        'archived_at': null,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 软删除。返回受影响行数。
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

  /// 撤销删除。
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

  Future<int> count({bool includeDeleted = false}) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM $_table'
      '${includeDeleted ? '' : ' WHERE deleted_at IS NULL'}',
    );
    return (rows.first['c'] as num).toInt();
  }
}
