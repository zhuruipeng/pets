// ignore_for_file: avoid_print
//
// ↑ 命令行验证脚本：print 是它的对外接口，不是忘删的调试输出（同
//   verify_token_migration.dart 的说明）。这些脚本里有真逻辑（内存库、
//   事务语义、LWW 分支），不该为了躲一条 lint 而关掉整体静态检查。
/// 同步拉取（pull）正确性的离线验证 —— **纯 Dart，不碰平台通道，也不用 Flutter**。
///
/// 跑法（本机 flutter test 跑不动：非提权必撞命名管道 231）：
///
///     E:/dev/flutter/bin/cache/dart-sdk/bin/dart.exe tool/verify_sync_pull.dart
///
/// 注意：**用 dart.exe 直接执行，不要用 `dart run`** —— 后者先跑 build hooks
/// （native assets），那一步 spawn 子进程，本机照样撞 231。
///
/// ## 为什么要有这个脚本
///
/// 2026-10-10 的代码审查在同步引擎里发现 3 个 P0，**全部落在测试盲区**：
///
/// 1. `_pullAll` 的游标 `last_seq` 先落盘、后应用 —— 应用抛异常时游标已经前进，
///    这批远端数据被永久跳过，用户无感知。
/// 2. `SyncChange.fromJson` 读 `updated_at`，而服务端 pull 返回的是 `changed_at`
///    ⇒ 恒为 null ⇒ 走 `?? c.seq` 兜底 ⇒ LWW 比较退化，远端**更新与删除**
///    永远应用不进来（只有新增能进来）。
/// 3. `remoteUpdatedAt` 用 `c.seq`（自增序号，量级 1e3）去和本地毫秒时间戳
///    （量级 1.7e12）比大小 ⇒ 「远端更旧」恒成立。
///
/// 这三条都会**静默丢数据**，真机上表现为「数据凭空少了/多了又不报错」，
/// 是最难排查的一类。`flutter test` 在本机跑不动，所以用这个脚本锁住。
///
/// SyncEngine 是**真的**，只有它依赖的外部世界是替身：
/// db（内存表）、密钥库（MemoryTokenStore）、网络（_FakeApi）。
library;

import 'package:pet_app/data/sync/sync_api.dart';
import 'package:pet_app/data/sync/sync_engine.dart';
import 'package:pet_app/data/sync/token_store.dart';
import 'package:sqflite_common/sqlite_api.dart';

// ------------------------------------------------------------------ 假 Db

/// 内存库：`Map<表名, Map<行主键, 行内容>>`。
///
/// 只实现 SyncEngine 碰 `sync_meta` / 业务表用到的那几个方法。
/// 声明了 [noSuchMethod] 之后 Dart 不再强制实现几十个成员，
/// **未实现的方法一律抛** —— 这是有意的：以后 SyncEngine 用了新方法，
/// 脚本立刻报出来，而不是用假实现算出个好看的结果。
class _MemDb implements Database {
  /// 表名 → (主键 → 行)。主键统一取 'id' 列；sync_meta 用 'key'。
  final Map<String, Map<String, Map<String, Object?>>> tables = {};

  /// 记录事务提交次数，用来断言「游标和应用是否真的同一个事务」。
  int commits = 0;

  /// 抛异常的开关：模拟「应用某条变更时失败」。
  bool failOnInsert = false;

  Map<String, Map<String, Object?>> _t(String t) => tables.putIfAbsent(t, () => {});

