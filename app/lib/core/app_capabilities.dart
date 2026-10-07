/// 平台功能入口。地区规则仍由 region.dart 管理，数据层不读取功能开关。
library;

import 'dart:io';

import 'feature_flags.dart';

enum AppPlatform { android, ios, other }

enum AppFeature {
  petProfiles,
  familyCareBoard,
  medicationCourses,
  symptomObservations,
  careHandoff,
  localBackup,
  petDeletion,
  walkTracking,
  apkUpdates,
  iosWidgets,
  iosShortcuts,
}

class AppCapabilities {
  const AppCapabilities({required this.platform});

  final AppPlatform platform;

  static AppCapabilities get current => AppCapabilities(
        platform: Platform.isAndroid
            ? AppPlatform.android
            : Platform.isIOS
                ? AppPlatform.ios
                : AppPlatform.other,
      );

  bool supports(AppFeature feature) => switch (feature) {
        AppFeature.petProfiles ||
        AppFeature.familyCareBoard ||
        AppFeature.medicationCourses ||
        AppFeature.symptomObservations ||
        AppFeature.careHandoff ||
        AppFeature.localBackup ||
        AppFeature.petDeletion =>
          true,
        AppFeature.walkTracking =>
          kWalkEnabled && platform != AppPlatform.other,
        AppFeature.apkUpdates => platform == AppPlatform.android,
        // 预留苹果扩展；完成原生实现和真机验证后再开放入口。
        AppFeature.iosWidgets =>
          platform == AppPlatform.ios && kIosWidgetsEnabled,
        AppFeature.iosShortcuts =>
          platform == AppPlatform.ios && kIosShortcutsEnabled,
      };
}
