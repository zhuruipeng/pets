/// 附件仓储 —— 记录的照片/单据，挂在 record 上，软删除与 records 同一套约定。
///
/// 两条硬规则：
/// 1. **入库前必须把图片拷进应用文档目录** —— 相册缓存随时可能被系统清掉，
///    直接存 content:// 或相册路径，三个月后缩略图就是一排灰块。
/// 2. **软删除只置 deleted_at，物理文件不动** —— 记录可以恢复，
///    附件跟着恢复；物理清理交给将来的维护任务，别在删除路径上顺手删文件。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../models.dart';

class AttachmentRepository {
  AttachmentRepository([Database? db]) : _injected = db;

  final Database? _injected;

  static const _uuid = Uuid();
  static const String _table = 'attachments';

  Database get _db => _injected ?? AppDatabase.instance.db;

  Future<List<RecordAttachment>> listByRecord(
    String recordId, {
    bool includeDeleted = false,
  }) async {
    final rows = await _db.query(
      _table,
      where: includeDeleted
          ? 'record_id = ?'
          : 'record_id = ? AND deleted_at IS NULL',
      whereArgs: [recordId],
      orderBy: 'created_at ASC',
    );
    return rows.map(RecordAttachment.fromMap).toList();
  }

  Future<RecordAttachment?> findById(String id) async {
    final rows = await _db
        .query(_table, where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return RecordAttachment.fromMap(rows.first);
  }

  /// 一只宠物的全部照片（跨记录）。档案页的「回忆」相册用。
  ///
  /// 走 JOIN 而不是「先查记录再逐条查附件」：后者是 N+1，一只记录多的宠物
  /// 会发出几十次查询。照片按时间倒序 —— 相册永远是「最近的先看到」。
  Future<List<RecordAttachment>> listPhotosByPet(
    String petId, {
    bool includeDeleted = false,
  }) async {
    final rows = await _db.rawQuery(
      'SELECT a.* FROM $_table a '
      'JOIN records r ON r.id = a.record_id '
      'WHERE r.pet_id = ? '
      '${includeDeleted ? '' : 'AND a.deleted_at IS NULL AND r.deleted_at IS NULL '}'
      'ORDER BY a.created_at DESC',
      [petId],
    );
    return rows.map(RecordAttachment.fromMap).toList();
  }

  /// 把一张已存在的图片文件收编为附件：拷贝 → 落库。
  ///
  /// [sourcePath] 通常是 image_picker 给的临时文件。拷贝失败就整体失败，
  /// 不落库 —— 绝不留一条指向临时路径的死附件。
  Future<RecordAttachment> addPhoto({
    required String recordId,
    required String sourcePath,
    int? width,
    int? height,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final attDir = Directory(p.join(dir.path, 'attachments'));
    if (!attDir.existsSync()) attDir.createSync(recursive: true);

    final src = File(sourcePath);
    if (!src.existsSync()) {
      throw StateError('附件源文件不存在: $sourcePath');
    }
    final ext = p.extension(sourcePath).isEmpty
        ? '.jpg'
        : p.extension(sourcePath).toLowerCase();
    final destPath = p.join(attDir.path, '${_uuid.v4()}$ext');
    await src.copy(destPath);

    final now = DateTime.now();
    final att = RecordAttachment(
      id: _uuid.v4(),
      recordId: recordId,
      kind: 'photo',
      localPath: destPath,
      width: width,
      height: height,
      createdAt: now,
      // 同步的 LWW 基准。创建时与 createdAt 相等，但显式写上 ——
      // 触发器取的是 NEW.updated_at，为 NULL 会让这条变更排在所有变更最前面。
      updatedAt: now,
    );
    await _db.insert(_table, att.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort);
    return att;
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
    final now = DateTime.now().millisecondsSinceEpoch;
    return _db.update(
      _table,
      {'deleted_at': null, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> countForRecord(String recordId) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM $_table '
      'WHERE record_id = ? AND deleted_at IS NULL',
      [recordId],
    );
    return (rows.first['c'] as num).toInt();
  }
}
