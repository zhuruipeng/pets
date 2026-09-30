/// 个性特点的预设码表。
///
/// 两条约定：
/// 1. **存 code 不存文案** —— 文案随语言变，code 不变；换语言不用改数据。
/// 2. **只收「能观察到的性格」** —— 亲人、爱玩、胆小这类。不放「可爱」「漂亮」，
///    那是评价不是性格，而且列进多选只会让用户不知道该勾什么。
library;

import 'l10n.dart';

/// 顺序即界面上的展示顺序：先正向的，后中性的，最后胆小的。
const List<String> kPersonalityCodes = [
  'friendly',
  'playful',
  'calm',
  'social',
  'smart',
  'foodie',
  'shy',
  'active',
];

/// code → 当前语言的显示文案。未知 code 原样返回，便于将来加标签时
/// 老版本 App 至少能把它显示出来，而不是留个空白。
String personalityLabel(String code) {
  final key = 'trait.$code';
  final text = L.t(key);
  return text == key ? code : text;
}

/// 过滤掉不在预设里的 code。历史数据里可能有已废弃的标签，
/// 界面只展示认识的，避免出现「一个看不懂的灰标签」。
List<String> knownPersonalities(Iterable<String> codes) =>
    codes.where(kPersonalityCodes.contains).toList(growable: false);
