/// 数据库打开与迁移框架。
///
/// 职责单一：把 schema.dart 里的 DDL 变成一条可用的连接。
/// 迁移策略：现在是 v1，后续每加一版就在 [_migrations] 里补一个分支，
/// 不允许直接改旧分支的语句（否则老用户升级会错位）。
library;

import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'schema.dart';

export 'schema.dart' show kSchemaVersion, onCreate, migrations;

class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();

  static const String _fileName = 'pet.db';

  Database? _db;
  Completer<Database>? _opening;

  /// 已打开的连接。未打开时抛出，提示调用 [open]。
  Database get db {
    final d = _db;
    if (d == null) {
      throw StateError('AppDatabase 尚未打开，请先 await AppDatabase.instance.open()');
    }
    return d;
  }

  bool get isOpen => _db != null;

  /// 打开（或复用）连接。并发调用只会真正打开一次。
  Future<Database> open({String? overridePath}) async {
    final existing = _db;
    if (existing != null) return existing;

    final pending = _opening;
    if (pending != null) return pending.future;

    final completer = Completer<Database>();
    _opening = completer;

    try {
      final db = await _openInternal(overridePath);
      _db = db;
      completer.complete(db);
      return db;
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      _opening = null;
    }
  }

  Future<Database> _openInternal(String? overridePath) async {
    final path = overridePath ?? await defaultPath();

    return openDatabase(
      path,
      version: kSchemaVersion,
      onConfigure: (db) async {
        // 外键约束默认关闭，必须显式打开，否则 members 之类的关联表会静默失序。
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        final batch = db.batch();
        for (final stmt in onCreate) {
          batch.execute(stmt);
        }
        await batch.commit(noResult: true);
      },      onUpgrade: (db, from, to) async {
        await _migrate(db, from, to);
      },
      onDowngrade: onDatabaseDowngradeDelete,
    );
  }

  /// 按版本逐级迁移：v(from+1) → v(to)，每级跑一次该版本的语句。
  Future<void> _migrate(Database db, int from, int to) async {
    for (var v = from + 1; v <= to; v++) {
      final stmts = migrations[v];
      if (stmts == null) continue;

      final batch = db.batch();
      for (final s in stmts) {
        batch.execute(s);
      }
      await batch.commit(noResult: true);
    }
  }

  /// 数据库文件路径。测试可用 [overridePath] 避开平台通道。
  Future<String> defaultPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, _fileName);
  }

  Future<void> close() async {
    final d = _db;
    _db = null;
    if (d != null) await d.close();
  }
}
