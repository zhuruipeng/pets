/// 「添加家庭成员」按钮点了之后会发生什么。
///
/// ## 为什么写这组测试
///
/// 用户报「点击邀请没有反应」。而代码里这条路径其实分**两跳**：
///
///   点「添加家庭成员」(`profile.addFamily`)
///     → 打开成员管理弹层 (`showMembersSheet`)
///     → 里面右上角才有「邀请成员」(`members.invite`)
///     → 点它才打开邀请表单
///
/// 而且第二跳的按钮**只在登录后显示**（`if (status.loggedIn)`）。
/// 未登录时弹层里只有一个登录引导 —— 用户看到「没有一个叫邀请的按钮」，
/// 很自然会说「点了没反应」。
///
/// 这里把两种情况都钉住，以后谁改动了这个条件，测试会直接说出来。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/core/l10n.dart';
import 'package:pet_app/data/db/schema.dart';
import 'package:pet_app/data/models.dart';
import 'package:pet_app/data/repositories/member_repository.dart';
import 'package:pet_app/data/repositories/pet_repository.dart';
import 'package:pet_app/data/repositories/user_repository.dart';
import 'package:pet_app/data/sync/sync_api.dart';
import 'package:pet_app/data/sync/sync_engine.dart';
import 'package:pet_app/providers.dart';
import 'package:pet_app/ui/members_sheet.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 假的同步状态。默认 `SyncStatus()` 就是未登录。
class _Sync extends SyncController {
  _Sync(this._status);
  final SyncStatus _status;

  @override
  SyncStatus build() => _status;
}

Future<Database> _openDb() async {
  sqfliteFfiInit();
  return databaseFactoryFfi.openDatabase(
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
}

void main() {
  late Database db;
  late Pet pet;
  late PetRepository pets;
  late MemberRepository members;
  late UserRepository users;

  setUp(() async {
    db = await _openDb();
    pets = PetRepository(db);
    members = MemberRepository(db);
    users = UserRepository(db);
    await db.insert('users', {
      'id': UserRepository.localUserId,
      'nickname': '铲屎官',
      'region': 'intl',
      'created_at': 1,
      'updated_at': 1,
    });
    pet = await pets.createSimple(
      name: '旺财',
      speciesWire: 'dog',
      createdBy: UserRepository.localUserId,
    );
  });

  tearDown(() async => db.close());

  ProviderContainer makeContainer({required bool loggedIn}) {
    return ProviderContainer(overrides: [
      petRepositoryProvider.overrideWithValue(pets),
      memberRepositoryProvider.overrideWithValue(members),
      userRepositoryProvider.overrideWithValue(users),
      dbReadyProvider.overrideWith((ref) async {}),
      syncControllerProvider.overrideWith(() => _Sync(
            loggedIn
                ? const SyncStatus(phase: SyncPhase.idle)
                : const SyncStatus(),
          )),
      // 未登录时真实现会去读 token，测试里没必要走那条路。
      petMembersRemoteProvider.overrideWith((ref, petId) async {
        return const <RemoteMember>[];
      }),
    ]);
  }

  testWidgets('点「添加家庭成员」会弹出成员管理弹层', (tester) async {
    final container = makeContainer(loggedIn: true);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMembersSheet(context, pet: pet),
              child: Text(L.t('profile.addFamily')),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text(L.t('profile.addFamily')));
    await tester.pumpAndSettle();

    // 弹层确实出来了 —— 「点了没反应」不成立
    expect(find.text(L.t('profile.section.family')), findsOneWidget);
  });

  testWidgets('已登录：弹层里有「邀请成员」按钮', (tester) async {
    final container = makeContainer(loggedIn: true);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMembersSheet(context, pet: pet),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text(L.t('members.invite')), findsOneWidget);
    expect(find.text(L.t('members.needLogin')), findsNothing);
  });

  testWidgets('**未登录：弹层里没有「邀请成员」，只有登录引导**', (tester) async {
    final container = makeContainer(loggedIn: false);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMembersSheet(context, pet: pet),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 这就是用户看到的现象：弹层开了，但**没有**那个叫「邀请」的按钮。
    // 用户很容易把这理解成「点了没反应」。
    expect(
      find.text(L.t('members.invite')),
      findsNothing,
      reason: '未登录时不该出现邀请按钮 —— 共养必须有账号',
    );
    expect(find.text(L.t('members.needLogin')), findsOneWidget);
    expect(find.text(L.t('auth.title')), findsOneWidget,
        reason: '必须给出登录入口，否则用户完全不知道下一步做什么');
  });
}
