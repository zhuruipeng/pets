/// 登录：默认「手机号/邮箱 + 密码」，验证码作为兜底。
///
/// 为什么密码为主：老板实测「每次登录都要等短信」太烦，改为密码登录为主，
/// 验证码保留给「忘记密码 / 没设过密码」的兜底路径。密码是宠物域本地凭据，
/// 与官网统一账号无关（官网本身没有密码）。
///
/// 顺序上有讲究：登录成功后在 [AppActions.login] / [AppActions.loginWithPassword]
/// 里**先过户本地数据、再存会话、最后同步**。顺序错了会把本地已有的宠物
/// 挂到占位用户名下推上去。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n.dart';
import '../core/theme.dart';
import '../data/sync/unified_api.dart';
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
  final TextEditingController _password = TextEditingController();

  String _channel = 'sms';

  /// 'password'（默认）或 'code'。
  String _mode = 'password';

  bool _sending = false;
  bool _submitting = false;
  String? _targetError;
  String? _codeError;
  String? _passwordError;
  String? _devCode;

  /// 表单级错误（登录/发码失败）。**必须显示在这个 sheet 内部**。
  ///
  /// 为什么不能用 SnackBar：`ScaffoldMessenger.of(context)` 在 modal bottom
  /// sheet 里拿到的是根 Scaffold 的 messenger，SnackBar 显示在屏幕**最底部**，
  /// 而这个登录框本身就盖在底部 —— 于是错误整条被挡住。实测事故：官网返回
  /// 400「验证码不存在或已使用」，用户连点 13 次登录，屏幕上什么都没出现，
  /// 以为「点了没反应」。成功路径看不到这个问题（成功会先 pop 掉 sheet，
  /// SnackBar 才露出来），所以只有失败路径会翻车。
  String? _formError;

  /// 重发倒计时。服务端也有限流（60 秒），这里只是别让用户白点。
  int _cooldown = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _target.dispose();
    _code.dispose();
    _password.dispose();
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

                  // 通道切换：手机号 / 邮箱（仅 intl 区显示，cn 只有手机号）。
                  if (_channels.length > 1) ...[
                    Row(
                      children: [
                        for (final c in _channels)
                          Padding(
                            padding: const EdgeInsets.only(right: AppSpace.gapS),
                            child: ChoiceChip(
                              label: Text(L.t('auth.channel.$c')),
                              selected: _channel == c,
                              onSelected: (_) => setState(() {
                                _channel = c;
                                _devCode = null;
                                _targetError = null;
                                _formError = null;
                              }),
                              showCheckmark: false,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpace.gapM),
                  ] else ...[
                    Text(
                      L.t('auth.unifiedHint'),
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.6,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: AppSpace.gapM),
                  ],

                  // 账号输入：手机号 / 邮箱。
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
                      // 验证码模式下，账号框右侧挂「获取验证码」。
                      suffixIcon: _mode == 'code'
                          ? TextButton(
                              onPressed: (_sending || _cooldown > 0)
                                  ? null
                                  : _sendCode,
                              child: Text(
                                _cooldown > 0
                                    ? L.tp('auth.resendIn', {'n': _cooldown})
                                    : L.t('auth.sendCode'),
                                style: const TextStyle(fontSize: 12.5),
                              ),
                            )
                          : null,
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

                  if (_mode == 'code')
                    // 验证码输入框。
                    TextField(
                      controller: _code,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      decoration: InputDecoration(
                        labelText: L.t('auth.code'),
                        hintText: L.t('auth.codeHint'),
                        errorText: _codeError,
                        counterText: '',
                        prefixIcon:
                            const Icon(Icons.password_rounded, size: 18),
                      ),
                    )
                  else ...[
                    // 密码输入框。
                    TextField(
                      controller: _password,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: L.t('auth.password'),
                        hintText: L.t('auth.passwordHint'),
                        errorText: _passwordError,
                        prefixIcon: const Icon(Icons.lock_outline, size: 18),
                      ),
                      onSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: AppSpace.gapS),
                    // 忘记密码 → 切验证码兜底。
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => setState(() {
                          _mode = 'code';
                          _formError = null;
                        }),
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 28),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          L.t('auth.forgotPassword'),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ],

                  // 表单级错误显示在按钮上方 —— **不能靠 SnackBar**，
                  // 它会被这个底部弹窗整个盖住（见 _formError 的注释）。
                  if (_formError != null) ...[
                    const SizedBox(height: AppSpace.gapM),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(AppSpace.gapM),
                      decoration: BoxDecoration(
                        color: AppColors.dangerBg,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _formError!,
                        style: const TextStyle(
                          fontSize: 12.5,
                          height: 1.5,
                          color: AppColors.danger,
                        ),
                      ),
                    ),
                  ],

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

                  const SizedBox(height: AppSpace.gapS),
                  // 主登录方式切换：密码 ⇄ 验证码。
                  Center(
                    child: TextButton(
                      onPressed: _submitting
                          ? null
                          : () => setState(() {
                                _mode =
                                    _mode == 'password' ? 'code' : 'password';
                                _passwordError = null;
                                _codeError = null;
                                _formError = null;
                              }),
                      child: Text(
                        _mode == 'password'
                            ? L.t('auth.switchToCode')
                            : L.t('auth.switchToPassword'),
                        style: const TextStyle(fontSize: 13),
                      ),
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

  /// 本区域可用的登录通道。
  ///
  /// 中国区只有手机号：登录走官网统一账号（与官网 ERP / 商城同一个手机号），
  /// 官网那边只有手机号这一种凭据。海外区仍保留邮箱兜底 —— 那边没有出岫账号，
  /// 而且国际短信成本高、到达率不稳。
  List<String> get _channels =>
      UnifiedAccountApi.isAvailable ? const ['sms'] : const ['sms', 'email'];

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
        _formError = null;
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
      setState(() => _formError = _friendly(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _submit() async {
    final target = _validatedTarget();
    if (target == null) return;

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    // 新一次尝试：清掉上一次的错误，免得旧错误一直挂在那里误导人。
    if (_formError != null) setState(() => _formError = null);

    if (_mode == 'password') {
      // 密码登录。
      final password = _password.text;
      if (password.length < 6) {
        setState(() => _passwordError = L.t('auth.passwordTooShort'));
        return;
      }
      setState(() {
        _passwordError = null;
        _submitting = true;
      });
      try {
        await ref.read(appActionsProvider).loginWithPassword(
              channel: _channel,
              target: target,
              password: password,
            );
        if (!mounted) return;
        navigator.pop();
        messenger.showSnackBar(SnackBar(content: Text(L.t('sync.done'))));
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _submitting = false;
          _formError = _friendly(e);
        });
      }
      return;
    }

    // 验证码登录。
    final code = _code.text.trim();
    if (code.length != 6) {
      setState(() => _codeError = L.t('auth.codeRequired'));
      return;
    }
    setState(() {
      _codeError = null;
      _submitting = true;
    });

    try {
      await ref.read(appActionsProvider).login(
            channel: _channel,
            target: target,
            code: code,
          );
      if (!mounted) return;
      // 先引导设密码（盖在登录 sheet 上，context 始终有效），引导关闭后
      // 再一起关掉登录 sheet，避免 pop 之后 context 失效。
      final shouldSet = await _promptSetPassword();
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text(L.t('sync.done'))));
      if (shouldSet) {
        messenger.showSnackBar(SnackBar(content: Text(L.t('auth.setPassword.done'))));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _formError = _friendly(e);
      });
    }
  }

  /// 验证码登录成功后，引导设一个密码（下次就能密码登录）。可跳过。
  /// 返回是否成功设置了密码。
  Future<bool> _promptSetPassword() async {
    final actions = ref.read(appActionsProvider);
    final passwordController = TextEditingController();
    final confirmController = TextEditingController();

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetCtx) {
        var saving = false;
        String? error;
        return StatefulBuilder(
          builder: (ctx, setSheetState) => Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: SingleChildScrollView(
              child: Padding(
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
                    Text(
                      L.t('auth.setPassword.title'),
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: AppSpace.gapS),
                    Text(
                      L.t('auth.setPassword.hint'),
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.6,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: AppSpace.gapL),
                    TextField(
                      controller: passwordController,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: L.t('auth.setPassword.placeholder'),
                        errorText: error,
                        prefixIcon:
                            const Icon(Icons.lock_outline, size: 18),
                      ),
                    ),
                    const SizedBox(height: AppSpace.gapM),
                    TextField(
                      controller: confirmController,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: L.t('auth.setPassword.confirm'),
                        prefixIcon:
                            const Icon(Icons.lock_outline, size: 18),
                      ),
                    ),
                    const SizedBox(height: AppSpace.gapL),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: saving
                            ? null
                            : () async {
                                final p = passwordController.text;
                                final c = confirmController.text;
                                if (p.length < 6) {
                                  setSheetState(() =>
                                      error = L.t('auth.passwordTooShort'));
                                  return;
                                }
                                if (p != c) {
                                  setSheetState(() =>
                                      error = L.t('auth.setPassword.mismatch'));
                                  return;
                                }
                                setSheetState(() {
                                  saving = true;
                                  error = null;
                                });
                                try {
                                  await actions.setPassword(p);
                                  if (!ctx.mounted) return;
                                  Navigator.of(ctx).pop(true);
                                } catch (_) {
                                  if (!ctx.mounted) return;
                                  setSheetState(() {
                                    saving = false;
                                    error = L.t('auth.failed');
                                  });
                                }
                              },
                        child: saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(L.t('auth.setPassword.save')),
                      ),
                    ),
                    const SizedBox(height: AppSpace.gapS),
                    SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        onPressed: saving
                            ? null
                            : () => Navigator.of(ctx).pop(false),
                        child: Text(L.t('auth.setPassword.skip')),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    passwordController.dispose();
    confirmController.dispose();
    return saved ?? false;
  }

  /// 把服务端的错误翻成人话。约定见 docs/同步协议.md 5.1。
  ///
  /// cn 区走官网统一账号，官网返回的是**中文** detail（如「验证码不存在或
  /// 已使用」）。这类文案本来就是写给用户看的，能透就透；只对需要补充
  /// 「下一步怎么办」的做改写。
  String _friendly(Object e) {
    final raw = e.toString();

    if (raw.contains('验证码不存在或已使用') || raw.contains('验证码已使用')) {
      return L.isZh
          ? '验证码不对或已经用过，请重新获取'
          : 'Code is wrong or already used — request a new one.';
    }
    if (raw.contains('验证码已过期') || raw.contains('code expired')) {
      return L.isZh ? '验证码过期了，重新获取' : 'Code expired';
    }
    if (raw.contains('验证码错误') || raw.contains('code mismatch')) {
      return L.isZh ? '验证码不对' : 'Wrong code';
    }
    if (raw.contains('too many') || raw.contains('429')) {
      return L.isZh ? '请求太频繁，等一会儿再试' : 'Too many requests';
    }
    if (raw.contains('invalid phone/email or password') ||
        raw.contains('401')) {
      return L.t('auth.passwordFailed');
    }

    // 兜底：把服务端说的原话透出来（比笼统的「登录失败，请重试」有用）。
    final detail = _extractDetail(raw);
    if (detail != null) return detail;
    return L.t('auth.failed');
  }

  /// 从异常串里抠出服务端的原始 detail。
  ///
  /// `SyncApiException(400): 验证码不存在或已使用` → `验证码不存在或已使用`。
  /// 只透出**含中文**的 detail：那说明它是写给用户看的；纯英文的
  /// （`SocketException: ...` / `DioError` …）是技术噪音，不该甩给用户。
  static String? _extractDetail(String raw) {
    final i = raw.indexOf('): ');
    if (i < 0) return null;
    final s = raw.substring(i + 3).trim();
    if (s.isEmpty) return null;
    return s.contains(RegExp(r'[\u4e00-\u9fa5]')) ? s : null;
  }
}
