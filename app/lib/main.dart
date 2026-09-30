/// 应用入口。
///
/// 启动顺序（有讲究，别改）：
/// 1. 打开数据库 —— 所有页面都依赖它
/// 2. 初始化通知（不请求权限）—— 只准备通道
/// 3. 建默认本地用户
/// 4. 渲染 UI
///
/// 通知权限**不在这里请求**。等用户添加了第一只宠物、看到生成的计划之后再要，
/// 授权率会高得多。见 ui/sheets.dart 的 _AddPetSheetState._submit。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/l10n.dart';
import 'core/theme.dart';
import 'data/db/app_database.dart';
import 'providers.dart';
import 'services/notification_service.dart';
import 'ui/me_screen.dart';
import 'ui/profile_screen.dart';
import 'ui/records_screen.dart';
import 'ui/reminder_sheet.dart';
import 'ui/today_screen.dart';
import 'ui/update_flow.dart';

/// 全局 Navigator key。目前只有一处用途：**通知点击后要从 App 外部
/// （原生回调）拿到一个能弹层的 context**。别拿它到处做导航。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// 首帧之前来的通知点击先暂存，等 UI 起来再弹。
String? _pendingReminderId;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 数据库先就位，避免首帧闪一下空态。
  await AppDatabase.instance.open();
  await NotificationService.instance.init();
  await _ensureLocalUser();

  // 点通知进 App → 直接弹这条提醒的操作卡（完成 / 明天再说）。
  //
  // onReminderTapped 是 NotificationService 上的**静态**字段，必须走类名赋值。
  // 写成 NotificationService.instance.onReminderTapped = ... 会被 analyzer 判
  // `instance_access_to_static_member`（在 Dart 里是 error，构建直接挂）。
  NotificationService.onReminderTapped = _openReminderFromNotification;

  // 冷启动：App 完全没运行时被通知拉起来，上面那个回调收不到这一次点击，
  // 必须主动查一次 —— 这是最容易漏的一条路径。
  final launchId = await NotificationService.instance.launchPayload();
  if (launchId != null) _pendingReminderId = launchId;

  runApp(const ProviderScope(child: PetApp()));
}

/// 通知点击的统一入口。context 还没准备好就先记下来，首帧后再弹。
void _openReminderFromNotification(String reminderId) {
  final ctx = appNavigatorKey.currentContext;
  if (ctx == null) {
    _pendingReminderId = reminderId;
    return;
  }
  showReminderDueSheet(ctx, reminderId: reminderId);
}

/// 建一个本地用户。M6 接入账号后由登录流程取代。
///
/// 为什么现在就要：members 表和 created_by 字段都指向用户，
/// 没有用户记录时共养功能的种子数据接不上。
Future<void> _ensureLocalUser() async {
  final db = AppDatabase.instance.db;
  final rows = await db.query('users', where: 'id = ?', whereArgs: [kCurrentUserId]);
  if (rows.isNotEmpty) return;

  final now = DateTime.now().millisecondsSinceEpoch;
  await db.insert('users', {
    'id': kCurrentUserId,
    'nickname': L.isZh ? '我' : 'Me',
    'region': 'local',
    'created_at': now,
    'updated_at': now,
  });
}

class PetApp extends StatelessWidget {
  const PetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: L.t('app.title'),
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      theme: buildAppTheme(),
      home: const HomeShell(),
    );
  }
}

/// 构建主题。所有取值来自 core/theme.dart，此处不写裸色值。
ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.seed,
    brightness: Brightness.light,
  ).copyWith(
    primary: AppColors.primary,
    surface: AppColors.surface,
    outlineVariant: AppColors.border,
  );

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.pageBg,
    splashFactory: InkSparkle.splashFactory,
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.pageBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      // 参考稿的底部栏没有胶囊底，靠图标与文字变色表示选中。
      height: 62,
      elevation: 0,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 11,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? AppColors.primary : AppColors.textTertiary,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 23,
          color: selected ? AppColors.primary : AppColors.textTertiary,
        );
      }),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.divider,
      thickness: 1,
      space: 1,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.chip),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.surface,
      selectedColor: AppColors.primaryLight,
      side: const BorderSide(color: AppColors.border),
      labelStyle: const TextStyle(fontSize: 12.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
      ),
      labelStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 13.5),
      floatingLabelStyle: const TextStyle(color: AppColors.primary, fontSize: 13),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
  );
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;
  Timer? _syncTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 定时同步：**只在真的有本地改动时才发请求**（先查一次 outbox 条数）。
    // 每分钟都打一次网络是纯浪费流量和电，而「有改动才同步」让
    // 常态下的开销只是一次本地 count 查询。
    _syncTimer = Timer.periodic(const Duration(seconds: 60), (_) => _syncIfDirty());
    // 启动后静默查一次更新。放在首帧之后，不占启动时间；
    // 检查失败或已是最新都**不打扰用户**（详见 ui/update_flow.dart）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      runUpdateCheck(context, interactive: false);

      // 冷启动时被通知点开：那时还没有 context，只能等首帧。
      final pending = _pendingReminderId;
      if (pending != null) {
        _pendingReminderId = null;
        showReminderDueSheet(context, reminderId: pending);
      }
    });
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 回到前台：**无条件同步一次**。
  ///
  /// 与定时器不同，这里不能只看 pending —— 应用在后台期间别的设备
  /// 可能改了数据，本地 pending 是 0 也需要拉下来。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final container = ProviderScope.containerOf(context, listen: false);
    container.read(syncControllerProvider.notifier).runSync();
  }

  Future<void> _syncIfDirty() async {
    if (!mounted) return;
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final pending = await container.read(syncEngineProvider).pendingCount();
      if (pending > 0) {
        await container.read(syncControllerProvider.notifier).runSync();
      }
    } catch (_) {
      // 后台同步失败不打扰用户：错误会显示在「我的」页的同步卡片里。
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: _index,
          children: const [
            TodayScreen(),
            RecordsScreen(),
            ProfileScreen(),
            MeScreen(),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: AppColors.divider)),
        ),
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.home_outlined),
              selectedIcon: const Icon(Icons.home_rounded),
              label: L.t('tab.home'),
            ),
            NavigationDestination(
              icon: const Icon(Icons.edit_note_outlined),
              selectedIcon: const Icon(Icons.edit_note),
              label: L.t('tab.records'),
            ),
            NavigationDestination(
              icon: const Icon(Icons.pets_outlined),
              selectedIcon: const Icon(Icons.pets),
              label: L.t('tab.profile'),
            ),
            NavigationDestination(
              icon: const Icon(Icons.person_outline),
              selectedIcon: const Icon(Icons.person),
              label: L.t('tab.me'),
            ),
          ],
        ),
      ),
    );
  }
}
