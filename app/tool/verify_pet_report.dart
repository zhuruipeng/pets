// ignore_for_file: avoid_print
/// 离线真跑「导出健康报告」的内容组装。
///
/// 报告最容易错的是内容而不是排版：哪条记录该进、日期怎么排、空数据会不会
/// 印成「null」。`pet_report.dart` 刻意做成了纯数据（不碰 Flutter），所以能用
/// dart 直接跑这一遍 —— 本机跑不了 `flutter test`（管道 231）。
///
///     E:/dev/flutter/bin/cache/dart-sdk/bin/dart.exe tool/verify_pet_report.dart
library;

import 'package:pet_app/core/units.dart';
import 'package:pet_app/data/models.dart';
import 'package:pet_app/domain/health_ledger.dart';
import 'package:pet_app/domain/immunization.dart';
import 'package:pet_app/domain/pet_report.dart';

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

Pet _pet({
  String name = '额藕丝',
  Species species = Species.dog,
  DateTime? birthday,
  String? breed = '金毛',
  double? weightBaseline,
  bool neutered = false,
  String? chipNo,
  String? allergy,
}) =>
    Pet(
      id: 'p1',
      name: name,
      species: species,
      breed: breed,
      birthday: birthday,
      weightBaseline: weightBaseline,
      neutered: neutered,
      chipNo: chipNo,
      allergy: allergy,
      createdBy: 'u1',
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

PetRecord _record(
  RecordType type,
  DateTime at, {
  double? num,
  String? unit,
  String? text,
  Map<String, dynamic> payload = const {},
  String? note,
}) =>
    PetRecord(
      id: 'r${at.millisecondsSinceEpoch}-${type.wireName}',
      petId: 'p1',
      type: type,
      recordedAt: at,
      valueNum: num,
      unit: unit,
      valueText: text,
      payload: payload,
      note: note,
      createdBy: 'u1',
      createdAt: at,
      updatedAt: at,
    );

void main() {
  final now = DateTime(2026, 10, 1, 9, 0);
  const kg = WeightUnit.kg;

  // ---- 1) 日期格式固定为 yyyy-MM-dd（不随语言变）----
  check(
    reportDate(DateTime(2026, 10, 1)) == '2026-10-01',
    '日期应为 2026-10-01，实际 ${reportDate(DateTime(2026, 10, 1))}',
  );
  check(
    reportDate(DateTime(2026, 1, 5)) == '2026-01-05',
    '月份和日应补零',
  );

  // ---- 2) 空数据：不印空表 ----
  final empty = buildPetReport(
    pet: _pet(),
    ledger: const [],
    weightSeries: const [],
    records: const [],
    now: now,
    weightUnit: kg,
  );
  check(empty.hasNothing, '没有记录也没有体重时应标记为「没内容」');
  check(empty.filledCareRows.isEmpty, '台账全空时不该有可印的行');

  // ---- 3) 简介拼接：物种 · 品种 · 年龄 ----
  final dog = buildPetReport(
    pet: _pet(birthday: DateTime(2023, 8, 1)), // 3 岁 2 个月
    ledger: const [],
    weightSeries: const [],
    records: const [],
    now: now,
    weightUnit: kg,
  );
  // 断言段落数而不是具体词：离线跑时语言环境未必是中文（实测输出
  // 「Dog · 金毛 · 3y 2mo」），绑死中文会让脚本在英文环境下假失败。
  // 品种和年龄是数据/数字，可以照断。
  check(
    dog.subtitle.split(' · ').length == 3,
    '简介应是「物种 · 品种 · 年龄」三段：${dog.subtitle}',
  );
  check(dog.subtitle.contains('金毛'), '简介应含品种：${dog.subtitle}');
  check(dog.subtitle.contains('3'), '简介应含年龄：${dog.subtitle}');

  // 没有品种时不留空档（别出现「Dog ·  · 3y」这种）
  final noBreed = buildPetReport(
    pet: _pet(birthday: DateTime(2023, 8, 1), breed: null),
    ledger: const [],
    weightSeries: const [],
    records: const [],
    now: now,
    weightUnit: kg,
  );
  check(
    noBreed.subtitle.split(' · ').length == 2,
    '缺品种时应只剩两段、不留空档：${noBreed.subtitle}',
  );

  // ---- 4) 台账：只印有内容的行 ----
  final ledger = <CareLedgerRow>[
    const CareLedgerRow(
      kind: PlanItemType.vaccine,
      lastDoneAt: null,
      nextDueAt: null,
    ), // 全空 → 不印
    CareLedgerRow(
      kind: PlanItemType.grooming,
      lastDoneAt: DateTime(2026, 9, 20),
      nextDueAt: DateTime(2026, 10, 20),
    ),
  ];
  final withLedger = buildPetReport(
    pet: _pet(birthday: DateTime(2023, 8, 1)),
    ledger: ledger,
    weightSeries: const [],
    records: const [],
    now: now,
    weightUnit: kg,
  );
  check(withLedger.careRows.length == 2, '台账行数应保留全部 2 行');
  check(withLedger.filledCareRows.length == 1, '只应有 1 行有内容可印');
  check(
    withLedger.filledCareRows.first.nextText == '2026-10-20',
    '下一次日期应格式化：${withLedger.filledCareRows.first.nextText}',
  );

  // ---- 5) 记录排序与条数上限 ----
  final many = [
    for (var i = 1; i <= 20; i++)
      _record(RecordType.weight, DateTime(2026, 9, i > 28 ? 28 : i), num: 20.0 + i),
  ];
  final capped = buildPetReport(
    pet: _pet(),
    ledger: const [],
    weightSeries: const [],
    records: many,
    now: now,
    weightUnit: kg,
    maxRecords: 5,
  );
  check(capped.records.length == 5, '记录应被截到 5 条，实际 ${capped.records.length}');
  check(
    capped.records.first.when.isAfter(capped.records.last.when),
    '记录应按时间倒序（最新的在最前）',
  );

  // ---- 6) 体重序列：取最近 N 个且保持升序 ----
  final series = [
    for (var i = 1; i <= 20; i++)
      (at: DateTime(2026, 1, 1).add(Duration(days: i)), kg: 30.0 + i),
  ];
  final w = buildPetReport(
    pet: _pet(),
    ledger: const [],
    weightSeries: series,
    records: const [],
    now: now,
    weightUnit: kg,
    maxWeights: 6,
  );
  check(w.weightPoints.length == 6, '体重应被截到 6 个点，实际 ${w.weightPoints.length}');
  check(
    w.weightPoints.first.at.isBefore(w.weightPoints.last.at),
    '体重点应保持时间升序（画折线用）',
  );
  check(
    w.weightPoints.last.kg == 50.0,
    '截取应保留最近的点（kg=50），实际 ${w.weightPoints.last.kg}',
  );

  // ---- 7) 数值与单位换算（报告必须跟区域走）----
  final weighted = buildPetReport(
    pet: _pet(),
    ledger: const [],
    weightSeries: const [],
    records: [
      _record(RecordType.weight, DateTime(2026, 9, 30), num: 10.0),
      _record(RecordType.feeding, DateTime(2026, 9, 29),
          num: 120, unit: 'g', payload: {'kind': 'dry'}),
      _record(RecordType.note, DateTime(2026, 9, 28), text: '  '),
    ],
    now: now,
    weightUnit: WeightUnit.lb,
  );
  final weightLine = weighted.records
      .firstWhere((r) => r.typeLabel.contains('体') || r.typeLabel.contains('Weight'))
      .value;
  check(
    weightLine != null && weightLine.contains('lb'),
    '海外区域体重应换算成 lb，实际 $weightLine',
  );
  final feedLine = weighted.records
      .firstWhere((r) => r.typeLabel.contains('喂') || r.typeLabel.contains('Feed'))
      .value;
  check(feedLine == '120 g', '喂食应带自己的单位，实际 $feedLine');

  // ---- 8) 空白文本不该印成空串 ----
  final blank = weighted.records.last;
  check(blank.value == null, '只有空格的 valueText 应归一成 null');
  check(blank.note == null, '没填的 note 应是 null 而不是空串');

  // ---- 9) payload 摘要进 detail ----
  final med = buildPetReport(
    pet: _pet(),
    ledger: const [],
    weightSeries: const [],
    records: [
      _record(RecordType.medication, DateTime(2026, 9, 27),
          payload: {'dose': '1 片', 'route': 'oral'}),
    ],
    now: now,
    weightUnit: kg,
  );
  check(
    med.records.first.detail != null && med.records.first.detail!.contains('1 片'),
    '用药的剂量应进 detail，实际 ${med.records.first.detail}',
  );

  // ---- 10) 每日日志的两个新类型：单位与小数位 ----
  final daily = buildPetReport(
    pet: _pet(),
    ledger: const [],
    weightSeries: const [],
    records: [
      _record(RecordType.water, DateTime(2026, 9, 30), num: 200, unit: 'ml'),
      _record(RecordType.sleep, DateTime(2026, 9, 30), num: 8.5, unit: 'h'),
    ],
    now: now,
    weightUnit: kg,
  );
  final water =
      daily.records.firstWhere((r) => (r.value ?? '').contains('ml'));
  check(water.value == '200 ml', '饮水取整不带小数点，实际 ${water.value}');
  final sleep = daily.records.firstWhere((r) => (r.value ?? '').contains('h'));
  check(sleep.value == '8.5 h', '睡眠保留一位小数，实际 ${sleep.value}');

  print('');
  print('通过 $_passed 项，失败 $_failed 项');
  if (_failed > 0) {
    throw StateError('报告组装验证失败 $_failed 项');
  }
}
