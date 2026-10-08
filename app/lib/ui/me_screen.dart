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
import 'package:package_info_plus/package_info_plus.dart';

import '../core/app_capabilities.dart';
import '../core/l10n.dart';
import '../core/region.dart';
import '../core/theme.dart';
import '../core/units.dart';
import '../data/models.dart';
import '../data/sync/sync_api.dart';
import '../providers.dart';
import 'auth_sheet.dart';
import 'contact_sheet.dart';
import 'feedback_page.dart';
import 'legal_page.dart';
import 'sheets.dart';
import 'update_flow.dart';
import 'widgets.dart';

/// 联系方式摘要：一行里把填过的都列出来，没填的跳过。
///
/// 不列「手机号：未填」这种 —— 那和「还没填联系方式」的空态重复了。
String _contactSummary(LocalUser user) => [
      if ((user.phone ?? '').trim().isNotEmpty) user.phone!.trim(),
      if ((user.wechat ?? '').trim().isNotEmpty)
        '${L.t('contact.wechat')} ${user.wechat!.trim()}',
      if ((user.email ?? '').trim().isNotEmpty) user.email!.trim(),
      if ((user.contactNote ?? '').trim().isNotEmpty) user.contactNote!.trim(),
    ].join(' · ');

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
        AppSpace.pageBottom,
      ),
      children: [
        _PageTitle(L.t('me.title')),
        const SizedBox(height: AppSpace.gapL),

        // ---- 我的宠物 ----
        _Card(
          title: L.t('me.section.pets'),
          icon: Icons.pets_rounded,
          trailing: Text(L.isZh ? '共 ${pets.length} 只' : '${pets.length}',
              style: AppText.caption),
          children: [
            const RowDivider(),
            // 「添加宠物」的**常驻入口**。
            //
            // 为什么必须放在这：这个按钮原先只在「今天」页底部出现，且带
            // `pets.length > 1` 的条件；另外三个入口全在**空态**里（没有
            // 宠物时才渲染）。于是「只有一只宠物」的用户在全 App 都找不到
            // 加第二只的地方 —— 两处条件把唯一的状态给漏了。
            // 放在这里与「共 N 只」同屏，语义最直接，且不随数量变化。
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => showAddPetSheet(context, ref),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(L.t('addPet.title')),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, AppSpace.tapTarget),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.gapM),

        if (region.requiresIcpDisplay) ...[
          _CompactEntryCard(
              title: L.t('me.build.icp'),
              icon: Icons.verified_outlined,
              detail: L.t('me.icp')),
        ],

        const SizedBox(height: AppSpace.gapM),

        // ---- 账号与同步（M6）。
        // 放在联系方式之上：没登录的话，走失卡片、共养都用不起来，
        // 它才是这个页面第一件该处理的事。 ----
        const _AccountCard(),
        const SizedBox(height: AppSpace.gapM),
        const _InvitesCard(),

        // ---- 联系方式（M5）。走失协查卡片要靠它，所以放在「我的」而不是
        // 藏在某个二级设置页里。 ----
        Consumer(builder: (context, ref, _) {
          final user = ref.watch(currentUserProvider).valueOrNull;
          final has = user?.hasContact ?? false;
          return _CompactEntryCard(
              title: L.t('contact.title'),
              icon: Icons.contact_phone_outlined,
              detail: has ? _contactSummary(user!) : L.t('contact.empty'),
              trailing: const Icon(Icons.chevron_right_rounded,
                  size: 18, color: AppColors.textTertiary),
              onTap: user == null
                  ? null
                  : () => showContactSheet(context, user: user));
        }),

        const SizedBox(height: AppSpace.gapM),
        _Card(
          title: L.t('me.about'),
          icon: Icons.info_outline_rounded,
          children: [
            // 版本号从构建产物读，不硬编码 —— 硬编码的那份迟早和 pubspec 对不上，
            // 而「我到底装的是哪版」正是排查更新问题的第一句话。
            //
            // ⚠️ **正式包也显示 build 号**（原先只有开发构建才显示）。
            //
            // 原来的理由是「括号里那个数字给系统比版本用，用户看了只会困惑」。
            // 这个理由在**侧载/内测场景下站不住**：同一个版本名会对应很多个包
            // （0.1.8 就有 +9 到 +13 五份），而「你装的是哪一版」恰恰是排查
            // 问题的第一句话。
            //
            // 这不是假设 —— 2026-10-07 那天用户报「看不到删除宠物」，
            // 我先花了很多时间从代码里推断原因，最后发现真正的问题是他装的
            // 是旧包。如果界面上当时就写着 `v0.1.8 (11)`，那句「你看一下
            // 我页面的版本号」十秒钟就能定位。
            //
            // 显示 build 号的代价只是多几个字符，收益是少一次误判。
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (_, snapshot) {
                final info = snapshot.data;
                final text = info == null
                    ? '—'
                    : 'v${info.version} (${info.buildNumber})';
                return InfoRow(L.t('me.version'), text);
              },
            ),
            const RowDivider(),
            _LinkRow(
              icon: Icons.feedback_outlined,
              label: L.t('me.feedback'),
              onTap: () => showFeedbackSheet(context),
            ),
            const RowDivider(),
            _LinkRow(
              icon: Icons.privacy_tip_outlined,
              label: L.t('me.privacy'),
              onTap: () => showLegalPage(context, LegalDoc.privacy),
            ),
            const RowDivider(),
            _LinkRow(
              icon: Icons.description_outlined,
              label: L.t('me.terms'),
              onTap: () => showLegalPage(context, LegalDoc.terms),
            ),
            if (AppCapabilities.current.supports(AppFeature.apkUpdates)) ...[
              const RowDivider(),
              InkWell(
                onTap: () => runUpdateCheck(context, interactive: true),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Row(
                    children: [
                      const Icon(Icons.system_update_alt_rounded,
                          size: 18, color: AppColors.primary),
                      const SizedBox(width: AppSpace.gapM),
                      Expanded(
                        child: Text(
                          L.t('update.check'),
                          style: const TextStyle(
                            fontSize: 13.5,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded,
                          size: 18, color: AppColors.textTertiary),
                    ],
                  ),
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.only(
                  top: AppSpace.gapS, bottom: AppSpace.gapS),
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

        // ---- 双市场诊断面板（仅 debug）。改 flavor 后这几行必须跟着变。
        // release 包里整个消失，正式用户不会看到开发自检信息。 ----
        if (kDebugMode) ...[
          const SizedBox(height: AppSpace.gapM),
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
              InfoRow(
                  L.t('me.build.geocoder'), 'vendor:${region.geocoderVendor}'),
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
                '${Units.defaultWeightUnit(region).name} / '
                '${Units.defaultDistanceUnit(region).name}',
              ),
            ],
          ),
          const SizedBox(height: AppSpace.gapM),
        ],

        // 页脚版本号已移到上面的「关于」卡片里，与「检查更新」放一起 ——
        // 「我装的是哪版」和「有没有新版」本来是同一个问题。
      ],
    );
  }
}

