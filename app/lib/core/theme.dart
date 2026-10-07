/// 设计令牌 —— 颜色与排版常量。
///
/// 全部集中在这里，页面里不许写裸 Color(0x...)。
/// 取值来自评审参考稿（爱宠陪伴风格），后续换肤只改这一个文件。
///
/// 主题策略：**浅色主题 + 高饱和紫色主色 + 语义色（红=警示/过期、绿=正向）。**
/// 注意：这里说的是界面通用语义色，与股票涨跌配色无关。
library;

import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  /// 主色 —— 参考稿的紫，比 Material 默认紫更饱和明亮。
  ///
  /// 色值以 MVP v1.0 规格为准（primary: #7657E8）。
  /// [seed] 必须和 [primary] 一致：Material 3 的 ColorScheme 由 seed 推导，
  /// 两者不一致会出现「按钮是 A 色、文字选中态是 B 色」的割裂。
  static const Color seed = Color(0xFF7657E8);
  static const Color primary = Color(0xFF7657E8);
  static const Color primaryText = Color(0xFF6244C5);
  static const Color primaryLight = Color(0xFFEDE9FE);

  /// 页面底色：非常浅的冷灰，让白卡片浮起来但不刺眼。
  static const Color pageBg = Color(0xFFF8F8FB);
  static const Color surface = Colors.white;

  /// 卡片描边：极淡，几乎只做边界提示。
  static const Color border = Color(0xFFE5E5EF);
  static const Color divider = Color(0xFFF1F1F5);

  /// 文字三级。
  static const Color textPrimary = Color(0xFF1A1A1F);
  static const Color textSecondary = Color(0xFF626272);
  static const Color textTertiary = Color(0xFF707080);

  /// 语义色。
  static const Color danger = Color(0xFFC7353C);
  static const Color dangerBg = Color(0xFFFDECEC);
  static const Color success = Color(0xFF168344);
  static const Color successBg = Color(0xFFE7F7EE);
  static const Color warning = Color(0xFFA65E09);
  static const Color warningBg = Color(0xFFFDF3E7);

  /// 今日待办「类型图标」的底色。参考稿里每个待办图标底色不同，
  /// 用来在一眼扫过时区分类型，比统一的紫色更好认。
  static const List<Color> tileTints = [
    Color(0xFFEDE9FE), // 紫
    Color(0xFFDDEEFE), // 蓝
    Color(0xFFFDE8EC), // 粉
    Color(0xFFE4F5E9), // 绿
    Color(0xFFFDF0E0), // 橙
  ];
}

/// 圆角与间距。参考稿用的是大圆角 + 宽松留白。
class AppRadius {
  AppRadius._();

  static const double card = 18;
  static const double tile = 16;
  static const double chip = 999;

  static BorderRadius get cardBorder => BorderRadius.circular(card);
  static BorderRadius get tileBorder => BorderRadius.circular(tile);
}

class AppSpace {
  AppSpace._();

  /// 页面左右边距。
  static const double page = 16;

  /// 底栏已独立于内容，仅为最后一个区块保留呼吸空间。
  static const double pageBottom = 32;
  static const double tapTarget = 44;

  static const double gapXs = 4;
  static const double gapS = 8;
  static const double gapM = 12;
  static const double gapL = 16;
  static const double gapXl = 24;
}

/// 渐变工具。参考稿的头像区与主色块用了非常淡的渐变。
/// 只允许用在「装饰性容器」，不要用在文字背景上。
///
/// 两个渐变**必须是 `static const`**：调用方常写
/// `decoration: const BoxDecoration(gradient: AppGradients.header)`，
/// 而非常量字段不能在常量表达式里用（编译器会报
/// "Context: The invocation of 'header' is not allowed in a constant expression"）。
class AppGradients {
  AppGradients._();

  /// 宠物详情头部：淡紫 → 淡蓝，纵向。
  static const LinearGradient header = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFEFEAFF), Color(0xFFE8F1FF)],
  );

  /// 主色卡片（如当前遛狗中）。两端是 [AppColors.primary] 的提亮 / 压暗，
  /// 换主色时要跟着重算，否则会出现渐变和相邻主色块撞色的接缝。
  static const LinearGradient activeWalk = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF8A6FEC), Color(0xFF6646D8)],
  );
}

/// 保留系统字体，让中文与英文共享清晰的字号层级。
class AppText {
  AppText._();
  static const pageTitle = TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w700,
      color: AppColors.textPrimary,
      height: 1.3);
  static const hero = TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.w700,
      color: AppColors.textPrimary,
      height: 1.25);
  static const section = TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: AppColors.textPrimary,
      height: 1.4);
  static const body =
      TextStyle(fontSize: 14, color: AppColors.textPrimary, height: 1.45);
  static const caption =
      TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.4);
}
