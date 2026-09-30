/// 提醒仓储。
///
/// 提醒是回访引擎：完成一次 → 系统按规则自动排下一次。
/// 所以这里最关键的是 [completeOnce]，它做三件事：
/// 1. 写一条 reminder_logs（留档，用于完成率统计）
/// 2. 按 rule 推算 next_at 并更新 reminders
/// 3. 返回下一次触发时间，供本地通知重新调度
library;

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../models.dart';

/// 完成一次提醒后的结果。
class ReminderTickResult {
  const ReminderTickResult({
    required this.reminder,
    required this.completedAt,
    required this.nextAt,
  });

  final Reminder reminder;
  final DateTime completedAt;

  /// 下一次触发时间。为 null 表示这是一次性提醒，已完成终结。
  final DateTime? nextAt;
}

class ReminderRepository {
  ReminderRepository([Database? db]) : _injected = db;

  final Database? _injected;

  static const _uuid = Uuid();
  static const String _table = 'reminders';
  static const String _logs = 'reminder_logs';

  Database get _db => _injected ?? AppDatabase.instance.db;

  Future<List<Reminder>> listForPet(
    String petId, {
    bool onlyEnabled = false,
  }) async {
    final where = <String>['pet_id = ?', 'deleted_at IS NULL'];
    if (onlyEnabled) where.add('enabled = 1');

    final rows = await _db.query(
      _table,
      where: where.join(' AND '),
      whereArgs: [petId],
      orderBy: 'next_at ASC',
    );
    return rows.map(Reminder.fromMap).toList();
  }

  /// 全量即将到期，跨宠物。今日页用。
  Future<List<Reminder>> upcoming({
    required DateTime from,
    required DateTime to,
    bool onlyEnabled = true,
  }) async {
    final where = <String>['deleted_at IS NULL', 'next_at >= ?', 'next_at <= ?'];
    if (onlyEnabled) where.add('enabled = 1');

    final rows = await _db.query(
      _table,
      where: where.join(' AND '),
      whereArgs: [from.millisecondsSinceEpoch, to.millisecondsSinceEpoch],
      orderBy: 'next_at ASC',
    );
    return rows.map(Reminder.fromMap).toList();
  }

  Future<Reminder?> findById(String id) async {
    final rows = await _db.query(_table, where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Reminder.fromMap(rows.first);
  }

  Future<Reminder> create(Reminder reminder) async {
    await _db.insert(_table, reminder.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort);
    return reminder;
  }

  /// 便捷新建周期提醒。
  Future<Reminder> createInterval({
    required String petId,
    required String type,
    required String title,
    required int everyDays,
    required DateTime firstAt,
    String source = 'manual',
  }) {
    final now = DateTime.now();
    return create(Reminder(
      id: _uuid.v4(),
      petId: petId,
      type: type,
      title: title,
      rule: {'mode': 'interval', 'days': everyDays},
      nextAt: firstAt,
      source: source,
      createdAt: now,
      updatedAt: now,
    ));
  }

  /// 完成一次。
  ///
  /// [recordId] 可关联到实际记录（比如完成「驱虫」时顺手写了条 deworm 记录）。
  /// 返回下一次触发时间，调用方据此重新调度本地通知。
  Future<ReminderTickResult> completeOnce(
    String reminderId, {
    DateTime? at,
    String? recordId,
  }) async {
    final now = at ?? DateTime.now();
    final reminder = await findById(reminderId);
    if (reminder == null) {
      throw StateError('reminder $reminderId 不存在');
    }

    // 1. 留档。due_at 用本次的 nextAt（不是 now），这样完成率统计才对得上。
    await _db.insert(
      _logs,
      {
        'id': _uuid.v4(),
        'reminder_id': reminder.id,
        'due_at': reminder.nextAt.millisecondsSinceEpoch,
        'done_at': now.millisecondsSinceEpoch,
        'record_id': recordId,
        'action': 'done',
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    // 2. 排下一次。
    final next = reminder.nextOccurrence();
    if (next != null) {
      await _db.update(
        _table,
        {
          'next_at': next.millisecondsSinceEpoch,
          'updated_at': now.millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [reminderId],
      );
    } else {
      // 一次性提醒，完成后停用而不是删除。
      await _db.update(
        _table,
        {
          'enabled': 0,
          'updated_at': now.millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [reminderId],
      );
    }

    return ReminderTickResult(
      reminder: reminder,
      completedAt: now,
      nextAt: next,
    );
  }

  /// 延后：不写完成日志，只把 next_at 往后推。
  Future<DateTime?> snooze(String reminderId, Duration by, {DateTime? at}) async {
    final now = at ?? DateTime.now();
    final reminder = await findById(reminderId);
    if (reminder == null) return null;

    final next = reminder.nextAt.add(by);
    await _db.update(
      _table,
      {
        'next_at': next.millisecondsSinceEpoch,
        'updated_at': now.millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [reminderId],
    );
    return next;
  }

  Future<int> setEnabled(String reminderId, bool enabled) async {
    return _db.update(
      _table,
      {
        'enabled': enabled ? 1 : 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [reminderId],
    );
  }

  Future<int> softDelete(String reminderId, {DateTime? at}) async {
    final now = at ?? DateTime.now();
    return _db.update(
      _table,
      {
        'deleted_at': now.millisecondsSinceEpoch,
        'updated_at': now.millisecondsSinceEpoch,
      },
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [reminderId],
    );
  }

  /// 完成率 = 已完成的到期项 / 全部到期项。这是 MVP 的生死线指标之一。
  Future<double> completionRate({DateTime? since}) async {
    final where = <String>[];
    final args = <Object?>[];
    if (since != null) {
      where.add('due_at >= ?');
      args.add(since.millisecondsSinceEpoch);
    }

    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS total,'
      ' SUM(CASE WHEN done_at IS NOT NULL THEN 1 ELSE 0 END) AS done'
      ' FROM $_logs'
      '${where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}'}',
      args,
    );
    final total = (rows.first['total'] as num?)?.toInt() ?? 0;
    if (total == 0) return 0;
    final done = (rows.first['done'] as num?)?.toInt() ?? 0;
    return done / total;
  }
}
