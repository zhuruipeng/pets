/// 遛狗轨迹仓储。
///
/// 本文件的核心约束：**轨迹点必须批量事务写入**。
/// GPS 每秒一个点，一次 30 分钟的遛狗是 1800 个点。
/// 逐条 insert 会在主线程上排队，直接卡住 UI。
library;

import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/region.dart';
import '../db/app_database.dart';
import '../models.dart';

class WalkRepository {
  WalkRepository([Database? db]) : _injected = db;

  final Database? _injected;

  static const _uuid = Uuid();
  static const String _sessions = 'walk_sessions';
  static const String _points = 'walk_points';

  /// 单点精度超过该阈值（米）视为漂移，不入库。
  static const double driftThresholdM = 50;

  /// 一次批量写入的最大点数，超过就分批，避免单条 SQL 过大。
  static const int batchChunkSize = 500;

  Database get _db => _injected ?? AppDatabase.instance.db;

  /// 开始一次遛狗。同一只宠物同时只允许一个进行中的 session。
  Future<WalkSession> startSession({
    required String petId,
    required String createdBy,
    String? region,
    DateTime? startedAt,
  }) async {
    final existing = await activeSession(petId);
    if (existing != null) return existing;

    final now = startedAt ?? DateTime.now();
    final session = WalkSession(
      id: _uuid.v4(),
      petId: petId,
      startedAt: now,
      // 写库时就带上分区标记，便于分区部署与审计。
      region: region ?? AppRegion.current.name,
      createdBy: createdBy,
      createdAt: now,
      updatedAt: now,
    );
    await _db.insert(_sessions, session.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort);
    return session;
  }

  Future<WalkSession?> activeSession(String petId) async {
    final rows = await _db.query(
      _sessions,
      where: 'pet_id = ? AND ended_at IS NULL AND deleted_at IS NULL',
      whereArgs: [petId],
      orderBy: 'started_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return WalkSession.fromMap(rows.first);
  }

  Future<WalkSession?> findSession(String id) async {
    final rows = await _db.query(_sessions, where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return WalkSession.fromMap(rows.first);
  }

  /// 批量写入轨迹点。整个批次在一个事务里提交。
  ///
  /// 返回实际入库的点数（已剔除漂移点）。
  Future<int> appendPoints(String sessionId, List<WalkPoint> points) async {
    if (points.isEmpty) return 0;

    final usable = points
        .where((p) => p.accuracy == null || p.accuracy! <= driftThresholdM)
        .toList();
    if (usable.isEmpty) return 0;

    var written = 0;
    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (var i = 0; i < usable.length; i++) {
        batch.insert(
          _points,
          usable[i].toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        // 分批提交，避免单个 batch 过大占用内存。
        if ((i + 1) % batchChunkSize == 0) {
          await batch.commit(noResult: true);
          written += batchChunkSize;
        }
      }
      await batch.commit(noResult: true);
    });

    written = usable.length;
    return written;
  }

  /// 结束一次遛狗，回算距离与时长并落库。
  Future<WalkSession> endSession(String sessionId, {DateTime? endedAt}) async {
    final session = await findSession(sessionId);
    if (session == null) {
      throw StateError('walk session $sessionId 不存在');
    }

    final now = endedAt ?? DateTime.now();
    final points = await pointsOf(sessionId);
    final distance = totalDistanceM(points);

    final updated = WalkSession(
      id: session.id,
      petId: session.petId,
      startedAt: session.startedAt,
      endedAt: now,
      distanceM: distance,
      durationS: now.difference(session.startedAt).inSeconds,
      region: session.region,
      createdBy: session.createdBy,
      createdAt: session.createdAt,
      updatedAt: now,
      deletedAt: session.deletedAt,
    );

    await _db.update(_sessions, updated.toMap(),
        where: 'id = ?', whereArgs: [sessionId]);
    return updated;
  }

  /// 结束后补录心情与备注。
  ///
  /// 为什么不塞进 [endSession]：距离和时长是**算出来的**，点「结束」就该定下来；
  /// 心情和备注是**用户看完结果才填的**。合成一个方法会让「停止记录」这个动作
  /// 卡在一个弹层上 —— 万一中途退出，连轨迹都没了。
  Future<WalkSession?> setFeedback(
    String sessionId, {
    String? mood,
    String? note,
  }) async {
    final now = DateTime.now();
    await _db.update(
      _sessions,
      {
        'mood': mood,
        'note': note,
        'updated_at': now.millisecondsSinceEpoch,
      },
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [sessionId],
    );
    return findSession(sessionId);
  }

  Future<List<WalkPoint>> pointsOf(String sessionId) async {
    final rows = await _db.query(
      _points,
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'recorded_at ASC',
    );
    return rows.map(WalkPoint.fromMap).toList();
  }

  Future<List<WalkSession>> listSessions(String petId, {int? limit}) async {
    final rows = await _db.query(
      _sessions,
      where: 'pet_id = ? AND deleted_at IS NULL AND ended_at IS NOT NULL',
      whereArgs: [petId],
      orderBy: 'started_at DESC',
      limit: limit,
    );
    return rows.map(WalkSession.fromMap).toList();
  }

  /// 哈弗辛公式累计距离。
  ///
  /// 用 haversine 而不是平面勾股：遛狗跨几个街区没问题，
  /// 但平面近似在城市尺度外的误差会累积得很快。
  static double totalDistanceM(List<WalkPoint> points) {
    if (points.length < 2) return 0;
    var total = 0.0;
    for (var i = 1; i < points.length; i++) {
      total += _haversineM(
        points[i - 1].lat,
        points[i - 1].lng,
        points[i].lat,
        points[i].lng,
      );
    }
    return total;
  }

  static double _haversineM(double lat1, double lng1, double lat2, double lng2) {
    const earthRadiusM = 6371000.0;
    final dLat = _rad(lat2 - lat1);
    final dLng = _rad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(lat1)) *
            math.cos(_rad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return earthRadiusM * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _rad(double deg) => deg * math.pi / 180.0;

  Future<int> softDelete(String sessionId, {DateTime? at}) async {
    final now = at ?? DateTime.now();
    return _db.update(
      _sessions,
      {
        'deleted_at': now.millisecondsSinceEpoch,
        'updated_at': now.millisecondsSinceEpoch,
      },
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [sessionId],
    );
  }
}
