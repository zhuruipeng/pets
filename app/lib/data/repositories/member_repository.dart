/// 共养成员仓储。
///
/// 角色与权限的口径以 docs/同步协议.md 第五节的矩阵为准 ——
/// 本地只做展示与轻量判断，**真正的权限判定在服务端**（客户端不可信）。
library;

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';

/// 共养角色。三档，与同步协议的权限矩阵一一对应。
///
/// 早期只有 owner / caretaker。v4 把 caretaker 改名成 editor 并加了 viewer：
/// 保留旧名会让「caretaker 到底能不能改档案」永远说不清。
enum MemberRole { owner, editor, viewer }

extension MemberRoleX on MemberRole {
  String get wireName => name;

  /// 解析。`caretaker` 是 v4 之前的旧值，老数据（或还没升级的设备推上来的）
  /// 一律当 editor 处理 —— 它原先的语义就是「能记录但不能管成员」。
  static MemberRole fromWire(String? raw) => switch ((raw ?? '').trim()) {
        'owner' => MemberRole.owner,
        'viewer' => MemberRole.viewer,
        'caretaker' || 'editor' => MemberRole.editor,
        _ => MemberRole.editor,
      };

  /// 能不能写数据（记录 / 提醒 / 遛狗 / 档案）。viewer 只能看。
  bool get canWrite => this != MemberRole.viewer;

  /// 能不能管成员与删宠物。
  bool get canManage => this == MemberRole.owner;
}

/// 邀请状态。pending 期间**没有读权限** —— 邀请不等于授权。
enum MemberStatus { pending, active }

class PetMember {
  const PetMember({
    required this.id,
    required this.petId,
    required this.userId,
    required this.role,
    required this.joinedAt,
    this.status = MemberStatus.active,
    this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String petId;
  final String userId;
  final MemberRole role;
  final DateTime joinedAt;
  final MemberStatus status;

  /// 同步的 LWW 基准（v4 补的列）。
  final DateTime? updatedAt;

  final DateTime? deletedAt;

  DateTime get effectiveUpdatedAt => updatedAt ?? deletedAt ?? joinedAt;

  factory PetMember.fromMap(Map<String, dynamic> m) => PetMember(
        id: m['id'] as String,
        petId: m['pet_id'] as String,
        userId: m['user_id'] as String,
        role: MemberRoleX.fromWire(m['role'] as String?),
        status: (m['status'] as String?) == 'pending'
            ? MemberStatus.pending
            : MemberStatus.active,
        joinedAt:
            DateTime.fromMillisecondsSinceEpoch(m['joined_at'] as int),
        updatedAt: m['updated_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['updated_at'] as int),
        deletedAt: m['deleted_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['deleted_at'] as int),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'pet_id': petId,
        'user_id': userId,
        'role': role.wireName,
        'status': status.name,
        'joined_at': joinedAt.millisecondsSinceEpoch,
        'updated_at': effectiveUpdatedAt.millisecondsSinceEpoch,
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
    MemberRole role = MemberRole.editor,
    MemberStatus status = MemberStatus.active,
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
        {
          'role': role.wireName,
          'status': MemberStatus.active.name,
          'deleted_at': null,
          'joined_at': now.millisecondsSinceEpoch,
          'updated_at': now.millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      return PetMember(
        id: id,
        petId: petId,
        userId: userId,
        role: role,
        joinedAt: now,
        updatedAt: now,
      );
    }

    final member = PetMember(
      id: _uuid.v4(),
      petId: petId,
      userId: userId,
      role: role,
      status: status,
      joinedAt: now,
      updatedAt: now,
    );
    await _db.insert(_table, member.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort);
    return member;
  }

  Future<int> remove(String petId, String userId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _db.update(
      _table,
      {'deleted_at': now, 'updated_at': now},
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
