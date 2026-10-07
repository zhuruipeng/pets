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

class UserRepository {
  UserRepository([Database? db]) : _injected = db;

  final Database? _injected;

  static const String _table = 'users';

  /// 未登录时的占位 id。登录成功后会被 [adoptAccount] 换成账号 id。
  static const String localUserId = 'local-user';

  Database get _db => _injected ?? AppDatabase.instance.db;

  /// 当前用户。表里最多一行，取第一行即可。
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

  /// 登录成功后把占位用户「过户」给真实账号。
  ///
  /// 为什么不是「新建一行账号用户、把老数据留给占位行」：那样本地已有的宠物
  /// 会永远挂在 `local-user` 名下（`created_by` 指向它），既同步不上去，
  /// 也判断不出归属。**过户 = 改 id + 把所有 created_by 一起改**，
  /// 本地数据原样收编进账号，然后由同步引擎整体推上去。
  ///
  /// 整件事必须在一个事务里：中途失败留下「一半数据属于旧 id」是最坏的结果。
  /// 这些 UPDATE 会触发 outbox 触发器 —— 正是想要的，过户后的全量数据
  /// 会在下一次同步里推上去。
  Future<void> adoptAccount({
    required String accountId,
    required String region,
    String? nickname,
    String? phone,
    String? email,
  }) async {
    if (accountId == localUserId) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      final existing =
          await txn.query(_table, where: 'id = ?', whereArgs: [accountId], limit: 1);
      if (existing.isEmpty) {
        final local = await txn
            .query(_table, where: 'id = ?', whereArgs: [localUserId], limit: 1);
        final localRow = local.isEmpty ? null : local.first;

        await txn.update(
          _table,
          {
            'id': accountId,
            'region': region,
            if (nickname != null && nickname.trim().isNotEmpty)
              'nickname': nickname,
            // 联系方式以本地为准：用户可能刚填完就登录了，
            // 服务端那份是更早的。
            'phone': localRow?['phone'] ?? phone,
            'email': localRow?['email'] ?? email,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [localUserId],
        );
      }

      // created_by 现在没有外键约束（schema 里没声明），可以直接改。
      // 将来若补上 FK，这段要改成先插新行再改引用。
      for (final table in ['pets', 'records', 'walk_sessions', 'reminder_logs']) {
        await txn.update(
          table,
          {'created_by': accountId},
          where: 'created_by = ?',
          whereArgs: [localUserId],
        );
      }
    });
  }
}
