/// 我的页 —— 设置入口 + Debug 诊断。
///
/// 「当前构建」自检面板只在 debug 构建出现（kDebugMode）：它回答的是
/// 「这个 flavor 的区域配置生效没有」，是开发验收工具，不是用户功能。
/// 正式用户看到的是：我的宠物 / 备案（cn）/ 关于 / 版本号。
/// 提交商店审核前务必用 release 包自检一遍，别把诊断页漏出去。
library;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n.dart';
import '../core/region.dart';
import '../core/theme.dart';
import '../core/units.dart';
import '../providers.dart';
import 'widgets.dart';

class MeScreen extends ConsumerWidget {
  const MeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const region = AppRegion.current;
    final pets = ref.watch(petsProvider).valueOrNull ?? const [];

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.page,
        AppSpace.gapS,
        AppSpace.page,
        96,
      ),
      children: [
        _PageTitle(L.t('me.title')),
        const SizedBox(height: AppSpace.gapL),

        // ---- 我的宠物 ----
        _Card(
          title: L.t('me.section.pets'),
          icon: Icons.pets_rounded,
          children: [
            InfoRow(
              L.t('me.section.pets'),
              L.isZh ? '共 ${pets.length} 只' : '${pets.length}',
            ),
          ],
        ),
        const SizedBox(height: AppSpace.gapM),

        // ---- 双市场诊断面板（仅 debug）。改 flavor 后这几行必须跟着变。
        // release 包里整个消失，正式用户不会看到开发自检信息。 ----
        if (kDebugMode) ...[
          _Card(
            title: L.t('me.build.title'),
            icon: Icons.tune_rounded,
            children: [
              // 值都加前缀，避免「区域 intl」和「免疫规则集 intl」看起来重复。
              InfoRow(L.t('me.build.region'), 'region:${region.name}'),
              InfoRow(L.t('me.build.api'), region.apiBaseUrl),
              InfoRow(
                L.t('me.build.map'),
                region.mapRenderingEnabled ? 'on' : 'off',
                valueColor: region.mapRenderingEnabled
                    ? AppColors.primary
                    : AppColors.textTertiary,
              ),
              InfoRow(L.t('me.build.geocoder'), 'vendor:${region.geocoderVendor}'),
              InfoRow(
                L.t('me.build.immunization'),
                'rules:${region.immunizationRuleSet}',
              ),
              InfoRow(
                L.t('me.build.icp'),
                region.requiresIcpDisplay ? 'required' : 'n/a',
              ),
              InfoRow(
                L.t('me.build.locale'),
                L.current == AppLang.zh ? 'zh' : 'en',
              ),
              InfoRow(
                L.t('me.build.units'),
                '${Units.defaultWeightUnit(region, region.name).name} / '
                    '${Units.defaultDistanceUnit(region, region.name).name}',
              ),
            ],
          ),
          const SizedBox(height: AppSpace.gapM),
        ],

        if (region.requiresIcpDisplay) ...[
          const SizedBox(height: AppSpace.gapM),
          _Card(
            title: L.t('me.build.icp'),
            icon: Icons.verified_outlined,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  L.t('me.icp'),
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ],

        const SizedBox(height: AppSpace.gapM),
        _Card(
          title: L.t('me.about'),
          icon: Icons.info_outline_rounded,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                L.t('me.about.body'),
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: AppSpace.gapXl),
        const Center(
          child: Text(
            'v0.1.0 · M1',
            style: TextStyle(fontSize: 11.5, color: AppColors.textTertiary),
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ 小组件

class _PageTitle extends StatelessWidget {
  const _PageTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
      );
}

/// 标题 + 内容的白卡片。所有分组都是这个形状，避免每个区块各写一套。
class _Card extends StatelessWidget {
  const _Card({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.gapL,
        AppSpace.gapM,
        AppSpace.gapL,
        AppSpace.gapS,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.cardBorder,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: AppColors.primary),
              const SizedBox(width: AppSpace.gapS),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.gapS),
          ...children,
        ],
      ),
    );
  }
}
