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
import '../../domain/medication_course.dart';

/// 完成一次提醒后的结果。
class ReminderTickResult {
  const ReminderTickResult({
    required this.reminder,
    required this.completedAt,
    required this.nextAt,
    this.alreadyCompleted = false,
  });

  final Reminder reminder;
  final DateTime completedAt;

  /// 下一次触发时间。为 null 表示这是一次性提醒，已完成终结。
  final DateTime? nextAt;
  final bool alreadyCompleted;
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
    final where = <String>[
      'deleted_at IS NULL', 'next_at >= ?', 'next_at <= ?',
      'pet_id IN (SELECT id FROM pets WHERE deleted_at IS NULL AND archived_at IS NULL)',
    ];
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

  /// 整体覆写一条提醒（编辑用）。id 与 pet_id 不动 —— 改归属不是编辑，
  /// 那是新建 + 删除。
  Future<int> update(Reminder reminder) async {
    final next = reminder.toMap()
      ..['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    return _db.update(
      _table,
      next,
      where: 'id = ?',
      whereArgs: [reminder.id],
    );
  }

  /// 完成一次。
  ///
  /// [recordId] 可关联到实际记录（比如完成「驱虫」时顺手写了条 deworm 记录）。
  /// 返回下一次触发时间，调用方据此重新调度本地通知。
  Future<ReminderTickResult> completeOnce(
    String reminderId, {
    DateTime? at,
    String? recordId,
    String? createdBy,
    String? actorName,
    DateTime? expectedDueAt,
  }) async {
    final now = at ?? DateTime.now();
    return _db.transaction((txn) async {
      final rows = await txn.query(_table, where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [reminderId], limit: 1);
      if (rows.isEmpty) throw StateError('care.error.changed');
      final reminder = Reminder.fromMap(rows.single);
      final due = DateTime.fromMillisecondsSinceEpoch(
          (expectedDueAt ?? reminder.nextAt).millisecondsSinceEpoch);
      final logId = 'log_${reminder.id}_${due.millisecondsSinceEpoch}';
      final existing = await txn.query(_logs, where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [logId]);
      if (existing.isNotEmpty) {
        return ReminderTickResult(reminder: reminder,
            completedAt: DateTime.fromMillisecondsSinceEpoch(existing.single['done_at'] as int),
            nextAt: reminder.enabled ? reminder.nextAt : null, alreadyCompleted: true);
      }
      if (!reminder.enabled || due != reminder.nextAt) {
        throw StateError('care.error.changed');
      }
      final pets = await txn.query('pets', where: 'id = ? AND deleted_at IS NULL AND archived_at IS NULL',
          whereArgs: [reminder.petId]);
      if (pets.isEmpty) throw StateError('care.error.changed');
      final course = MedicationCourse.fromReminder(reminder);
      if (reminder.rule['mode'] == 'medication' && course == null) {
        throw StateError('med.error.schedule');
      }
      final next = course == null ? reminder.nextOccurrence() :
          course.nextAt(now.isAfter(due) ? now : due, inclusive: false);
      final timestamp = now.millisecondsSinceEpoch > reminder.updatedAt.millisecondsSinceEpoch
          ? now.millisecondsSinceEpoch : reminder.updatedAt.millisecondsSinceEpoch + 1;
      final doseRecordId = course == null ? recordId :
          'dose_${reminder.id}_${due.millisecondsSinceEpoch}';
      if (course != null) {
        await txn.insert('records', PetRecord(
          id: doseRecordId!, petId: reminder.petId, type: RecordType.medication,
          recordedAt: now, valueText: course.name,
          payload: {'dose': course.dose, 'route': course.route,
            'course_id': reminder.id, 'due_at': due.millisecondsSinceEpoch,
            if (actorName != null) 'actor_name': actorName},
          createdBy: createdBy ?? 'local-user', createdAt: now,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(timestamp),
        ).toMap());
      }
      await txn.insert(_logs, {
        'id': logId, 'pet_id': reminder.petId, 'reminder_id': reminder.id,
        'due_at': due.millisecondsSinceEpoch, 'done_at': now.millisecondsSinceEpoch,
        'record_id': doseRecordId, 'action': 'done', 'created_by': createdBy,
        'actor_name': actorName, 'created_at': now.millisecondsSinceEpoch,
        'updated_at': timestamp, 'stock_used': course?.unitsPerDose ?? 0,
      });
      await txn.update(_table, {
        if (next != null) 'next_at': next.millisecondsSinceEpoch,
        if (next == null) 'enabled': 0,
        'updated_at': timestamp,
      }, where: 'id = ?', whereArgs: [reminderId]);
      return ReminderTickResult(reminder: reminder, completedAt: now, nextAt: next);
    });
  }

  Future<List<Map<String, Object?>>> logsForPet(String petId) => _db.query(
      _logs, where: 'pet_id = ? AND deleted_at IS NULL', whereArgs: [petId],
      orderBy: 'done_at DESC');

