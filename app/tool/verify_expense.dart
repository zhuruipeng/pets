// ignore_for_file: avoid_print
/// 离线真跑「费用追踪」的汇总与格式化。
///
/// 费用最容易错的三处：月度分桶（跨年时会算错月份）、「本月」的边界
/// （月初第一毫秒和月末最后一毫秒归哪个月）、金额展示（整数多带两位小数、
/// 大额少了千分位）。这些在 UI 上都是一眼看不出的小偏差，所以单独跑一遍。
///
///     E:/dev/flutter/bin/cache/dart-sdk/bin/dart.exe tool/verify_expense.dart
library;

import 'package:pet_app/core/l10n.dart';
import 'package:pet_app/data/models.dart';
import 'package:pet_app/domain/expense_stats.dart';

int _passed = 0;
int _failed = 0;

void check(bool ok, String what) {
  if (ok) {
    _passed++;
  } else {
    _failed++;
    print('FAIL  $what');
  }
}

Expense _e(
  ExpenseCategory c,
  double amount,
  DateTime at, {
  String currency = 'CNY',
  String? note,
}) =>
    Expense(
      id: 'e-${at.millisecondsSinceEpoch}-${c.wireName}',
      petId: 'p1',
      amount: amount,
      currency: currency,
      category: c,
      spentAt: at,
      note: note,
      createdBy: 'u1',
      createdAt: at,
      updatedAt: at,
    );

