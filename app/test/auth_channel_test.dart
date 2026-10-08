/// 登录页的验证通道必须默认选中「真的能用」的那个。
///
/// ## 这个 bug 藏了很久
///
/// 海外区服务端的 `SMS_PROVIDER` 是空的（国际短信成本高、到达率不稳），
/// 只有邮箱通道真的能发。但登录页的通道列表写的是
/// `['sms', 'email']`，而 `_channel` 的默认值**写死 `'sms'`** ——
/// 于是用户一打开登录页，默认选中的就是那个必然失败的通道。
///
/// 真机表现（2026-10-08 截图确认）：
///
///     用户填手机号 → 点「发送验证码」
///     → Sign-in is temporarily unavailable.
///       The verification channel is not set up yet — please try again later.
///
/// 用户会以为「这个 App 登录坏了」，而不是「我选错了通道」。
///
/// ## 修法
///
/// 海外区只列 `['email']`，默认值改成 `_channels.first` ——
/// **给一个点了必然失败的选项，比不给更糟**。
/// 中国区本来就是 `['sms']`（走官网统一账号，那边只有手机号）。
///
/// 以后海外区若真的配上短信，把 'sms' 加回列表即可（服务端接口支持）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/core/l10n.dart';
import 'package:pet_app/core/region.dart';
import 'package:pet_app/data/sync/unified_api.dart';
import 'package:pet_app/ui/auth_sheet.dart';

void main() {
  test('测试环境按海外区跑（否则下面的断言没有意义）', () {
    // 如果哪天 CI 默认区域变成 cn，这些测试的前提就不同了，
    // 这条断言会提醒我们。
    expect(
      UnifiedAccountApi.isAvailable,
      isFalse,
      reason: '本组测试假设运行在海外区（intl）',
    );
    expect(AppRegion.current, Region.intl);
  });

  testWidgets('海外区登录页默认就是邮箱通道 —— 不需要用户自己去切', (tester) async {
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: Scaffold(body: _OpenAuthSheet())),
    ));
    await tester.pumpAndSettle();

    // 输入框的标签应该是「邮箱」。
    // 修之前这里是「手机号」—— 用户填完点发送就报通道未配置。
    expect(
      find.text(L.t('auth.target.email')),
      findsOneWidget,
      reason: '海外区默认必须是邮箱，否则一进来就踩「通道未配置」',
    );
    expect(
      find.text(L.t('auth.target.phone')),
      findsNothing,
      reason: '海外区不该出现手机号输入框',
    );
  });

  testWidgets('海外区不再显示手机号/邮箱切换条', (tester) async {
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: Scaffold(body: _OpenAuthSheet())),
    ));
    await tester.pumpAndSettle();

    // 只剩一个可用通道时不该显示切换 —— 给用户一个点了会失败的选项
    // 是在害他（详见文件头）。
    expect(
      find.byType(ChoiceChip),
      findsNothing,
      reason: '只有一个可用通道时不该有切换条',
    );
  });
}

/// 打开登录面板（`_AuthSheet` 是私有的，只能通过这个入口触发）。
class _OpenAuthSheet extends StatefulWidget {
  const _OpenAuthSheet();

  @override
  State<_OpenAuthSheet> createState() => _OpenAuthSheetState();
}

class _OpenAuthSheetState extends State<_OpenAuthSheet> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showAuthSheet(context);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
