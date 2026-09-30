/// 共养成员管理（M6）：查看成员 / 邀请 / 移除。
///
/// 一条硬规则：**共养必须有账号**。没有账号就没有 user_id，也就没有
/// 「谁是谁」可言 —— 所以未登录时这个弹层只给一个登录入口，
/// 不做「本地假共养」（那种数据一登录就会变成孤儿）。
///
/// 清单来源：登录后以**服务端为准**（`GET /pets/{id}/members`），
/// 因为服务端知道昵称，而本地 members 表只有 user_id。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../data/sync/sync_api.dart';
import '../data/sync/sync_engine.dart';
import '../providers.dart';
import 'auth_sheet.dart';
import 'widgets.dart';

/// 某只宠物的成员（服务端视图）。未登录时返回空。
final petMembersRemoteProvider =
    FutureProvider.family<List<RemoteMember>, String>((ref, petId) async {
  final token = await ref.read(syncEngineProvider).token();
  if (token == null) return const <RemoteMember>[];
  return ref.read(syncApiProvider).members(token, petId);
});

Future<void> showMembersSheet(BuildContext context, {required Pet pet}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _MembersSheet(pet: pet),
  );
}

class _MembersSheet extends ConsumerWidget {
  const _MembersSheet({required this.pet});

  final Pet pet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncControllerProvider);
    final members = ref.watch(petMembersRemoteProvider(pet.id));

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.page,
        AppSpace.gapL,
        AppSpace.page,
        AppSpace.gapXl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  L.t('profile.section.family'),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              if (status.loggedIn)
                TextButton.icon(
                  onPressed: () => showInviteMemberSheet(context, pet: pet),
                  icon: const Icon(Icons.person_add_alt_1_rounded, size: 17),
                  label: Text(L.t('members.invite')),
                ),
            ],
          ),
          const SizedBox(height: AppSpace.gapS),

          if (!status.loggedIn)
            _NeedLogin(hasMessage: status.phase == SyncPhase.notLoggedIn)
          else
            members.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(AppSpace.gapXl),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => _ErrorBox(message: '$e'),
              data: (list) {
                if (list.isEmpty) {
                  return Text(
                    L.t('members.inviteHint'),
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.6,
                      color: AppColors.textSecondary,
                    ),
                  );
                }
                return Column(
                  children: [
                    for (var i = 0; i < list.length; i++) ...[
                      if (i > 0) const RowDivider(),
                      _MemberRow(petId: pet.id, member: list[i]),
                    ],
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

/// 角色单选项。
///
/// 不用 `RadioListTile`：它的 `groupValue` / `onChanged` 在当前 Flutter 里
/// 已经废弃（要求改用 `RadioGroup` 祖先），而 `RadioGroup` 在旧版本里又不存在
/// —— 引它就得把版本下限拉高。自己画一行 InkWell 两端都兼容，
/// 顺带能控制选中态的配色，和 App 里其它选择器也统一。
class _RoleOption extends StatelessWidget {
  const _RoleOption({
    required this.role,
    required this.selected,
    required this.onTap,
  });

  final String role;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.tile),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              size: 19,
              color: selected ? AppColors.primary : AppColors.textTertiary,
            ),
            const SizedBox(width: AppSpace.gapM),
            Expanded(
              child: Text(
                L.t('members.role.$role'),
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 请求失败时的提示块。原始异常串直接摆出来对用户没有意义，
/// 所以上面配一句人话，下面用小字附上详情（排查时要看）。
class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpace.gapL),
      decoration: BoxDecoration(
        color: AppColors.dangerBg,
        borderRadius: AppRadius.cardBorder,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.cloud_off_rounded,
                  size: 17, color: AppColors.danger),
              const SizedBox(width: AppSpace.gapS),
              Expanded(
                child: Text(
                  L.t('members.loadFailed'),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.danger,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            message,
            style: const TextStyle(
              fontSize: 11.5,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 未登录：给一个明确的入口，不摆一堆不能用的按钮。
class _NeedLogin extends StatelessWidget {
  const _NeedLogin({required this.hasMessage});

  final bool hasMessage;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          hasMessage ? L.t('members.needLogin') : L.t('auth.notLoggedInHint'),
          style: const TextStyle(
            fontSize: 12.5,
            height: 1.6,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: AppSpace.gapM),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => showAuthSheet(context),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            child: Text(L.t('auth.title')),
          ),
        ),
      ],
    );
  }
}

class _MemberRow extends ConsumerStatefulWidget {
  const _MemberRow({required this.petId, required this.member});

  final String petId;
  final RemoteMember member;