void main() {
  // 固定在 2026-09-30，让「本月」与「近半年」有确定答案。
  final now = DateTime(2026, 9, 30, 14, 20);

  // ---- 1) 中英文表键数一致 ----
  final diff = L.tableDiff();
  check(diff.onlyZh.isEmpty && diff.onlyEn.isEmpty,
      '中英文键一致，实际 zh 多 ${diff.onlyZh.length} / en 多 ${diff.onlyEn.length}');

  // ---- 2) 费用类别的 wire 往返 ----
  check(ExpenseCategory.values.length == 8, '8 个费用类别');
  for (final c in ExpenseCategory.values) {
    check(expenseCategoryFromWire(c.wireName) == c, 'wire 往返一致: ${c.name}');
  }
  check(expenseCategoryFromWire(null) == ExpenseCategory.other,
      '未知类别落 other');
  check(expenseCategoryFromWire('乱写') == ExpenseCategory.other,
      '乱码类别落 other');

  // ---- 3) 空数据 ----
  final empty = buildExpenseSummary(const [], now: now);
  check(empty.isEmpty, '没有支出时 isEmpty');
  check(empty.allTotal == 0, '空数据累计为 0');
  check(empty.monthCount == 0, '空数据本月 0 笔');
  check(empty.avgPerActiveMonth == 0, '空数据月均为 0（不除零）');
  check(empty.months.length == 6, '空数据也有 6 个月桶（图表不塌）');

  // ---- 4) 本月 / 累计的区分 ----
  final sep = <Expense>[
    _e(ExpenseCategory.food, 320, DateTime(2026, 9, 3)),
    _e(ExpenseCategory.vaccine, 120, DateTime(2026, 9, 28)),
    _e(ExpenseCategory.medical, 800, DateTime(2026, 5, 11)), // 窗口外
  ];
  final s = buildExpenseSummary(sep, now: now);
  check(s.monthTotal == 440, '本月合计 320+120=440，实际 ${s.monthTotal}');
  check(s.allTotal == 1240, '累计含窗口外的 800，实际 ${s.allTotal}');
  check(s.monthCount == 2, '本月 2 笔，实际 ${s.monthCount}');

  // ---- 5) 月度分桶跨年 ----
  // now 在 2026-09，往前 6 个月应是 2026-04 … 2026-09。
  check(s.months.length == 6, '6 个月桶');
  check(s.months.last.year == 2026 && s.months.last.month == 9,
      '最后一个桶是当前月，实际 ${s.months.last.year}-${s.months.last.month}');
  check(s.months.first.year == 2026 && s.months.first.month == 4,
      '第一个桶是 2026-04，实际 ${s.months.first.year}-${s.months.first.month}');
  // 5 月那笔在窗口内，4 月没有支出。
  final may = s.months.firstWhere((m) => m.month == 5);
  check(may.total == 800, '5 月那笔落在 5 月桶，实际 ${may.total}');

  // 跨年：now 推到 2027-02，桶应覆盖 2026-09 … 2027-02。
  final cross = buildExpenseSummary(
    [_e(ExpenseCategory.food, 100, DateTime(2026, 12, 25))],
    now: DateTime(2027, 2, 10),
  );
  check(cross.months.length == 6, '跨年仍是 6 个桶');
  check(cross.months.first.year == 2026 && cross.months.first.month == 9,
      '跨年首桶 2026-09，实际 ${cross.months.first.year}-${cross.months.first.month}');
  check(cross.months.last.year == 2027 && cross.months.last.month == 2,
      '跨年末桶 2027-02，实际 ${cross.months.last.year}-${cross.months.last.month}');
  final dec = cross.months.firstWhere((m) => m.month == 12);
  check(dec.year == 2026 && dec.total == 100,
      '2026-12 那笔不会算进 2027-12，实际 ${dec.year}-${dec.month}=${dec.total}');

  // ---- 6) 月度边界 ----
  // 本月 1 号 00:00:00.000 算本月；下月 1 号 00:00:00.000 不算。
  final edge = buildExpenseSummary(
    [
      _e(ExpenseCategory.food, 10, DateTime(2026, 9, 1)),
      _e(ExpenseCategory.food, 20, DateTime(2026, 9, 30, 23, 59, 59)),
      _e(ExpenseCategory.food, 30, DateTime(2026, 10, 1)),
    ],
    now: now,
  );
  check(edge.monthTotal == 30, '月初与月末都算本月，下月 1 号不算，实际 ${edge.monthTotal}');
  check(edge.allTotal == 60, '三笔都进累计，实际 ${edge.allTotal}');

  // ---- 7) 分类占比 ----
  final cats = buildExpenseSummary(
    [
      _e(ExpenseCategory.food, 300, DateTime(2026, 9, 2)),
      _e(ExpenseCategory.medical, 500, DateTime(2026, 9, 4)),
      _e(ExpenseCategory.supply, 200, DateTime(2026, 9, 6)),
      _e(ExpenseCategory.food, 100, DateTime(2026, 8, 6)), // 上月，不进占比
    ],
    now: now,
  );
  check(cats.byCategory.length == 3, '本月 3 个分类，实际 ${cats.byCategory.length}');
  check(cats.byCategory.first.category == ExpenseCategory.medical,
      '按金额降序，首位是就诊，实际 ${cats.byCategory.first.category.name}');
  check(cats.byCategory.first.total == 500, '就诊 500，实际 ${cats.byCategory.first.total}');
  final foodSlice = cats.byCategory.firstWhere((x) => x.category == ExpenseCategory.food);
  check(foodSlice.total == 300, '同分类本月累加（上月那笔不算），实际 ${foodSlice.total}');

  // ---- 8) 月均按「有支出的月份数」摊 ----
  final avg = buildExpenseSummary(
    [_e(ExpenseCategory.food, 1200, DateTime(2026, 9, 2))],
    now: now,
  );
  check(avg.activeMonths == 1, '只有 1 个月有支出，实际 ${avg.activeMonths}');
  check(avg.avgPerActiveMonth == 1200,
      '月均按有支出的月份摊（不是 /6），实际 ${avg.avgPerActiveMonth}');

  // ---- 9) 金额展示 ----
  check(currencySymbolOf('CNY') == '¥', 'CNY 符号');
  check(currencySymbolOf('USD') == '\$', 'USD 符号');
  check(currencySymbolOf('XYZ').startsWith('XYZ'), '未知币种回落到代码本身');
  check(formatMoney(120, 'CNY') == '¥120', '整数不带小数，实际 ${formatMoney(120, 'CNY')}');
  check(formatMoney(12.5, 'CNY') == '¥12.5', '有零头保留小数，实际 ${formatMoney(12.5, 'CNY')}');
  check(formatMoney(12.56, 'CNY') == '¥12.56', '两位小数，实际 ${formatMoney(12.56, 'CNY')}');
  check(formatMoney(1234, 'CNY') == '¥1,234', '千分位，实际 ${formatMoney(1234, 'CNY')}');
  check(formatMoney(1234567.5, 'CNY') == '¥1,234,567.5',
      '大额千分位 + 小数，实际 ${formatMoney(1234567.5, 'CNY')}');
  check(formatMoney(0, 'CNY') == '¥0', '零金额');
  check(formatMoney(-12.5, 'CNY') == '-¥12.5', '负数（退款）保留负号');

  // ---- 10) Expense 的存取往返 ----
  final src = _e(
    ExpenseCategory.boarding,
    88.8,
    DateTime(2026, 9, 9),
    note: '出差寄养',
  );
  final back = Expense.fromMap(src.toMap());
  check(back.id == src.id && back.petId == src.petId, '往返：主键与归属');
  check(back.amount == 88.8, '往返：金额，实际 ${back.amount}');
  check(back.category == ExpenseCategory.boarding, '往返：类别');
  check(back.note == '出差寄养', '往返：备注');
  check(back.spentAt == DateTime(2026, 9, 9), '往返：消费日期');
  check(back.deletedAt == null, '往返：未删除时 deleted_at 是 null');
  check(src.toMap()['currency'] == 'CNY', '存 ISO 代码而不是符号');

  // ---- 11) monthsBack 可配 ----
  final three = buildExpenseSummary(sep, now: now, monthsBack: 3);
  check(three.months.length == 3, 'monthsBack=3 只出 3 个桶');
  check(three.allTotal == 1240, '桶的多少不影响累计，实际 ${three.allTotal}');

  print('');
  print('通过 $_passed 项，失败 $_failed 项');
  if (_failed > 0) {
    throw StateError('费用汇总验证失败 $_failed 项');
  }
}
