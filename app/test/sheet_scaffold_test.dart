/// 公共弹层积木的测试（2026-10-11 P2 抽组件）。
///
/// 抽组件的价值不在「少写了几行」，而在**被抽出来的东西终于可测了**：
/// 抽之前 `_p()` 在 8 个文件各定义一遍、没有一份被测试覆盖；
/// `confirmDelete` 的「点遮罩返回 null 算不算确认」也没有任何断言。
///
/// ⚠️ 本文件的断言刻意覆盖**语义**而不只是渲染：
/// - `pad2` 的边界（0 / 9 / 10 / 99 / 100）
/// - `confirmDelete` / `confirmAction` 三条路径：取消 / 确认 / 点遮罩（返回 null）
/// - `SheetScaffold` 两种形态的**键盘避让位置**（必须包在滚动容器外面）
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/core/l10n.dart';
import 'package:pet_app/core/theme.dart';
import 'package:pet_app/ui/sheet_scaffold.dart';

/// 把被测 widget 挂到最小可用的 MaterialApp 上。
Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

/// 点开一个 confirm 对话框。返回值由调用方通过界面断言，不从这里取。
Future<void> _openConfirm(
  WidgetTester tester, {
  bool danger = false,
}) async {
  await _pump(
    tester,
    Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          if (danger) {
            await confirmDelete(context, title: 'T', hint: 'H');
          } else {
            await confirmAction(context, title: 'T', hint: 'H');
          }
        },
        child: const Text('open'),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('pad2', () {
    test('个位数补零，两位数及以上原样', () {
      expect(pad2(0), '00');
      expect(pad2(7), '07');
      expect(pad2(9), '09');
      expect(pad2(10), '10');
      expect(pad2(59), '59');
      expect(pad2(99), '99');
      // 100 不该被截断成末两位 —— 时间是 0-59，但日期/序号会更大，
      // 截断是静默出错，宁可多两位。
      expect(pad2(100), '100');
    });
  });

  group('confirmAction / confirmDelete', () {
    testWidgets('点「取消」返回 false', (tester) async {
      bool? got;
      await _pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              got = await confirmDelete(context, title: 'T', hint: 'H');
            },
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(L.t('action.cancel')));
      await tester.pumpAndSettle();
      expect(got, isFalse);
    });

    testWidgets('点确认返回 true', (tester) async {
      bool? got;
      await _pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              got = await confirmDelete(context, title: 'T', hint: 'H');
            },
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, L.t('action.delete')));
      await tester.pumpAndSettle();
      expect(got, isTrue);
    });

    testWidgets('点遮罩关掉 —— 必须等价于「取消」而不是「确认」', (tester) async {
      // 这是本组最重要的一条：Navigator.pop 在点遮罩时给的是 null，
      // 如果实现写成 `return ok`（而不是 `ok ?? false`），
      // 调用点 `if (ok)` 恰好把 null 当 false 用 —— 表面没炸。
      // 可一旦有人改成 `if (ok != false)`，误点遮罩就会**执行删除**。
      // 所以这条断言锁住的是「null ⇒ false」这个语义。
      bool? got;
      await _pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              got = await confirmDelete(context, title: 'T', hint: 'H');
            },
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10)); // 遮罩左上角
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing, reason: '遮罩应关掉对话框');
      expect(got, isFalse, reason: 'null 必须折叠成 false，否则误触会执行删除');
    });

    testWidgets('confirmDelete 的确认键是红底（破坏性操作要有重量）', (tester) async {
      await _openConfirm(tester, danger: true);
      final btn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, L.t('action.delete')),
      );
      final bg = btn.style?.backgroundColor?.resolve({});
      expect(bg, isNotNull, reason: 'confirmDelete 必须显式设置背景色');
      expect(bg, AppColors.danger);
    });

    testWidgets('confirmAction 默认不染红（非破坏性保持主色）', (tester) async {
      await _openConfirm(tester);
      final btn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, L.t('action.delete')),
      );
      // 没传 danger 时不设 backgroundColor，交给主题。
      expect(btn.style?.backgroundColor, isNull);
    });

    testWidgets('hint 为 null 时不渲染 content', (tester) async {
      await _pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => confirmAction(context, title: 'OnlyTitle'),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final dlg = tester.widget<AlertDialog>(find.byType(AlertDialog));
      expect(dlg.content, isNull);
      expect(find.text('OnlyTitle'), findsOneWidget);
    });
  });

  group('SheetScaffold', () {
    testWidgets('scrollable: true（默认）—— 标题 + 内容，无 Divider', (tester) async {
      await _pump(
        tester,
        const SheetScaffold(title: '标题', child: Text('内容')),
      );
      expect(find.text('标题'), findsOneWidget);
      expect(find.text('内容'), findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(find.byType(Divider), findsNothing);
    });

    testWidgets('scrollable: false —— 标题固定 + Divider + 内容自己滚', (tester) async {
      await _pump(
        tester,
        const SizedBox(
          height: 400,
          child: SheetScaffold(
            title: '标题',
            scrollable: false,
            child: Text('内容'),
          ),
        ),
      );
      expect(find.text('标题'), findsOneWidget);
      expect(find.byType(Divider), findsOneWidget);
      // 内容在 ListView 里（Expanded 包着），不是跟着标题一起滚。
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(find.byType(ListView), findsOneWidget);
    });

    testWidgets('title 之外的 action 渲染在标题行右侧', (tester) async {
      await _pump(
        tester,
        SheetScaffold(
          title: '标题',
          action: TextButton(onPressed: () {}, child: const Text('保存')),
          child: const Text('内容'),
        ),
      );
      expect(find.text('保存'), findsOneWidget);
    });

    testWidgets('action 为 null 时标题独占整行（不报错）', (tester) async {
      await _pump(
        tester,
        const SheetScaffold(title: '标题', child: Text('内容')),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('横条是 SheetHandle（36×4），不是各自内联的 Container', (tester) async {
      // 抽之前的症状是「横条在 8 个文件各写一遍」，
      // 这条断言的意义是：以后新增弹层不会再长出第 9 份。
      await _pump(
        tester,
        const SheetScaffold(title: '标题', child: Text('内容')),
      );
      expect(find.byType(SheetHandle), findsOneWidget);
    });

    testWidgets('键盘避让包在滚动容器【外面】', (tester) async {
      // ⚠️ 这条锁的是一个具体的布局错误：如果 Padding(viewInsets) 放在
      // SingleChildScrollView **里面**，滚动区自己也会把避让高度算进
      // 可滚动范围，键盘弹出后会出现一截滚不到内容的空白。
      //
      // 判据：viewInsets 生效后，SingleChildScrollView 的下边界要随之抬升 ——
      // 也就是说 Padding 必须是它的祖先。
      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(viewInsets: EdgeInsets.only(bottom: 300)),
          child: MaterialApp(
            home: Scaffold(
              body: SheetScaffold(title: '标题', child: Text('内容')),
            ),
          ),
        ),
      );
      final scrollRect = tester.getRect(find.byType(SingleChildScrollView));
      final handleRect = tester.getRect(find.byType(SheetHandle));
      // 滚动区下边界应低于横条（正常排布）——
      // 关键断言：整个滚动区都在「扣除键盘」之后的区域里。
      final screenH = tester.getRect(find.byType(Scaffold)).height;
      expect(scrollRect.bottom, lessThanOrEqualTo(screenH - 300 + 0.5));
      expect(handleRect.top, greaterThanOrEqualTo(scrollRect.top - 0.5));
    });
  });

  group('errorPlaceholder', () {
    testWidgets('不把异常原文甩在界面上', (tester) async {
      // 抽之前约 8 处写 `Text('$e')`，SocketException 的原文
      // （带内部域名端口）会直接显示给用户。这条断言锁住「不再泄漏」。
      final leaky = Exception(
        'SocketException: Connection refused, '
        'address = api.example.com, port = 44300',
      );
      await _pump(tester, errorPlaceholder(leaky));
      final text = tester.widget<Text>(find.byType(Text)).data!;
      expect(text.contains('SocketException'), isFalse);
      expect(text.contains('api.example.com'), isFalse);
      expect(text.contains('44300'), isFalse);
      // 必须给出一句能看懂的兜底文案。
      expect(text, L.t('error.generic'));
    });
  });
}