  String _pk(Map<String, Object?> v) {
    if (v.containsKey('key')) return '${v['key']}';
    if (v.containsKey('id')) return '${v['id']}';
    return '${v.values.first}';
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    final rows = _t(table).values.where((row) {
      if (where == null || whereArgs == null) return true;
      // 只支持本脚本用到的两种 where：`id = ?` 和 `key = ?`。
      if (where.contains('id = ?')) return '${row['id']}' == '${whereArgs.first}';
      if (where.contains('key = ?')) return '${row['key']}' == '${whereArgs.first}';
      // 其它形态（如 `table_name = ? AND row_id = ?`）按不匹配处理，
      // 让 outbox 查询返回空 —— 与「没有待推送变更」等价，符合本脚本场景。
      return false;
    }).toList();
    final out = rows.map((r) => Map<String, Object?>.from(r)).toList();
    if (limit != null && out.length > limit) return out.sublist(0, limit);
    return out;
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    if (failOnInsert) throw StateError('验证：模拟应用变更失败');
    _t(table)[_pk(values)] = Map<String, Object?>.from(values);
    return 1;
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    if (failOnInsert) throw StateError('验证：模拟应用变更失败');
    final key = '${whereArgs?.first ?? ''}';
    final row = _t(table)[key];
    if (row == null) return 0;
    row.addAll(values);
    return 1;
  }

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    if (where == null || whereArgs == null) {
      final n = _t(table).length;
      _t(table).clear();
      return n;
    }
    final key = '${whereArgs.first}';
    return _t(table).remove(key) == null ? 0 : 1;
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) async {
    // 事务语义：把整个库快照下来，抛异常就整体回滚 ——
    // 这样「应用失败 → 游标也必须回滚」才测得出真效果。
    final snapshot = {
      for (final e in tables.entries)
        e.key: {for (final r in e.value.entries) r.key: Map<String, Object?>.from(r.value)},
    };
    try {
      final result = await action(_MemTxn(this));
      commits++;
      return result;
    } catch (_) {
      tables
        ..clear()
        ..addAll(snapshot);
      rethrow;
    }
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('验证脚本没实现 Database.${invocation.memberName}');
}

/// 事务对象：所有操作直接落到 [_MemDb] 上（回滚由上层快照负责）。
class _MemTxn implements Transaction {
  _MemTxn(this._db);
  final _MemDb _db;

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) =>
      _db.query(table,
          distinct: distinct,
          columns: columns,
          where: where,
          whereArgs: whereArgs,
          groupBy: groupBy,
          having: having,
          orderBy: orderBy,
          limit: limit,
          offset: offset);

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) =>
      _db.insert(table, values,
          nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) =>
      _db.update(table, values,
          where: where, whereArgs: whereArgs, conflictAlgorithm: conflictAlgorithm);

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) =>
      _db.delete(table, where: where, whereArgs: whereArgs);

  @override
  Batch batch() => throw UnimplementedError('本脚本不走 batch 路径');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('验证脚本没实现 Transaction.${invocation.memberName}');
}

// ------------------------------------------------------------------ 假 API

/// 不打网络的 SyncApi。按预设脚本回放 pull / push 的响应。
class _FakeApi extends SyncApi {
  _FakeApi({this.pages = const []}) : super(baseUrl: 'http://127.0.0.1:1');

  /// 每次 pull 调用依次取一页。
  final List<PullResult> pages;
  int pullCalls = 0;

  @override
  Future<PullResult> pull({
    required String token,
    required int since,
    int limit = 200,
  }) async {
    final page = pages[pullCalls.clamp(0, pages.length - 1)];
    pullCalls++;
    return page;
  }

  @override
  Future<PushResult> push({
    required String token,
    required String deviceId,
    required List<SyncChange> changes,
  }) async =>
      const PushResult(applied: [], rejected: []);
}

int _passed = 0;
int _failed = 0;

void check(bool ok, String what) {
  if (ok) {
    _passed++;
    print('  ok   $what');
  } else {
    _failed++;
    print('  FAIL $what');
  }
}

