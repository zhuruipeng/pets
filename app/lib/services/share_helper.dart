/// 唤起系统分享的**唯一入口**。
///
/// ## 为什么不直接调 share_plus
///
/// share_plus 在 **iPad 上必须传 `sharePositionOrigin`**，否则抛
/// `PlatformException: sharePositionOrigin: argument must be set`，
/// 而且**手机上也一样抛** —— iOS 的分享面板（UIActivityViewController）在
/// iPad 上必须锚定一个源视图，否则系统直接拒绝。
///
/// 这个坑的特点是：
/// - **不编译失败、不在真机上立刻可见**，代码看着完全正常；
/// - 报错发生在整条链路的**最后一步**，前面的图片渲染、文件落盘全都成功过了，
///   所以「导出失败」这个提示会把人引到完全错误的方向（我第一版就是这么查歪的，
///   以为是图片太长撑爆了像素上限）；
/// - 错误信息里没有任何「iPad」字样，只说 `must be set`，第一眼完全看不出缺什么。
///
/// 所以收口到这个文件：**一处传参，全项目不会再漏**。
library;

import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

/// 分享若干文件。
///
/// [origin] 是**触发分享的那个按钮**在屏幕上的位置。iPad 必须有它，
/// 传 null 或全零 `Rect` 都会抛（`must be non-zero`）—— 所以要传按钮，
/// 别传 `Rect.zero`。
Future<void> shareFiles({
  required List<XFile> files,
  String? subject,
  Rect? origin,
  BuildContext? context,
}) {
  return Share.shareXFiles(
    files,
    subject: subject,
    sharePositionOrigin: origin
        ?? (context == null ? null : originOf(context)),
  );
}

/// 分享纯文本。
///
/// 纯文本同样受 iPad 那条限制 —— `Share.share()` 走的是同一个
/// UIActivityViewController，所以这里也必须给 origin。
Future<void> shareText({
  required String text,
  Rect? origin,
  BuildContext? context,
}) {
  return Share.share(
    text,
    sharePositionOrigin: origin
        ?? (context == null ? null : originOf(context)),
  );
}

/// 从一个 [BuildContext] 算出它在全局坐标里的位置。
///
/// 拿不到就返回 `null`（让 share_plus 用自己的默认值）—— **不要返回一个假的
/// 非零 Rect**：那会让分享面板锚在一个看不见的地方，表现为「点了没反应」，
/// 比抛异常更难查。
Rect? originOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize || !box.attached) return null;
  final offset = box.localToGlobal(Offset.zero);
  return offset & box.size;
}

/// 按钮专用的 origin：把按钮自己当锚点。
///
/// [BuildContext] 传按钮的 context 时用它 —— 面板从按钮旁边弹出来，
/// 符合用户预期（iPad 上尤其重要，用户需要看到弹窗从哪来）。
Rect? buttonOrigin(BuildContext context) => originOf(context);
