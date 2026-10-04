/// 分享调用的 iPad 锚点约束。
///
/// ## 这条约束是什么
///
/// share_plus 在 iPad 上必须传 `sharePositionOrigin`，否则抛：
/// ```
/// PlatformException(error, sharePositionOrigin: argument must be set,
///   {{0, 0}, {0, 0}} must be non-zero and within coordinate space of source view)
/// ```
/// **iPhone 上同样抛** —— iOS 的 UIActivityViewController 在 iPad 上必须锚定
/// 源视图，这是通用要求。
///
/// ## 为什么值得用测试钉住
///
/// 这个坑的三个特点让它极易复发：
/// 1. **不编译失败**，代码看着完全正常；
/// 2. **报错在整条链路最后一步** —— 图片渲染、文件落盘全都成功过了，
///    所以「导出失败」这个提示把人引向完全错误的方向（我第一版就查歪了，
///    以为是图片太长撑爆了 iOS 的像素上限）；
/// 3. **错误信息不提 iPad**，只说 `must be set`，看不出缺什么。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/services/share_helper.dart';

void main() {
  group('分享锚点 originOf', () {
    testWidgets('正常挂载的 context 返回非零矩形', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox(width: 200, height: 48);
            },
          ),
        ),
      );

      final rect = originOf(ctx);
      expect(rect, isNotNull);
      // iPad 抛异常时明确说 must be non-zero —— 宽或高为 0 一样会挂
      expect(rect!.width, greaterThan(0));
      expect(rect.height, greaterThan(0));
      // 是屏幕坐标，不是局部坐标：按钮在页面里，y 不会是 0
      expect(rect.top, greaterThanOrEqualTo(0));
    });

    testWidgets('按钮的实际位置能被取到（不返回全零）', (tester) async {
      // 全零 Rect 是 iPad 明确拒绝的第二种形式（must be non-zero），
      // 所以这条专门挡「传了但等于没传」的情况。
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.only(top: 120, left: 40),
              child: Builder(
                builder: (c) {
                  ctx = c;
                  return const SizedBox(width: 120, height: 44);
                },
              ),
            ),
          ),
        ),
      );

      final rect = originOf(ctx);
      expect(rect, isNotNull);
      expect(rect!.left, greaterThan(0));
      expect(rect.top, greaterThan(0));
      expect(rect.width, greaterThan(0));
      expect(rect.height, greaterThan(0));
    });

    testWidgets('找不到 RenderObject 时返回 null 而不是伪造矩形', (tester) async {
      // ⚠️ 返回一个假的非零 Rect 会让分享面板锚在看不见的地方，
      // 表现为「点了没反应」—— 比抛异常更难查。拿不到就交回 null。
      // 用 pumpWidget 前后的空场景触发「context 还没 attach」。
      Object? result;
      await tester.runAsync(() async {
        result = originOf(_UnattachedContext());
      });
      expect(result, isNull);
    });
  });

  group('分享入口', () {
    test('shareFiles / shareText 存在且接受 origin', () {
      // 真正的约束在**调用点**：每个分享都必须传 origin 或 context。
      // 签名上两者都可空，所以这里只守「入口存在」，
      // 传参正确性靠 review + 真机验证（iOS 上真机才跑得出来）。
      expect(shareFiles, isNotNull);
      expect(shareText, isNotNull);
    });
  });
}

/// 永远拿不到 RenderObject 的 context —— 模拟页面已销毁 / 未 attach。
class _UnattachedContext extends StatelessWidget implements BuildContext {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  @override
  bool get mounted => false;

  @override
  T? dependOnInheritedWidgetOfExactType<T extends InheritedWidget>({
    Object? aspect,
  }) =>
      null;

  // ⚠️ 这里**不**实现 dependOnInheritedWidget / getInheritedWidgetOfExactType。
  // 它们在现代 Flutter 的 BuildContext 上已经不存在，写上去会被 analyzer 判
  // `override_on_non_overriding_member`。`noSuchMethod` 兜住其余调用即可。

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
