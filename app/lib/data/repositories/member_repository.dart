/// 共养成员仓储。MVP 只做邀请与角色，不做权限矩阵。
library;

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';

/// 共养角色。owner 可移除成员，caretaker 只能记录。
enum MemberRole { owner, caretaker }

class PetMember {
  const PetMember({
    required this.id,
    required this.petId,
    required this.userId,
    required this.role,
    required this.joinedAt,
    this.deletedAt,
  });

  final String id;
  final String petId;
  final String userId;
  final MemberRole role;
  final DateTime joinedAt;
  final DateTime? deletedAt;

  factory PetMember.fromMap(Map<String, dynamic> m) => PetMember(
        id: m['id'] as String,
        petId: m['pet_id'] as String,
        userId: m['user_id'] as String,
        role: m['role'] == 'owner' ? MemberRole.owner : MemberRole.caretaker,
        joinedAt:
            DateTime.fromMillisecondsSinceEpoch(m['joined_at'] as int),
        deletedAt: m['deleted_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['deleted_at'] as int),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'pet_id': petId,
        'user_id': userId,
        'role': role.name,
        'joined_at': joinedAt.millisecondsSinceEpoch,
        'deleted_at': deletedAt?.millisecondsSinceEpoch,
      };
}

class MemberRepository {
  MemberRepository([Database? db]) : _injected = db;

  final Database? _injected;

  static const _uuid = Uuid();
  static const String _table = 'members';

  Database get _db => _injected ?? AppDatabase.instance.db;

  Future<List<PetMember>> listByPet(String petId) async {
    final rows = await _db.query(
      _table,
      where: 'pet_id = ? AND deleted_at IS NULL',
      whereArgs: [petId],
      orderBy: 'joined_at ASC',
    );
    return rows.map(PetMember.fromMap).toList();
  }

  /// 加成员。同 (pet_id, user_id) 已存在时复活原记录，而不是插新的。
  Future<PetMember> add({
    required String petId,
    required String userId,
    MemberRole role = MemberRole.caretaker,
  }) async {
    final existing = await _db.query(
      _table,
      where: 'pet_id = ? AND user_id = ?',
      whereArgs: [petId, userId],
      limit: 1,
    );

    final now = DateTime.now();
    if (existing.isNotEmpty) {
      final id = existing.first['id'] as String;
      await _db.update(
        _table,
        {'role': role.name, 'deleted_at': null, 'joined_at': now.millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [id],
      );
      return PetMember(
        id: id,
        petId: petId,
        userId: userId,
        role: role,
        joinedAt: now,
      );
    }

    final member = PetMember(
      id: _uuid.v4(),
      petId: petId,
      userId: userId,
      role: role,
      joinedAt: now,
    );
    await _db.insert(_table, member.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort);
    return member;
  }

  Future<int> remove(String petId, String userId) async {
    return _db.update(
      _table,
      {'deleted_at': DateTime.now().millisecondsSinceEpoch},
      where: 'pet_id = ? AND user_id = ? AND deleted_at IS NULL',
      whereArgs: [petId, userId],
    );
  }

  Future<bool> isMember(String petId, String userId) async {
    final rows = await _db.query(
      _table,
      where: 'pet_id = ? AND user_id = ? AND deleted_at IS NULL',
      whereArgs: [petId, userId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }
}
