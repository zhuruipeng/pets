import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/services/app_update_service.dart';

/// 应用内更新里两条**纯判断**逻辑的单测。
///
/// 为什么单挑这两条：它们各自守着一个「错了用户也看不出来是哪儿错」的点 ——
/// `compareVersion` 决定要不要弹更新（错了就是永远不提示，或者天天提示），
/// `isDownloadComplete` 决定要不要把一个残缺的 60 MB 包交给系统安装器
/// （错了用户看到的是「解析包时出现问题」，跟下载毫无关联）。
/// 而它们都是纯函数，能直接测，没有理由不测。
void main() {
  group('compareVersion —— 决定「有没有新版」', () {
    test('相同版本返回 0', () {
      expect(AppUpdateService.compareVersion('0.1.0', '0.1.0'), 0);
    });

    test('主/次/修订号任一变大都要判为新', () {
      expect(AppUpdateService.compareVersion('0.2.0', '0.1.0'), greaterThan(0));
      expect(AppUpdateService.compareVersion('0.1.1', '0.1.0'), greaterThan(0));
      expect(AppUpdateService.compareVersion('1.0.0', '0.9.9'), greaterThan(0));
      expect(AppUpdateService.compareVersion('0.1.0', '0.2.0'), lessThan(0));
    });

    test('段数不齐时缺的那段按 0 算', () {
      // 服务端写 "0.1"、客户端是 "0.1.0" 时不能判成有更新，
      // 否则每次启动都弹一次更新框。
      expect(AppUpdateService.compareVersion('0.1', '0.1.0'), 0);
      expect(AppUpdateService.compareVersion('0.1.0', '0.1'), 0);
      expect(AppUpdateService.compareVersion('1', '0.9.9'), greaterThan(0));
    });

    test('预发布后缀不参与比较', () {
      // 注释里写明「遇到 1.0.0-beta 这类后缀按不参与比较处理」——
      // 也就是说 1.0.0-beta 与 1.0.0 视为同一个版本。
      expect(AppUpdateService.compareVersion('1.0.0-beta', '1.0.0'), 0);
      expect(AppUpdateService.compareVersion('1.0.0', '1.0.0-beta'), 0);
    });

    test('非法段当 0，不抛异常', () {
      // 版本名是人写的，服务端配错了也不能让 App 崩。
      expect(AppUpdateService.compareVersion('x.y.z', '0.0.0'), 0);
      expect(AppUpdateService.compareVersion('', '0.0.0'), 0);
    });
  });

  group('isDownloadComplete —— 决定「要不要把包交给安装器」', () {
    test('字节数与声明一致才算完成', () {
      expect(AppUpdateService.isDownloadComplete(64848330, 64848330), isTrue);
      expect(AppUpdateService.isDownloadComplete(1, 1), isTrue);
    });

    test('下载被截断必须判为未完成', () {
      // 这是本次修复针对的核心场景：60 MB 下到一半连接断了，
      // 而 HTTP 层可能认为响应已正常读完。不比对长度就会把坏包交出去。
      expect(AppUpdateService.isDownloadComplete(45 * 1024 * 1024, 64848330),
          isFalse);
      expect(AppUpdateService.isDownloadComplete(1, 64848330), isFalse);
    });

    test('一个字节都没下到也是未完成', () {
      expect(AppUpdateService.isDownloadComplete(0, 64848330), isFalse);
      expect(AppUpdateService.isDownloadComplete(0, null), isFalse);
    });

    test('拿不到长度时不判失败', () {
      // 服务端没给 Content-Length 是合法的（chunked 传输）。
      // 宁可放过一次可疑下载，也不能因此把所有正常下载判成失败 ——
      // 那会让更新功能在整个服务端配置下彻底不可用。
      expect(AppUpdateService.isDownloadComplete(12345, null), isTrue);
      // 长度为 0 或负数同样视为「没这个信息」。
      expect(AppUpdateService.isDownloadComplete(12345, 0), isTrue);
      expect(AppUpdateService.isDownloadComplete(12345, -1), isTrue);
    });

    test('收到比声明更多也判为不一致', () {
      // 服务端给了错的 Content-Length 时也该拦下，而不是照单全收。
      expect(AppUpdateService.isDownloadComplete(1001, 1000), isFalse);
    });
  });
}
