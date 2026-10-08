import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pet_app/core/app_capabilities.dart';
import 'package:pet_app/services/app_update_service.dart';

void main() {
  test('两端共享宠物业务，尚未实现的功能保持关闭', () {
    for (final platform in [AppPlatform.android, AppPlatform.ios]) {
      final capabilities = AppCapabilities(platform: platform);
      for (final feature in [
        AppFeature.petProfiles,
        AppFeature.familyCareBoard,
        AppFeature.medicationCourses,
        AppFeature.symptomObservations,
        AppFeature.careHandoff,
        AppFeature.localBackup,
        AppFeature.petDeletion,
      ]) {
        expect(capabilities.supports(feature), isTrue);
      }
      expect(capabilities.supports(AppFeature.walkTracking), isFalse);
      expect(capabilities.supports(AppFeature.iosWidgets), isFalse);
      expect(capabilities.supports(AppFeature.iosShortcuts), isFalse);
    }
  });

  test('iOS 与其它平台不请求安卓清单，也不能下载 APK', () async {
    for (final platform in [AppPlatform.ios, AppPlatform.other]) {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      });
      addTearDown(client.close);
      final service = AppUpdateService(
        client: client,
        capabilities: AppCapabilities(platform: platform),
      );
      expect(service.supportsUpdates, isFalse);
      final outcome = await service.check(currentBuild: 1);
      expect(outcome.status, UpdateCheckStatus.unsupported);
      await expectLater(
        service.download(const UpdateManifest(
          version: '9.0.0',
          build: 99,
          minBuild: 99,
          url: 'https://example.com/app.apk',
        )),
        throwsUnsupportedError,
      );
      expect(requests, 0);
    }
  });

  test('安卓保留升级与强制更新判断', () async {
    final client = MockClient((_) async => http.Response(
        jsonEncode({
          'version': '0.2.0',
          'build': 12,
          'minBuild': 10,
          'url': 'https://example.com/app.apk',
        }),
        200));
    addTearDown(client.close);
    final service = AppUpdateService(
      client: client,
      capabilities: const AppCapabilities(platform: AppPlatform.android),
    );
    expect(service.supportsUpdates, isTrue);
    final forced = await service.check(currentBuild: 9);
    expect(forced.status, UpdateCheckStatus.hasUpdate);
    expect(forced.result!.forced, isTrue);
    final optional = await service.check(currentBuild: 11);
    expect(optional.result!.forced, isFalse);
    final latest =
        await service.check(currentBuild: 12, currentVersion: '0.2.0');
    expect(latest.status, UpdateCheckStatus.upToDate);
  });
}