// ------------------------------------------------------------------ 小组件

/// 账号与同步状态。
///
/// 这里承担三件事，顺序就是用户会关心的顺序：
/// 1. 登没登录（没登录时一切同步都是空谈）
/// 2. 上次同步是什么时候、还有多少没上去
/// 3. 立即同步 / 退出登录
class _AccountCard extends ConsumerWidget {
  const _AccountCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncControllerProvider);
    final user = ref.watch(currentUserProvider).valueOrNull;
    final controller = ref.read(syncControllerProvider.notifier);

    if (!status.loggedIn) {
      return _CompactEntryCard(
          title: L.t('sync.title'),
          icon: Icons.sync_rounded,
          status: L.t('auth.notLoggedIn'),
          detail: L.t('auth.notLoggedInHint'),
          trailing: FilledButton(
              onPressed: () => showAuthSheet(context),
              style: FilledButton.styleFrom(
                  minimumSize: const Size(0, AppSpace.tapTarget),
                  padding: const EdgeInsets.symmetric(horizontal: 12)),
              child: Text(L.t('auth.title'))));
    }
    return _Card(
      title: L.t('sync.title'),
      icon: Icons.sync_rounded,
      children: [
        if (!status.loggedIn) ...[
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        L.t('auth.notLoggedIn'),
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        L.t('auth.notLoggedInHint'),
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpace.gapM),
                FilledButton(
                  onPressed: () => showAuthSheet(context),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 38),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  child: Text(L.t('auth.title')),
                ),
              ],
            ),
          ),
        ] else ...[
          InfoRow(
            L.t('auth.account'),
            (user?.nickname ?? '').trim().isEmpty ? '—' : user!.nickname,
          ),
          const RowDivider(),
          InfoRow(L.t('sync.title'), _syncSummary(status)),
          if (status.message != null) ...[
            const RowDivider(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                status.message!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.danger,
                ),
              ),
            ),
          ],
          const SizedBox(height: AppSpace.gapS),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: status.syncing ? null : controller.runSync,
                  icon: status.syncing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync_rounded, size: 17),
                  label: Text(L.t('sync.now')),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    side: const BorderSide(color: AppColors.border),
                    minimumSize: const Size(0, 40),
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.gapM),
              TextButton(
                onPressed: status.syncing
                    ? null
                    : () => _confirmLogout(context, ref, controller),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.textSecondary,
                ),
                child: Text(L.t('auth.logout')),
              ),
            ],
          ),
        ],
      ],
    );
  }

  static String _syncSummary(SyncStatus s) {
    final parts = <String>[
      if (s.syncing)
        L.t('sync.syncing')
      else if (s.lastSyncAt == null)
        L.t('sync.never')
      else
        L.tp('sync.lastAt', {'time': compactDateTime(s.lastSyncAt!)}),
      if (s.pending > 0) L.tp('sync.pending', {'n': s.pending}),
      if (!s.syncing && s.pending == 0 && s.lastSyncAt != null)
        L.t('sync.upToDate'),
    ];
    return parts.join(' · ');
  }

  Future<void> _confirmLogout(
    BuildContext context,
    WidgetRef ref,
    SyncController controller,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t('auth.logoutConfirm')),
        content: Text(L.t('auth.logoutHint')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L.t('action.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L.t('auth.logout')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // 引擎侧撤令牌 + 本地动作层清理，两件事都要做，顺序无所谓。
    await ref.read(appActionsProvider).logout();
    await controller.refresh();
  }
}

