/// 登录（M6）：手机号或邮箱 + 验证码。
///
/// 为什么不设密码：**验证码登录是更低成本的一条路**。宠物 App 的使用频率是
/// 「想起来才开」，密码一定会被忘。短信/邮件通道本来就要接（投递提醒也用得上），
/// 再加一套密码体系等于多一份要维护、要找回、要防撞库的东西。
///
/// 顺序上有讲究：登录成功后在 [AppActions.login] 里**先过户本地数据、
/// 再存会话、最后同步**。顺序错了会把本地已有的宠物挂到占位用户名下推上去。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n.dart';
import '../core/theme.dart';
import '../providers.dart';

Future<void> showAuthSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const _AuthSheet(),
  );
}

class _AuthSheet extends ConsumerStatefulWidget {
  const _AuthSheet();

  @override
  ConsumerState<_AuthSheet> createState() => _AuthSheetState();
}

class _AuthSheetState extends ConsumerState<_AuthSheet> {
  final TextEditingController _target = TextEditingController();
  final TextEditingController _code = TextEditingController();

  String _channel = 'sms';
  bool _sending = false;
  bool _submitting = false;
  String? _targetError;
  String? _codeError;
  String? _devCode;

  /// 重发倒计时。服务端也有限流（60 秒），这里只是别让用户白点。
  int _cooldown = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _target.dispose();
    _code.dispose();
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
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      L.t('auth.title'),
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.gapS),
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
                    L.t('auth.why'),
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.6,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AppSpace.gapL),

                  // 通道切换：手机号 / 邮箱
                  Row(
                    children: [
                      for (final c in const ['sms', 'email'])
                        Padding(
                          padding: const EdgeInsets.only(right: AppSpace.gapS),
                          child: ChoiceChip(
                            label: Text(L.t('auth.channel.$c')),
                            selected: _channel == c,
                            onSelected: (_) => setState(() {
                              _channel = c;
                              _devCode = null;
                              _targetError = null;
                            }),
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
                      labelText: _channel == 'sms'
                          ? L.t('auth.target.phone')
                          : L.t('auth.target.email'),
                      errorText: _targetError,
                      prefixIcon: Icon(
                        _channel == 'sms'
                            ? Icons.phone_outlined
                            : Icons.mail_outline,
                        size: 18,
                      ),
                      suffixIcon: TextButton(
                        onPressed: (_sending || _cooldown > 0) ? null : _sendCode,
                        child: Text(
                          _cooldown > 0
                              ? L.tp('auth.resendIn', {'n': _cooldown})
                              : L.t('auth.sendCode'),
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ),
                  ),

                  if (_devCode != null) ...[
                    const SizedBox(height: AppSpace.gapS),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(AppSpace.gapM),
                      decoration: BoxDecoration(
                        color: AppColors.warningBg,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        L.tp('auth.devCode', {'code': _devCode}),
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: AppColors.warning,
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: AppSpace.gapM),
                  TextField(
                    controller: _code,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: L.t('auth.code'),
                      hintText: L.t('auth.codeHint'),
                      errorText: _codeError,
                      counterText: '',
                      prefixIcon: const Icon(Icons.password_rounded, size: 18),
                    ),
                  ),

                  const SizedBox(height: AppSpace.gapL),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _submitting ? null : _submit,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 46),
                      ),
                      child: _submitting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(L.t('auth.submit')),
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

  String? _validatedTarget() {
    final v = _target.text.trim();
    if (v.isEmpty) {
      setState(() => _targetError = L.t('auth.target.required'));
      return null;
    }
    // 只做最轻的形态检查，真正的校验在服务端（客户端校验挡不住任何人）。
    if (_channel == 'email' && !v.contains('@')) {
      setState(() => _targetError = L.t('auth.target.email'));
      return null;
    }
    setState(() => _targetError = null);
    return v;
  }

  Future<void> _sendCode() async {
    final target = _validatedTarget();
    if (target == null) return;

    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await ref.read(appActionsProvider).requestLoginCode(
            channel: _channel,
            target: target,
          );
      if (!mounted) return;
      setState(() {
        _devCode = r.devCode;
        _cooldown = 60;
      });
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() => _cooldown = _cooldown > 0 ? _cooldown - 1 : 0);
        if (_cooldown == 0) t.cancel();
      });
      messenger.showSnackBar(SnackBar(content: Text(L.t('auth.sent'))));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(_friendly(e))));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _submit() async {
    final target = _validatedTarget();
    if (target == null) return;

    final code = _code.text.trim();
    if (code.length != 6) {
      setState(() => _codeError = L.t('auth.codeRequired'));
      return;
    }
    setState(() {
      _codeError = null;
      _submitting = true;
    });

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await ref.read(appActionsProvider).login(
            channel: _channel,
            target: target,
            code: code,
          );
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text(L.t('sync.done'))));
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      messenger.showSnackBar(SnackBar(content: Text(_friendly(e))));
    }
  }

  /// 把服务端的错误翻成人话。约定见 docs/同步协议.md 5.1。
  String _friendly(Object e) {
    final raw = e.toString();
    if (raw.contains('code expired')) return L.isZh ? '验证码过期了，重新获取' : 'Code expired';
    if (raw.contains('code mismatch')) return L.isZh ? '验证码不对' : 'Wrong code';
    if (raw.contains('too many')) return L.isZh ? '尝试太多次，重新获取' : 'Too many attempts';
    if (raw.contains('429')) return L.isZh ? '请求太频繁，等一会儿再试' : 'Too many requests';
    return L.t('auth.failed');
  }
}