  Future<Reminder> createCourse({required String petId,
      required MedicationCourse course, DateTime? now}) async {
    final rule = course.toRule();
    final stamp = now ?? DateTime.now();
    final first = course.nextAt(stamp);
    if (first == null) throw ArgumentError('med.error.expired');
    return create(Reminder(id: _uuid.v4(), petId: petId, type: 'medication',
        title: course.name.trim(), rule: rule, nextAt: first, source: 'medication_course',
        createdAt: stamp, updatedAt: stamp));
  }

  Future<Reminder> updateCourse(Reminder reminder, MedicationCourse course) async {
    final rule = course.toRule();
    return _db.transaction((txn) async {
      final current = await _courseForUpdate(txn, reminder);
      final next = await _nextUncompleted(txn, current.id, course, DateTime.now());
      if (next == null) throw ArgumentError('med.error.expired');
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final updated = current.copyWith(title: course.name.trim(), rule: rule, nextAt: next,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(
              stamp > current.updatedAt.millisecondsSinceEpoch ? stamp : current.updatedAt.millisecondsSinceEpoch + 1));
      await txn.update(_table, updated.toMap(), where: 'id = ?', whereArgs: [current.id]);
      return updated;
    });
  }

  Future<Reminder> toggleCourse(Reminder reminder, bool enabled) async {
    return _db.transaction((txn) async {
      final current = await _courseForUpdate(txn, reminder);
      final course = MedicationCourse.fromReminder(current);
      if (course == null) throw ArgumentError('med.error.schedule');
      final next = enabled ? await _nextUncompleted(txn, current.id, course, DateTime.now()) : current.nextAt;
      if (next == null) throw ArgumentError('med.error.expired');
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final updated = current.copyWith(enabled: enabled, nextAt: next,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(
              stamp > current.updatedAt.millisecondsSinceEpoch ? stamp : current.updatedAt.millisecondsSinceEpoch + 1));
      await txn.update(_table, updated.toMap(), where: 'id = ?', whereArgs: [current.id]);
      return updated;
    });
  }

  Future<Reminder> _courseForUpdate(DatabaseExecutor txn, Reminder reminder) async {
    final rows = await txn.query(_table, where: 'id = ? AND deleted_at IS NULL', whereArgs: [reminder.id]);
    if (rows.isEmpty || rows.single['rule'] != reminder.toMap()['rule']) {
      throw StateError('care.error.changed');
    }
    return Reminder.fromMap(rows.single);
  }

  Future<DateTime?> _nextUncompleted(DatabaseExecutor txn, String id,
      MedicationCourse course, DateTime at) async {
    var next = course.nextAt(at);
    final logs = await txn.query(_logs, columns: ['due_at'],
        where: 'reminder_id = ? AND deleted_at IS NULL', whereArgs: [id]);
    final completed = logs.map((r) => r['due_at']).toSet();
    while (next != null && completed.contains(next.millisecondsSinceEpoch)) {
      next = course.nextAt(next, inclusive: false);
    }
    return next;
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
  ///
  /// ⚠️ **必须排除软删日志**（2026-10-10 代码审查 P1 修）。
  ///
  /// 原先这条查询没有任何 `deleted_at` 条件，而同一个文件里其他所有日志
  /// 查询（`logsForPet`、`_nextUncompleted`、`tick` 的去重）**都带**
  /// `deleted_at IS NULL`。口径不一致的后果很具体：
  ///
  /// - 用户把一条给药记录删掉（`record_repository.softDelete` 只改 records，
  ///   日志行原样留着）⇒ 完成率分子分母**都不减**，界面显示「8/10 已完成」，
  ///   但时间线上那条记录已经没了。
  /// - 更糟的是 `_nextUncompleted` 认 `deleted_at`，于是**同一个到期时刻**
  ///   在一处算「已完成」、在另一处算「未完成」—— 排期会被跳过，但统计说
  ///   已经做过了，两个功能互相打架。
  ///
  /// 两条查询口径统一到 `deleted_at IS NULL` 之后，删记录 = 撤销完成，
  /// 完成率会如实回落。
  Future<double> completionRate({DateTime? since}) async {
    // 软删条件放在 WHERE 里而不是拼进 SELECT：参数顺序要跟占位符一一对应，
    // 分开写容易错位（`since` 那条是带参数的）。
    final where = <String>['deleted_at IS NULL'];
    final args = <Object?>[];
    if (since != null) {
      where.add('due_at >= ?');
      args.add(since.millisecondsSinceEpoch);
    }

    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS total,'
      ' SUM(CASE WHEN done_at IS NOT NULL THEN 1 ELSE 0 END) AS done'
      ' FROM $_logs'
      ' WHERE ${where.join(' AND ')}',
      args,
    );
    final total = (rows.first['total'] as num?)?.toInt() ?? 0;
    if (total == 0) return 0;
    final done = (rows.first['done'] as num?)?.toInt() ?? 0;
    return done / total;
  }
}