/// 我收到的共养邀请。登录后才有内容，没内容就整块不出现。
class _InvitesCard extends ConsumerWidget {
  const _InvitesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(syncControllerProvider).loggedIn) {
      return const SizedBox.shrink();
    }
    final invites = ref.watch(myInvitesProvider).valueOrNull ?? const [];
    if (invites.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.gapM),
      child: _Card(
        title: L.t('members.invites.title'),
        icon: Icons.mark_email_unread_outlined,
        children: [
          for (var i = 0; i < invites.length; i++) ...[
            if (i > 0) const RowDivider(),
            _InviteRow(invite: invites[i]),
          ],
        ],
      ),
    );
  }
}

class _InviteRow extends ConsumerStatefulWidget {
  const _InviteRow({required this.invite});

  final RemoteInvite invite;

  @override
  ConsumerState<_InviteRow> createState() => _InviteRowState();
}

class _InviteRowState extends ConsumerState<_InviteRow> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final invite = widget.invite;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.pets_rounded, size: 18, color: AppColors.primary),
          const SizedBox(width: AppSpace.gapM),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  invite.petName ?? invite.petId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  L.t('members.role.${invite.role}'),
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.gapM),
          FilledButton(
            onPressed: _busy ? null : _accept,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              textStyle: const TextStyle(fontSize: 13),
            ),
            child: Text(L.t('members.invites.accept')),
          ),
        ],
      ),
    );
  }

  Future<void> _accept() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(appActionsProvider).acceptInvite(widget.invite.inviteId);
      messenger.showSnackBar(
        SnackBar(content: Text(L.t('members.invites.accepted'))),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// 可点击的一行（图标 + 文案 + 右箭头）。关于卡里连着四个入口，
/// 每处各写一遍 InkWell 太啰嗦。
class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            children: [
              Icon(icon, size: 18, color: AppColors.primary),
              const SizedBox(width: AppSpace.gapM),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13.5,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  size: 18, color: AppColors.textTertiary),
            ],
          ),
        ),
      );
}

class _PageTitle extends StatelessWidget {
  const _PageTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: AppText.pageTitle,
      );
}

/// 标题 + 内容的白卡片。所有分组都是这个形状，避免每个区块各写一套。
class _Card extends StatelessWidget {
  const _Card({
    required this.title,
    required this.icon,
    required this.children,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.gapM,
          10,
          AppSpace.gapM,
          AppSpace.gapS,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 17, color: AppColors.primary),
                const SizedBox(width: AppSpace.gapS),
                Expanded(
                    child: Row(children: [
                  Flexible(child: Text(title, style: AppText.section)),
                  if (trailing != null) ...[const SizedBox(width: 8), trailing!]
                ])),
              ],
            ),
            const SizedBox(height: 6),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _CompactEntryCard extends StatelessWidget {
  const _CompactEntryCard(
      {required this.title,
      required this.icon,
      required this.detail,
      this.status,
      this.trailing,
      this.onTap});
  final String title;
  final IconData icon;
  final String detail;
  final String? status;
  final Widget? trailing;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Icon(icon, size: 20, color: AppColors.primary),
            const SizedBox(width: 10),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(title, style: AppText.section),
                        if (status != null)
                          Text(status!, style: AppText.caption),
                      ]),
                  const SizedBox(height: 4),
                  Text(detail, style: AppText.caption),
                ])),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          ]),
        ),
      ));
}
