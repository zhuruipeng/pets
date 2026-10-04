/// 单位换算与格式化。中国 + 海外共用。
///
/// 铁律：数据库里一律存公制（kg / cm / ℃ / 米）。
/// 只在「展示」和「输入」两层做换算，绝不让两套单位混进存储层。
library;

import 'region.dart';

enum WeightUnit { kg, lb }

enum LengthUnit { cm, inch }

enum DistanceUnit { km, mile }

enum TempUnit { celsius, fahrenheit }

class Units {
  Units._();

  static const double _lbPerKg = 2.2046226218;
  static const double _inchPerCm = 0.3937007874;
  static const double _metersPerMile = 1609.344;

  // ---------------- 重量 ----------------

  static double kgToLb(double kg) => kg * _lbPerKg;

  static double lbToKg(double lb) => lb / _lbPerKg;

  static double toDisplayWeight(double kg, WeightUnit unit) =>
      unit == WeightUnit.kg ? kg : kgToLb(kg);

  static double fromDisplayWeight(double value, WeightUnit unit) =>
      unit == WeightUnit.kg ? value : lbToKg(value);

  static String weightSymbol(WeightUnit unit) =>
      unit == WeightUnit.kg ? 'kg' : 'lb';

  /// 权重单位标签。与 [weightSymbol] 同义，命名为的是在 UI 里读起来顺。
  static String weightUnitLabel(WeightUnit unit) => weightSymbol(unit);

  // ---------------- 距离（遛狗轨迹） ----------------

  static double metersToKm(double m) => m / 1000.0;

  static double metersToMiles(double m) => m / _metersPerMile;

  static double metersToDisplay(double m, DistanceUnit unit) =>
      unit == DistanceUnit.km ? metersToKm(m) : metersToMiles(m);

  static String distanceSymbol(DistanceUnit unit) =>
      unit == DistanceUnit.km ? 'km' : 'mi';

  // ---------------- 长度 ----------------

  static double cmToInch(double cm) => cm * _inchPerCm;

  static double inchToCm(double inch) => inch / _inchPerCm;

  // ---------------- 温度 ----------------

  static double celsiusToFahrenheit(double c) => c * 9 / 5 + 32;

  static double fahrenheitToCelsius(double f) => (f - 32) * 5 / 9;

  // ---------------- 格式化 ----------------

  static String formatWeight(double kg, WeightUnit unit, {int decimals = 1}) {
    final v = toDisplayWeight(kg, unit);
    return '${v.toStringAsFixed(decimals)} ${weightSymbol(unit)}';
  }

  /// 只出数字，不带单位。UI 上数值和单位分开排版时用这个。
  static String weightNumber(double kg, WeightUnit unit, {int decimals = 1}) =>
      toDisplayWeight(kg, unit).toStringAsFixed(decimals);

  static String formatDistance(
    double meters,
    DistanceUnit unit, {
    int decimals = 2,
  }) {
    final v = metersToDisplay(meters, unit);
    return '${v.toStringAsFixed(decimals)} ${distanceSymbol(unit)}';
  }

  /// 把秒数格式化成「1小时23分」/「1h 23m」之外的通用形式由 i18n 处理。
  /// 这里只负责拆成小时与分钟，避免把语言逻辑塞进工具类。
  static (int hours, int minutes) splitDuration(int seconds) =>
      (seconds ~/ 3600, (seconds % 3600) ~/ 60);

  // ---------------- 默认值（按区域） ----------------

  /// 体重默认单位。
  ///
  /// **只按区域判定，不接 locale 参数。**
  ///
  /// ⚠️ 这里以前是 `defaultWeightUnit(Region region, String localeName)`，
  /// 判断 `localeName.startsWith('en_us')`。而 15 处调用点传的是
  /// `region.name` —— 那是 `'intl'`，不是 `'en_US'`。于是判断恒为 false，
  /// **美国用户拿到的还是 kg，而界面不报任何错**。
  /// 纯函数测试只测了 kgToLb/toDisplayWeight，没测这个默认值，bug 一路漏到真机。
  ///
  /// 去掉 locale 参数不是图省事，是**把易错的那一步从调用方手里拿走**：
  /// 单位跟着市场走是本项目的既有约定（`region.dart` 的 `defaultUseImperial`
  /// 早就把这件事定义好了），让每个调用点自己判断 locale 等于把同一个决定
  /// 复制 15 遍 —— 第 16 遍一定会写错。
  ///
  /// 依据：`RegionBehavior.defaultUseImperial`（美式习惯用磅，其余海外地区用公斤）。
  static WeightUnit defaultWeightUnit(Region region) =>
      region.defaultUseImperial ? WeightUnit.lb : WeightUnit.kg;

  /// 距离默认单位。与 [defaultWeightUnit] 同理，跟随区域而不是 locale。
  static DistanceUnit defaultDistanceUnit(Region region) =>
      region.defaultUseImperial ? DistanceUnit.mile : DistanceUnit.km;
}
