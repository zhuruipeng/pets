// ignore_for_file: avoid_print
/// 把生产 DDL 原样打印出来，供 `tool/schema_smoke.py` 在真 SQLite 上执行。
///
/// 为什么要有这一层：本机跑不了 `flutter test`（Windows 命名管道 231），
/// 而 schema.dart 是纯 Dart（不引 Flutter），所以能用 dart 直接取到同一份
/// 语句 —— 测试跑的必须是生产那份，不能是另抄一份（抄的那份迟早漏掉新列）。
///
/// 输出格式：每条语句之间用单独一行 `@@@` 分隔。语句本身是多行的，
/// 用换行分隔会让解析端分不清「语句内的换行」和「语句之间的分隔」。
///
///     E:/dev/flutter/bin/cache/dart-sdk/bin/dart.exe tool/dump_schema.dart
library;

import 'package:pet_app/data/db/schema.dart';

void main() {
  print('#VERSION $kSchemaVersion');

  print('#SECTION onCreate');
  for (final s in onCreate) {
    print(s);
    print('@@@');
  }

  for (final entry in migrations.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key))) {
    print('#SECTION migration ${entry.key}');
    for (final s in entry.value) {
      print(s);
      print('@@@');
    }
  }
}