  @override
  ConsumerState<_MemberRow> createState() => _MemberRowState();
}

class _MemberRowState extends ConsumerState<_MemberRow> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.member;
    final pending = m.status == 'pending';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(
              color: AppColors.primaryLight,
              shape: BoxShape.circle,
            ),
            child: Icon(
              m.role == 'owner' ? Icons.star_rounded : Icons.person_rounded,
              size: 18,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(width: AppSpace.gapM),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        m.isMe
                            ? '${m.nickname ?? ''} (${L.t('members.me')})'.trim()
                            : (m.nickname ?? m.userId),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    if (pending) ...[
                      const SizedBox(width: 6),
                      SoftTag(
                        L.t('members.status.pending'),
                        color: AppColors.warning,
                        bg: AppColors.warningBg,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  L.t('members.role.${m.role}'),
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          // 主人不能被移除（服务端也会拒），所以不给自己那行摆删除按钮。
          if (m.role != 'owner' && !m.isMe)
            IconButton(
              tooltip: L.t('members.remove'),
              onPressed: _busy ? null : _remove,
              icon: const Icon(Icons.person_remove_outlined,
                  size: 18, color: AppColors.textSecondary),
            ),
        ],
      ),
    );
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.tp('members.removeConfirm', {
          'name': widget.member.nickname ?? widget.member.userId,
        })),
        content: Text(L.t('members.removeHint')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L.t('action.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text(L.t('members.remove')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(appActionsProvider)
          .removeMember(widget.petId, widget.member.userId);
      ref.invalidate(petMembersRemoteProvider(widget.petId));
      messenger.showSnackBar(SnackBar(content: Text(L.t('members.removed'))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

// ------------------------------------------------------------------ 邀请

Future<void> showInviteMemberSheet(BuildContext context, {required Pet pet}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _InviteSheet(pet: pet),
  );
}

class _InviteSheet extends ConsumerStatefulWidget {
  const _InviteSheet({required this.pet});

  final Pet pet;

  @override
  ConsumerState<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends ConsumerState<_InviteSheet> {
  final TextEditingController _target = TextEditingController();

  String _channel = 'sms';
  String _role = 'editor';
  bool _sending = false;

  @override
  void dispose() {
    _target.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.page,
                0,
                AppSpace.page,
                AppSpace.gapXl,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    L.t('members.invite'),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: AppSpace.gapS),
                  Text(
                    L.t('members.inviteHint'),
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.6,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AppSpace.gapL),

                  Row(
                    children: [
                      for (final c in const ['sms', 'email'])
                        Padding(
                          padding: const EdgeInsets.only(right: AppSpace.gapS),
                          child: ChoiceChip(
                            label: Text(L.t('auth.channel.$c')),
                            selected: _channel == c,
                            onSelected: (_) => setState(() => _channel = c),
                            showCheckmark: false,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.gapM),

                  TextField(
                    controller: _target,
                    keyboardType: _channel == 'sms'
                        ? TextInputType.phone
                        : TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: L.t('members.target'),
                      prefixIcon: Icon(
                        _channel == 'sms'
                            ? Icons.phone_outlined
                            : Icons.mail_outline,
                        size: 18,
                      ),
                    ),
                  ),

                  const SizedBox(height: AppSpace.gapL),
                  Text(
                    L.t('members.role'),
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AppSpace.gapS),
                  // 只给 editor / viewer：owner 是归属凭证，靠邀请再产生一个
                  // owner 会让「谁是主人」变成不可判定（服务端也这么校验）。
                  for (final r in const ['editor', 'viewer'])
                    _RoleOption(
                      role: r,
                      selected: _role == r,
                      onTap: () => setState(() => _role = r),
                    ),

                  const SizedBox(height: AppSpace.gapM),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _sending ? null : _send,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 46),
                      ),
                      child: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(L.t('members.invite')),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _send() async {
    final target = _target.text.trim();
    if (target.isEmpty) return;

    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await ref.read(appActionsProvider).inviteMember(
            petId: widget.pet.id,
            channel: _channel,
            target: target,
            role: _role,
          );
      ref.invalidate(petMembersRemoteProvider(widget.pet.id));
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(content: Text(L.t('members.invite.sent'))),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      // 「对方没注册」是最常见的失败，值得单独说清楚 ——
      // 否则用户会以为邀请成功了，等几天才发现对方根本没收到。
      final raw = e.toString();
      messenger.showSnackBar(SnackBar(
        content: Text(raw.contains('not registered')
            ? L.t('members.notRegistered')
            : (raw.contains('already') ? raw : L.t('members.invite.failed'))),
      ));
    }
  }
}