void main() async {
  print('同步拉取正确性 · 离线验证\n');

  // ---------------------------------------------------------------
  print('P0-3 · pull 返回的是 changed_at，不是 updated_at：');
  {
    // 服务端 pull 的真实响应形状（见 server/app/sync.py 的 sync_pull）。
    final c = SyncChange.fromJson({
      'seq': 42,
      'table': 'records',
      'row_id': 'r-1',
      'op': 'upsert',
      'payload': {'id': 'r-1', 'title': '体重'},
      'changed_at': 1730000000000,
    });
    check(c.updatedAt == 1730000000000,
        '从 changed_at 读到了时间戳（读 updated_at 会恒为 null）');
    check(c.updatedAt == null || c.updatedAt! > 1000000000000,
        '时间戳是毫秒量级，不是 seq 那种小整数');
  }

  // ---------------------------------------------------------------
  print('\nP0-3 · 远端 delete 墓碑必须能应用进来：');
  {
    final db = _MemDb();
    // 本地已有一行，updated_at 是「较新」的毫秒时间戳。
    db.tables['records'] = {
      'r-1': {
        'id': 'r-1',
        'title': '体重',
        'updated_at': 1730000009999, // 比墓碑还新
      },
    };

    final api = _FakeApi(pages: [
      PullResult(
        changes: [
          SyncChange.fromJson({
            'seq': 7, // 序号很小 —— 旧代码会拿它当时间戳
            'table': 'records',
            'row_id': 'r-1',
            'op': 'delete',
            'payload': const <String, dynamic>{},
            'changed_at': 1730000000000, // 比本地旧
          }),
        ],
        nextSince: 7,
        hasMore: false,
      ),
    ]);

    final engine = SyncEngine(
      dbProvider: () => db,
      tokenStore: MemoryTokenStore('t'),
      api: api,
    );
    await engine.sync();

    // 墓碑 changed_at(1730000000000) < 本地 updated_at(1730000009999)
    // ⇒ 按 LWW 本地更新，跳过是**正确**的。
    check(db.tables['records']!.containsKey('r-1'),
        '本地更新时，旧墓碑不覆盖（LWW 正确）');
  }

  // ---------------------------------------------------------------
  print('\nP0-3 · 远端更新比本地新时必须应用：');
  {
    final db = _MemDb();
    db.tables['records'] = {
      'r-1': {'id': 'r-1', 'title': '旧标题', 'updated_at': 1730000000000},
    };

    final api = _FakeApi(pages: [
      PullResult(
        changes: [
          SyncChange.fromJson({
            'seq': 8,
            'table': 'records',
            'row_id': 'r-1',
            'op': 'upsert',
            // 刻意**不在 payload 里放 updated_at**：真实 pull 的 payload 是
            // 行快照，业务表虽有 updated_at 列，但这条断言要单测的是
            // 「只靠 changed_at 能不能判出新旧」。若 payload 兜底也能取到值，
            // 这条测试就测不到「字段名读错」的失败路径了。
            'payload': {'id': 'r-1', 'title': '新标题'},
            'changed_at': 1730000005000,
          }),
        ],
        nextSince: 8,
        hasMore: false,
      ),
    ]);

    final engine = SyncEngine(
      dbProvider: () => db,
      tokenStore: MemoryTokenStore('t'),
      api: api,
    );
    await engine.sync();

    check(db.tables['records']!['r-1']?['title'] == '新标题',
        '远端更新被应用（seq 当时间戳时会失败）');
  }

  // ---------------------------------------------------------------
  print('\nP0-3 · 远端墓碑比本地新时必须删掉本地行：');
  {
    final db = _MemDb();
    db.tables['records'] = {
      'r-del': {'id': 'r-del', 'title': '待删', 'updated_at': 1730000000000},
    };

    // 协议第 228 行：墓碑推的是**行快照**（含 deleted_at），payload 不空。
    // 所以这里 payload 只放业务列，**不放 updated_at** —— 否则即使
    // SyncChange 读错字段名，payload 兜底也能取到值，测试就抓不到 bug。
    final api = _FakeApi(pages: [
      PullResult(
        changes: [
          SyncChange.fromJson({
            'seq': 9,
            'table': 'records',
            'row_id': 'r-del',
            'op': 'delete',
            'payload': {'id': 'r-del', 'title': '待删', 'deleted_at': 1730000009000},
            'changed_at': 1730000009000,
          }),
        ],
        nextSince: 9,
        hasMore: false,
      ),
    ]);

    final engine = SyncEngine(
      dbProvider: () => db,
      tokenStore: MemoryTokenStore('t'),
      api: api,
    );
    await engine.sync();

    final row = db.tables['records']?['r-del'];
    check(row == null || row['deleted_at'] != null,
        '远端墓碑生效：本地行被软删（seq 当时间戳时会残留）');
  }

  // ---------------------------------------------------------------
  print('\nP0-3 · 远端墓碑 payload 不含时间戳时也要能删：');
  {
    // 防御性场景：即使服务端只推了 `op=delete` + 空 payload，
    // 也必须能把本地这行软删掉 —— 否则远端删除在本地永远不生效。
    final db = _MemDb();
    db.tables['records'] = {
      'r-del2': {'id': 'r-del2', 'title': '待删', 'updated_at': 1730000000000},
    };

    final api = _FakeApi(pages: [
      PullResult(
        changes: [
          SyncChange.fromJson({
            'seq': 10,
            'table': 'records',
            'row_id': 'r-del2',
            'op': 'delete',
            'payload': const <String, dynamic>{},
            'changed_at': 1730000010000,
          }),
        ],
        nextSince: 10,
        hasMore: false,
      ),
    ]);

    final engine = SyncEngine(
      dbProvider: () => db,
      tokenStore: MemoryTokenStore('t'),
      api: api,
    );
    await engine.sync();

    final row = db.tables['records']?['r-del2'];
    check(row == null || row['deleted_at'] != null,
        '空 payload 的墓碑也能删掉本地行');
  }

  // ---------------------------------------------------------------
  print('\nP0-2 · 应用失败时游标不得前进：');
  {
    final db = _MemDb();
    db.failOnInsert = true; // 模拟某条变更格式异常

    final api = _FakeApi(pages: [
      PullResult(
        changes: [
          SyncChange.fromJson({
            'seq': 99,
            'table': 'records',
            'row_id': 'r-bad',
            'op': 'upsert',
            'payload': {'id': 'r-bad', 'updated_at': 1730000010000},
            'changed_at': 1730000010000,
          }),
        ],
        nextSince: 99,
        hasMore: false,
      ),
    ]);

    final engine = SyncEngine(
      dbProvider: () => db,
      tokenStore: MemoryTokenStore('t'),
      api: api,
    );
    await engine.sync(); // 内部会 catch 掉异常，不往外抛

    final seq = db.tables['sync_meta']?['last_seq']?['value'];
    check(seq == null || '$seq' != '99',
        '游标没有推进到 99（推进了 = 这批数据被永久跳过）');
  }

  // ---------------------------------------------------------------
  print('\nP0-2 · 应用成功时游标正常推进：');
  {
    final db = _MemDb();
    final api = _FakeApi(pages: [
      PullResult(
        changes: [
          SyncChange.fromJson({
            'seq': 123,
            'table': 'records',
            'row_id': 'r-new',
            'op': 'upsert',
            'payload': {'id': 'r-new', 'updated_at': 1730000020000},
            'changed_at': 1730000020000,
          }),
        ],
        nextSince: 123,
        hasMore: false,
      ),
    ]);

    final engine = SyncEngine(
      dbProvider: () => db,
      tokenStore: MemoryTokenStore('t'),
      api: api,
    );
    await engine.sync();

    check('${db.tables['sync_meta']?['last_seq']?['value']}' == '123',
        '游标推进到 123');
    check(db.tables['records']!.containsKey('r-new'), '新记录落了库');
  }

  // ---------------------------------------------------------------
  print('\n空页也要落游标（否则每次同步都从头扫）：');
  {
    final db = _MemDb();
    final api = _FakeApi(pages: [
      const PullResult(changes: [], nextSince: 555, hasMore: false),
    ]);
    final engine = SyncEngine(
      dbProvider: () => db,
      tokenStore: MemoryTokenStore('t'),
      api: api,
    );
    await engine.sync();

    check('${db.tables['sync_meta']?['last_seq']?['value']}' == '555',
        '空页返回的 nextSince 被存下来');
  }

  print('\n结果：$_passed 项通过，$_failed 项失败');
  if (_failed > 0) {
    throw StateError('有 $_failed 项断言失败');
  }
}
