/// 费用汇总 —— 纯计算，不碰 Flutter / sqflite。
///
/// 单独拆一个文件是为了能离线验证（`dart tool/verify_expense.dart`）：
/// 本机 `flutter test` 跑不动（Windows 命名管道 231），所以凡是「算错了
/// 用户才发现」的逻辑都要能脱离 Flutter 单独跑。
library;

import '../data/models.dart';

/// 一个月的支出合计。
class ExpenseMonth {
  const ExpenseMonth({
    required this.year,
    required this.month,
    required this.total,
  });

  final int year;
  final int month; // 1-12
  final double total;

  /// 图表横轴标签用。「3月」而不是「2026-03」，轴太窄放不下全称。
  String get shortLabel => '$month';
}

/// 一个分类的支出合计。
class ExpenseSlice {
  const ExpenseSlice({required this.category, required this.total});

  final ExpenseCategory category;
  final double total;
}

class ExpenseSummary {
  const ExpenseSummary({
    required this.monthTotal,
    required this.allTotal,
    required this.monthCount,
    required this.months,
    required this.byCategory,
  });

  /// 本月合计。
  final double monthTotal;

  /// 累计合计（全部月份）。
  final double allTotal;

  /// 本月笔数。
  final int monthCount;

  /// 最近若干个月，升序（老 → 新），末位是当前月。
  final List<ExpenseMonth> months;

  /// 本月的分类占比，按金额降序。金额为 0 的分类不进列表。
  final List<ExpenseSlice> byCategory;

  /// 有数据的月份数（月均分摊的分母）。
  ///
  /// 用「有支出的月份数」而不是「月数」：App 装了三个月、只在其中一个月
  /// 记过账，月均 1200/3 会让人以为自家宠物每月花四百，其实是那个月花了一千二。
  int get activeMonths => months.where((m) => m.total > 0).length;

  /// 月均支出。没有任何支出时为 0。
  double get avgPerActiveMonth =>
      activeMonths == 0 ? 0 : allTotal / activeMonths;

  bool get isEmpty => allTotal == 0 && monthCount == 0;
}

/// 汇总一批支出。
///
/// [all] 应当是这只宠物的全部**未删除**支出 —— 累计与月度都要用到全部区间，
/// 只传当月就只剩当月数字了。
ExpenseSummary buildExpenseSummary(
  List<Expense> all, {
  required DateTime now,
  int monthsBack = 6,
}) {
  final monthStart = DateTime(now.year, now.month, 1);
  final nextMonth =
      now.month == 12 ? DateTime(now.year + 1, 1, 1) : DateTime(now.year, now.month + 1, 1);

  double monthTotal = 0;
  double allTotal = 0;
  var monthCount = 0;

  // 月度桶按「年*12+月序号」做键：跨年往前推时用 month - i 会算出 0 或负数，
  // 又得手写借位；换成整数轴就没有这个分支。
  final buckets = <int, double>{};
  final thisIdx = now.year * 12 + (now.month - 1);
  for (var i = 0; i < monthsBack; i++) {
    final idx = thisIdx - (monthsBack - 1 - i);
    buckets[_key(idx ~/ 12, idx % 12 + 1)] = 0;
  }

  final catTotals = <ExpenseCategory, double>{};

  for (final e in all) {
    allTotal += e.amount;

    if (!e.spentAt.isBefore(monthStart) && e.spentAt.isBefore(nextMonth)) {
      monthTotal += e.amount;
      monthCount++;
      catTotals[e.category] = (catTotals[e.category] ?? 0) + e.amount;
    }

    final k = _key(e.spentAt.year, e.spentAt.month);
    if (buckets.containsKey(k)) {
      buckets[k] = buckets[k]! + e.amount;
    }
  }

  final months = buckets.entries.toList()
    // 键是「年*12+月序号」，升序即时间升序。
    ..sort((a, b) => a.key.compareTo(b.key));

  final byCategory = catTotals.entries
      .where((e) => e.value > 0)
      .map((e) => ExpenseSlice(category: e.key, total: e.value))
      .toList()
    ..sort((a, b) => b.total.compareTo(a.total));

  return ExpenseSummary(
    monthTotal: monthTotal,
    allTotal: allTotal,
    monthCount: monthCount,
    months: [
      for (final e in months)
        ExpenseMonth(
          year: e.key ~/ 12,
          month: e.key % 12 + 1,
          total: e.value,
        ),
    ],
    byCategory: byCategory,
  );
}

int _key(int year, int month) => year * 12 + (month - 1);

/// 币种符号表。查不到就回落到代码本身 —— 宁可显示「CNY 120」也不要
/// 显示一个错的 ¥。
const Map<String, String> kCurrencySymbols = {
  'CNY': '¥',
  'USD': '\$',
  'EUR': '€',
  'GBP': '£',
  'JPY': '¥',
  'HKD': 'HK\$',
  'TWD': 'NT\$',
};

String currencySymbolOf(String code) => kCurrencySymbols[code] ?? '$code ';

/// 金额展示：整数不带小数，有零头就保留两位。
///
/// 为什么不让小数位固定两位：「本月支出 ¥1,200.00」在卡片大字号上很啰嗦，
/// 而 ¥12.50 少写一位又会被读成 ¥125。按有没有零头切换是最省事又不出错的写法。
String formatMoney(double amount, String currency) {
  final sym = currencySymbolOf(currency);
  final abs = amount.abs();
  final text = (abs - abs.roundToDouble()).abs() < 0.005
      ? _group(abs.round())
      : _group(double.parse(abs.toStringAsFixed(2)));
  return '${amount < 0 ? '-' : ''}$sym$text';
}

/// 千分位。手写一个而不用 intl 的 NumberFormat：后者要加载 locale 数据，
/// 离线验证脚本（`dart tool/verify_expense.dart`）里没有那份数据会直接抛。
String _group(num v) {
  final s = v.toString();
  final dot = s.indexOf('.');
  final intPart = dot < 0 ? s : s.substring(0, dot);
  final frac = dot < 0 ? '' : s.substring(dot);
  final buf = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
    buf.write(intPart[i]);
  }
  return '$buf$frac';
}
