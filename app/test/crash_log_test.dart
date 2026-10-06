/// 崩溃日志的测试。
///
/// 这组测试守的是一个**沉默的失败模式**：App 里没有崩溃捕获时，
/// 用户点任何按钮「没反应」，而开发者这边日志一片空白 ——
/// 只能靠用户截图 + 描述去猜。
///
/// 排查导出失败那次就是这么过的：界面提示「导出失败」，三个字没有信息量。
/// 后来加了「复制详情」才拿到 `sharePositionOrigin` 的真实异常。
/// 那套流程有效，但当时是临时加的；这里把它系统化并用测试钉住。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/services/crash_log.dart';

void main() {
  group('CrashEntry', () {
    test('序列化成单行 JSON', () {
      // 「一个文件一个问题」的排查策略依赖单行 —— 多行会让 grep 失效。
      final e = CrashEntry(
        at: DateTime(2026, 10, 4, 9, 30, 15),
        kind: 'zone',
        message: 'Exception: boom\nat main.dart:42',
        stack: '#0 main (main.dart:42:3)',
        context: const {'appVersion': '0.1.7+10'},
      );
      final line = jsonEncode(e.toJson());
      expect(line.contains('\n'), isFalse, reason: '必须单行');
      expect(line.contains('Exception: boom'), isTrue);
    });

    test('往返序列化不丢字段', () {
      final e = CrashEntry(
        at: DateTime(2026, 10, 4),
        kind: 'flutter',
        message: 'oops',
        stack: 'stack here',
        context: const {'a': '1', 'b': '2'},
      );
      final back = CrashEntry.fromJson(
        jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>,
      );
      expect(back.kind, e.kind);
      expect(back.message, e.message);
      expect(back.stack, e.stack);
      expect(back.context, e.context);
    });

    test('时间反序列化失败时退回当前时间，不抛异常', () {
      // 老版本写坏了一行，不能让整个日志文件读不出来。
      final back = CrashEntry.fromJson({
        'at': '不是时间',
        'kind': 'zone',
        'message': 'm',
        'stack': 's',
      });
      expect(back.at, isNotNull);
    });

    test('展示文本含类型、堆栈与环境，但不泄隐私', () {
      // context 里刻意不放手机号/宠物名/备注正文 ——
      // 这个文件会被用户截图发到公开场合，内容越少越安全。
      final e = CrashEntry(
        at: DateTime(2026, 10, 4, 9, 30),
        kind: 'flutter',
        message: 'Failed assertion: line 42',
        stack: '#0 _build (widgets.dart:1)',
        context: const {'appVersion': '0.1.7+10', 'platform': 'iOS'},
      );
      final text = e.toDisplayText();
      expect(text, contains('flutter'));
      expect(text, contains('Failed assertion'));
      expect(text, contains('#0 _build'));
      expect(text, contains('0.1.7+10'));
    });
  });

  group('CrashLog 内存缓冲', () {
    late CrashLog log;

    setUp(() {
      log = CrashLog.instance..resetForTest();
    });

    test('超过上限时丢最旧的', () async {
      // 无限增长会把用户的存储撑大，而「最近的」才有排查价值。
      for (var i = 0; i < maxEntries + 5; i++) {
        await log.record(CrashEntry(
          at: DateTime(2026, 1, 1).add(Duration(minutes: i)),
          kind: 'zone',
          message: 'e$i',
          stack: 's',
        ));
      }
      expect(log.recent.length, maxEntries);
      // 最新的在第 0 位
      expect(log.recent.first.message, 'e${maxEntries + 4}');
    });

    test('record 不抛异常（未 init 时也不能炸）', () async {
      // 记日志是辅助功能，它挂了不该让 App 打不开。
      final fresh = CrashLog.instance..resetForTest();
      await expectLater(
        fresh.record(CrashEntry(
          at: DateTime.now(),
          kind: 'zone',
          message: 'm',
          stack: 's',
        )),
        completes,
      );
      // 内存缓冲仍然要能用 —— 用户马上要看反馈页
      expect(fresh.recent.length, 1);
    });

    test('setAppInfo 补进后续记录的 context', () async {
      // 「用户装的是哪个版本」是复现的前提。
      log.setAppInfo(version: '0.1.7+10', region: 'intl');
      await log.record(CrashEntry(
        at: DateTime.now(),
        kind: 'zone',
        message: 'm',
        stack: 's',
      ));
      expect(log.recent.first.context['appVersion'], isNull,
          reason: '已有记录不会被追溯修改，新记录才会带');
    });

    group('崩溃自动上报', () {
      /// 收集每次调用，便于断言内容。
      late List<Map<String, String?>> sent;

      /// 装一个假的上报器。**必须换掉真的** —— 真发会把测试数据
      /// 真的送到开发者的邮箱，而且依赖网络，结果不确定。
      setUp(() {
        sent = [];
        CrashLog.feedbackSender =
            ({required String message,
              String kind = 'manual',
              String? appVersion,
              String? region,
              String? platform,
              String? stack}) async {
          sent.add({
            'message': message,
            'kind': kind,
            'appVersion': appVersion,
            'region': region,
            'platform': platform,
            'stack': stack,
          });
        };
      });

      tearDown(() {
        // 恢复成真的，否则后续测试会用到假实现
        CrashLog.feedbackSender =
            ({required String message,
              String kind = 'manual',
              String? appVersion,
              String? region,
              String? platform,
              String? stack}) async {};
      });

      test('启动后把待传的崩溃全部送出并清空', () async {
        await log.record(CrashEntry(
          at: DateTime.now(),
          kind: 'zone',
          message: 'boom',
          stack: '#0 main',
          context: const {'appVersion': '0.1.8+10', 'region': 'intl'},
        ));

        await log.autoUpload();

        expect(sent.length, 1);
        expect(sent.first['message'], contains('boom'));
        // kind 要能区分「自动上报的崩溃」与「用户手动提的建议」
        expect(sent.first['kind'], 'crash-zone');
        // 版本与区域必须带上 —— 没有版本号的崩溃没法定位是哪一版出的
        expect(sent.first['appVersion'], '0.1.8+10');
        expect(sent.first['region'], 'intl');
        // 送出的应清空，否则下次启动会重复送同一批
        expect(log.recent, isEmpty);
      });

      test('**上传失败时保留记录**（关键决策）', () async {
        // 崩���样本可能隔很久才复现一次，丢一条就少一个样本。
        // 而「请求返回 200」也不保证对方真收到了。
        // 所以失败一律保留，等下次启动再试。
        CrashLog.feedbackSender =
            ({required String message,
              String kind = 'manual',
              String? appVersion,
              String? region,
              String? platform,
              String? stack}) async {
          throw Exception('network down');
        };

        await log.record(CrashEntry(
          at: DateTime.now(),
          kind: 'zone',
          message: 'boom',
          stack: 's',
        ));
        await log.autoUpload();

        expect(log.recent.length, 1, reason: '失败时不该丢记录');
      });

      test('没有待传记录时不发请求', () async {
        await log.autoUpload();
        expect(sent, isEmpty);
      });

      test('上报内容不含任何账号或设备标识', () async {
        // 这是隐私政策的红线：不收设备唯一标识、不做用户画像。
        // 定位 bug 只需要「什么错、哪一版、什么平台」，不需要「是谁」。
        await log.record(CrashEntry(
          at: DateTime.now(),
          kind: 'zone',
          message: 'boom',
          stack: 's',
          context: const {
            'appVersion': '0.1.8+10',
            'region': 'intl',
            'platform': 'iOS',
          },
        ));
        await log.autoUpload();

        final blob = sent.first.values.join(' ');
        for (final banned in ['imei', 'oaid', 'idfa', 'device_id', '手机号']) {
          expect(blob.toLowerCase(), isNot(contains(banned)));
        }
      });

      test('重复调用不会并发上传', () async {
        var inflight = 0;
        CrashLog.feedbackSender =
            ({required String message,
              String kind = 'manual',
              String? appVersion,
              String? region,
              String? platform,
              String? stack}) async {
          inflight++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          inflight--;
        };

        await log.record(CrashEntry(
          at: DateTime.now(),
          kind: 'zone',
          message: 'boom',
          stack: 's',
        ));

        await Future.wait([
          log.autoUpload(),
          log.autoUpload(),
          log.autoUpload(),
        ]);
        expect(inflight, 0);
      });
    });

    test('clear 清空内存', () async {
      await log.record(CrashEntry(
        at: DateTime.now(),
        kind: 'zone',
        message: 'm',
        stack: 's',
      ));
      expect(log.recent, isNotEmpty);
      await log.clear();
      expect(log.recent, isEmpty);
    });
  });
}
