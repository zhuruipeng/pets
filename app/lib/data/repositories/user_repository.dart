/// 本地用户仓储。
///
/// 本地只有「当前这个人」这一行 —— 不需要用户列表。
///
/// **登录状态不在这里判断**：是否已登录看的是有没有 token（见 SyncEngine），
/// 用户行只负责存资料与联系方式。这样退出登录时不用动这行，
/// 也就不会出现「改 id 改一半」这类难查的问题。未登录时这一行是
/// id = `kCurrentUserId` 的占位行（region 记为 'local'）。
library;

import 'package:sqflite/sqflite.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../sync/account_data.dart';

class UserRepository {
  UserRepository([Database? db]) : _injected = db;

  final Database? _injected;

  static const String _table = 'users';

  /// 未登录时的占位 id。登录成功后会被 [adoptAccount] 换成账号 id。
  static const String localUserId = 'local-user';

  Database get _db => _injected ?? AppDatabase.instance.db;

  /// Current account working set contains its own user row.
  Future<LocalUser?> current() async {
    final rows = await _db.query(_table, limit: 1);
    if (rows.isEmpty) return null;
    return LocalUser.fromMap(rows.first);
  }

  Future<LocalUser> create(LocalUser user) async {
    await _db.insert(_table, user.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort);
    return user;
  }

  Future<int> update(LocalUser user) async {
    final next = user.toMap()
      ..['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    return _db.update(_table, next, where: 'id = ?', whereArgs: [user.id]);
  }

  /// First login adopts guest data; later accounts restore their own working set.
  Future<void> adoptAccount({
    required String accountId,
    required String region,
    String? nickname,
    String? phone,
    String? email,
  }) =>
      _db.transaction((txn) => adoptAccountIn(txn,
          accountId: accountId,
          region: region,
          nickname: nickname,
          phone: phone,
          email: email));

  Future<void> adoptAccountIn(
    DatabaseExecutor txn, {
    required String accountId,
    required String region,
    String? nickname,
    String? phone,
    String? email,
  }) =>
      adoptAccountData(txn,
          accountId: accountId,
          region: region,
          nickname: nickname,
          phone: phone,
          email: email);
}
