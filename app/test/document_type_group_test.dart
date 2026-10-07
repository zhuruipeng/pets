/// 文件选择器的类型过滤必须在 iOS 上可用。
///
/// ## 这个 bug 是怎么被发现和理解的
///
/// 用户报「点 Add document 没反应」。修了 `try` 之后错误能报出来了，
/// 真机截图显示：
///
///     Could not open the file picker: Invalid argument(s): The provided
///     type group Instance of 'XTypeGroup' should either allow all files,
///     or have a non-empty "uniformTypeIdentifiers"
///
/// **iOS 不看 `extensions`，只看 `uniformTypeIdentifiers`（UTI）。**
/// 只传 extensions 时它不是「过滤失效」，而是**直接抛异常、选择器打不开**。
///
/// ## 为什么拖了这么久才找到
///
/// - macOS / Windows / Android 上 `extensions` 是有效的，所以
///   「在 Mac 上试」永远不会暴露
/// - `flutter test` 不碰真机插件，也不会暴露
/// - 错误信息说的是「参数不合法」，看着像调用方式错了，
///   而真实原因是「这个平台根本不读那个参数」
///
/// 只有真机 iOS 才会撞上。所以这组测试的职责很窄但很关键：
/// **保证两个调用点都传了 UTI，且每个扩展名都有对应映射**。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/ui/record_detail.dart';

/// 扩展名 → UTI。
///
/// 这份表是**校验用**的，不是生产代码用的 —— 生产代码直接读
/// `kDocumentUtis`。放在测试里是为了让「加了扩展名但忘了 UTI」
/// 这种事在 CI 就挂掉，而不是等用户在真机上发现选择器打不开。
const Map<String, String> kExtToUti = {
  'pdf': 'com.adobe.pdf',
  'doc': 'com.microsoft.word.doc',
  'docx': 'org.openxmlformats.wordprocessingml.document',
  'xls': 'com.microsoft.excel.xls',
  'xlsx': 'org.openxmlformats.spreadsheetml.sheet',
  'txt': 'public.plain-text',
  'jpg': 'public.jpeg',
  'jpeg': 'public.jpeg',
  'png': 'public.png',
  'heic': 'public.heic',
  'webp': 'org.webmproject.webp',
};

void main() {
  test('UTI 列表非空 —— 空了 iOS 会直接拒绝', () {
    expect(kDocumentUtis, isNotEmpty);
  });

  test('每个允许的扩展名都有对应的 UTI', () {
    // 这是最容易出的错：新加一个扩展名到 kDocumentExtensions，
    // 忘了同步 kDocumentUtis —— 结果那个格式的文件在 iOS 上选不了，
    // 而且看起来像「选择器坏了」，不是「少配了一个类型」。
    for (final ext in kDocumentExtensions) {
      expect(
        kExtToUti.containsKey(ext),
        isTrue,
        reason: '扩展名 `.`$ext 没有 UTI 映射 —— 请补 kDocumentUtis',
      );
      expect(
        kDocumentUtis.contains(kExtToUti[ext]),
        isTrue,
        reason: '`.$ext` 的 UTI `${kExtToUti[ext]}` 不在 kDocumentUtis 里',
      );
    }
  });

  test('UTI 列表里没有多余的项', () {
    // 反向检查：kDocumentUtis 里每一项都该能对应回一个扩展名。
    // 多了不致命，但说明两边已经不同步了，早晚出错。
    for (final uti in kDocumentUtis) {
      expect(
        kExtToUti.containsValue(uti),
        isTrue,
        reason: 'UTI `$uti` 在扩展名表里找不到对应 —— 两边不同步了',
      );
    }
  });

  test('doc 与 docx 用不同的 UTI', () {
    // 这两个格式的 UTI 完全不一样，容易想当然地写成一个。
    expect(kExtToUti['doc'], isNot(kExtToUti['docx']));
    expect(kExtToUti['xls'], isNot(kExtToUti['xlsx']));
  });
}
