/// 联系方式编辑（M5）。
///
/// 为什么值得单独做一个设置项：**走失协查卡片要靠它才有用**。
/// 一张没有联系方式的寻宠卡片，别人捡到宠物也不知道找谁。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../providers.dart';

Future<void> showContactSheet(BuildContext context, {required LocalUser user}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _ContactSheet(user: user),
  );
}

class _ContactSheet extends ConsumerStatefulWidget {
  const _ContactSheet({required this.user});

  final LocalUser user;

  @override
  ConsumerState<_ContactSheet> createState() => _ContactSheetState();
}

class _ContactSheetState extends ConsumerState<_ContactSheet> {
  late final TextEditingController _phone;
  late final TextEditingController _email;
  late final TextEditingController _wechat;
  late final TextEditingController _note;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _phone = TextEditingController(text: widget.user.phone ?? '');
    _email = TextEditingController(text: widget.user.email ?? '');
    _wechat = TextEditingController(text: widget.user.wechat ?? '');
    _note = TextEditingController(text: widget.user.contactNote ?? '');
  }

  @override
  void dispose() {
    for (final c in [_phone, _email, _wechat, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final loginIdentifiersLocked = widget.user.region != 'local';

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
                AppSpace.gapS,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      L.t('contact.title'),
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _saving ? null : _save,
                    child: Text(
                      L.t('contact.save'),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.page,
                AppSpace.gapM,
                AppSpace.page,
                AppSpace.gapXl,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    L.t('contact.hint'),
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.6,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AppSpace.gapL),
                  if (loginIdentifiersLocked) ...[
                    Text(L.t('contact.loginLocked'),
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                    const SizedBox(height: AppSpace.gapM),
                  ],
                  TextField(
                    controller: _phone,
                    readOnly: loginIdentifiersLocked,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      labelText: L.t('contact.phone'),
                      prefixIcon: const Icon(Icons.phone_outlined, size: 18),
                    ),
                  ),
                  const SizedBox(height: AppSpace.gapM),
                  TextField(
                    controller: _wechat,
                    decoration: InputDecoration(
                      labelText: L.t('contact.wechat'),
                      prefixIcon:
                          const Icon(Icons.chat_bubble_outline, size: 18),
                    ),
                  ),
                  const SizedBox(height: AppSpace.gapM),
                  TextField(
                    controller: _email,
                    readOnly: loginIdentifiersLocked,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: L.t('contact.email'),
                      prefixIcon: const Icon(Icons.mail_outline, size: 18),
                    ),
                  ),
                  const SizedBox(height: AppSpace.gapM),
                  TextField(
                    controller: _note,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: L.t('contact.note'),
                      hintText: L.t('contact.noteHint'),
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

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);

    String? orNull(TextEditingController c) {
      final v = c.text.trim();
      return v.isEmpty ? null : v;
    }

    final updated = widget.user.copyWith(
      phone: orNull(_phone),
      clearPhone: orNull(_phone) == null,
      email: orNull(_email),
      clearEmail: orNull(_email) == null,
      wechat: orNull(_wechat),
      clearWechat: orNull(_wechat) == null,
      contactNote: orNull(_note),
      clearContactNote: orNull(_note) == null,
    );

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    try {
      await ref.read(appActionsProvider).updateContact(
            user: widget.user,
            updated: updated,
          );
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text(L.t('contact.saved'))));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}
