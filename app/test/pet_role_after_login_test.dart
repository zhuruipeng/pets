/// 登录前后「谁是这只宠物的主人」必须一致。
///
/// ## 这个测试的来历（以及一次误判）
///
/// 用户报「苹果端看不到删除宠物」，我怀疑是登录导致的：
/// 登录时 `adoptAccount` 会把本地用户行的 id 从 `local-user` 改成
/// 服务端 accountId，如果宠物的 `created_by` 没跟着迁移，
/// `roleFor()` 的 `created_by == userId` 就不成立 → 返回 null →
/// `DeletePetButton` 整个消失。
///
/// **这个判断是错的。** `adoptAccount` 其实已经迁移了四张表的 created_by。
/// 用户的真实原因是**装了旧包**：`+11` 的二进制里 `DeletePetButton`
/// 存在但 `_dangerZone`（挂载点）为 0 —— 组件从没被任何页面引用。
/// 这个可以用解包对比验证，比推理可靠：
///
///   | 版本 | _dangerZone | DeletePetButton |
///   | --- | --- | --- |
///   | +10 | 0 | 0 |
///   | +11 | **0** | 2 |  ← 组件在，没挂载
///   | +12 | 1 | 2 |
///
/// 那为什么还留着这组测试？因为这条路径**本来就该有覆盖**：
/// `family_care_test.dart` 测了组件本身，但那里 users.id 与 created_by
/// 都是同一个值，**从没模拟过「登录把 id 换掉」这一步**。
/// 状态的变化本身才是最容易出问题的地方。
///
/// 教训：**先验证再下结论。** 我当时凭代码推理就宣布「找到真凶」，
/// 而真正的验证（解包对比新旧包）只要两分钟，而且会直接推翻那个结论。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/data/repositories/member_repository.dart';
import 'package:pet_app/data/repositories/pet_repository.dart';
import 'package:pet_app/data/repositories/user_repository.dart';
import 'package:pet_app/data/db/schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late PetRepository pets;
  late MemberRepository members;
  late UserRepository users;

  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: kSchemaVersion,
        onCreate: (db, _) async {
          for (final sql in onCreate) {
            await db.execute(sql);
          }
        },
      ),
    );
    pets = PetRepository(db);
    members = MemberRepository(db);
    users = UserRepository(db);

    // 本地用户行，id 是固定的 localUserId —— 与真机首次启动一致。
    await db.insert('users', {
      'id': UserRepository.localUserId,
      'nickname': '铲屎官',
      'region': 'intl',
      'created_at': 1,
      'updated_at': 1,
    });
  });

  tearDown(() async => db.close());

  test('登录前：本地建的宠物属于自己', () async {
    final pet = await pets.createSimple(
      name: '旺财',
      speciesWire: 'dog',
      createdBy: UserRepository.localUserId,
    );
    expect(
      await members.roleFor(pet.id, UserRepository.localUserId),
      MemberRole.owner,
    );
  });

  test('**登录后：登录前建的宠物仍然是自己的**（这条曾经挂掉）', () async {
    final pet = await pets.createSimple(
      name: '旺财',
      speciesWire: 'dog',
      createdBy: UserRepository.localUserId,
    );

    // 模拟登录：本地用户行的 id 被改写成服务端 accountId。
    // 这一步就是 bug 的触发点 —— 不去模拟它，就复现不了。
    const accountId = 'srv_9f8e7d6c';
    await users.adoptAccount(accountId: accountId, region: 'intl');

    // 确认前提真的成立了：本地那行的 id 确实换了。
    // 如果哪天 adoptAccount 改成不动 id，这条断言会失败，
    // 提醒我们这里的假设变了。
    final row = await db.query('users', limit: 1);
    expect(row.single['id'], accountId,
        reason: '前提：登录会把本地用户 id 改成 accountId');

    // 关键断言：换了 id 之后，登录前建的宠物仍然认自己为主人。
    expect(
      await members.roleFor(pet.id, accountId),
      MemberRole.owner,
      reason: '登录不该让用户失去自己宠物的所有权',
    );
  });

  test('登录后建的宠物也属于自己', () async {
    const accountId = 'srv_9f8e7d6c';
    await users.adoptAccount(accountId: accountId, region: 'intl');
    final pet = await pets.createSimple(
      name: '小黑',
      speciesWire: 'cat',
      createdBy: accountId,
    );
    expect(await members.roleFor(pet.id, accountId), MemberRole.owner);
  });

  test('别人的宠物不会被误判成自己的', () async {
    // 放宽判定不能放宽到「谁都算主人」——
    // 共养场景下这会变成「谁都能删别人的宠物」。
    final pet = await pets.createSimple(
      name: '别人的猫',
      speciesWire: 'cat',
      createdBy: 'stranger_user_id',
    );
    expect(
      await members.roleFor(pet.id, 'srv_9f8e7d6c'),
      isNull,
      reason: 'created_by 既不是自己也不是 localUserId，就不该是主人',
    );
  });

  test('已归档的宠物返回 null（不给操作入口）', () async {
    final pet = await pets.createSimple(
      name: '旺财',
      speciesWire: 'dog',
      createdBy: UserRepository.localUserId,
    );
    await pets.archive(pet.id);
    expect(
      await members.roleFor(pet.id, UserRepository.localUserId),
      isNull,
    );
  });
}
