/// 底部弹层的公共积木。**新增弹层必须用这里的组件，不要自己写一份。**
///
/// 为什么单独开一个文件（2026-10-11 代码审查 P2 抽组件）：
///
/// 抽之前，「36×4 圆角横条 + 标题行 + Divider」这套骨架在 8 个文件里
/// 各写了一遍，`confirmDelete` 的 AlertDialog 在 7 个文件里各写了一遍，
/// `_p()` 补零函数 8 个文件各定义一遍。
///
/// **这不是洁癖问题，是有代价的**：P1-1 那个「海外区邀请默认选中必然失败
/// 的 sms 通道」bug，根因就是 `auth_sheet` 修过了、`members_sheet` 那份
/// 拷贝没同步改。重复代码的代价是「修一处漏一处」，而且漏的那处**不报错**，
/// 只表现为功能静默失效。
///
/// 抽出来之后：新增弹层从约 80 行缩到约 10 行；改键盘避让 / 大字体适配 /
/// 安全区只改这一个文件。
library;

import 'package:flutter/material.dart';

import '../core/l10n.dart';
import '../core/theme.dart';

// ------------------------------------------------------------------ 横条

/// 弹层顶部的小横条（拖拽指示器）。
///
/// 抽之前 `edit_pet_sheet` 与 `reminder_sheet` 里是**逐字相同**的
/// 私有 `_Handle`，另有两个文件把它内联在 build 里。
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 36,
          height: 4,
          margin: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.divider,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}

// ------------------------------------------------------------------ 骨架

/// 弹层的统一骨架：横条 + 标题行（可带右侧动作）+ Divider + 内容。
///
/// 三种形态由一个类覆盖（`scrollable` / `bodyController` 两个开关）：
///
/// | 形态 | 用法 | 现有例子 |
/// |---|---|---|
/// | 固定高度可拖拽 | `scrollable: false` + `bodyController` | 编辑宠物、新建提醒 |
/// | 内容自适应高度 | `scrollable: true`（默认） | 邀请成员、联系方式 |
///
/// **键盘避让是这里统一处理的**（`MediaQuery.viewInsets.bottom`）：
/// 抽之前每个弹层各写一遍，漏写的那个在键盘弹出时会被遮住输入框。
///
/// ⚠️ `showModalBottomSheet(isScrollControlled: true)` 仍要调用方自己传 ——
/// 它属于「打开方式」而不是「弹层内容」，关在这个组件里会让调用点看着像
/// 不需要设置，实际不设就会被键盘顶掉一半。
class SheetScaffold extends StatelessWidget {
  const SheetScaffold({
    super.key,
    required this.title,
    required this.child,
    this.action,
    this.scrollable = true,
    this.bodyController,
  });

  /// 标题（已本地化的字符串，不是 key）。
  final String title;

  /// 内容。`scrollable: false` 时它是 `Expanded` 的子节点，必须自己可滚动
  /// （用传进来的 [bodyController] 建 ListView）。
  final Widget child;

  /// 标题行右侧的动作，通常是「保存」。为 null 时标题独占整行。
  final Widget? action;

  /// true：整体套 `SingleChildScrollView`，高度由内容决定（适合短表单）。
  /// false：内容自己滚动，需要配合 [bodyController]（适合长表单/固定高度）。
  final bool scrollable;

  /// `scrollable: false` 时传给内容里那个 `ListView` 的 controller。
  ///
  /// 它来自 `DraggableScrollableSheet` 的 builder —— 不接的话拖拽手柄
  /// 与列表滚动会各走各的，用户拖不动内容。
  final ScrollController? bodyController;

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    final header = <Widget>[
      const SheetHandle(),
      Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpace.page,
          0,
          AppSpace.page,
          scrollable ? 0 : AppSpace.gapS,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            if (action != null) action!,
          ],
        ),
      ),
    ];

    // 两种形态的差异只在这里：
    // - scrollable：标题和内容一起滚（适合短弹层）
    // - 否则：标题固定、内容区自己滚（适合长弹层，滚动时标题不动）
    final Widget body;
    if (scrollable) {
      body = SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...header,
            const SizedBox(height: AppSpace.gapS),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.page,
                0,
                AppSpace.page,
                AppSpace.gapXl,
              ),
              child: child,
            ),
          ],
        ),
      );
    } else {
      body = Column(
        children: [
          ...header,
          const Divider(height: 1),
          Expanded(
            child: ListView(
              controller: bodyController,
              padding: const EdgeInsets.fromLTRB(
                AppSpace.page,
                AppSpace.gapL,
                AppSpace.page,
                AppSpace.gapXl,
              ),
              children: [child],
            ),
          ),
        ],
      );
    }

    // ⚠️ 键盘避让必须在这里做，且要**包在滚动容器外面**：
    // 包在里面的话，滚动区自己也在算避让高度，会出现「键盘弹出后能滚动的
    // 范围比实际内容多一截」的空白。
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: body,
    );
  }
}

// ------------------------------------------------------------------ 确认框

/// 危险操作的二次确认。返回 true 表示用户确认。
///
/// 抽之前 7 个文件各写一份 `showDialog<bool>` + `AlertDialog`，
/// 且**样式已经开始漂移**：有的用 `FilledButton`
/// （`FilledButton.styleFrom(backgroundColor: danger)`），有的用
/// `TextButton`（`TextButton.styleFrom(foregroundColor: danger)`）——
/// 同一个「删除」在不同页面长得不一样。
///
/// 统一成 `FilledButton` + 红底：破坏性操作要有视觉重量，
/// 靠「文字变红」的 TextButton 太轻，容易误触。
///
/// [hint] 是可选补充说明（比如「关联的记录也会一起删除」）。
/// 破坏性操作建议都传 —— 只说「确定删除吗」不告诉用户删掉什么，
/// 是最容易让人点错的一类确认框。
Future<bool> confirmDelete(
  BuildContext context, {
  required String title,
  String? hint,
  String? confirmLabel,
}) {
  return confirmAction(
    context,
    title: title,
    hint: hint,
    confirmLabel: confirmLabel ?? L.t('action.delete'),
    danger: true,
  );
}

/// 通用二次确认。返回 true 表示用户确认。
///
/// 和 [confirmDelete] 是同一个对话框，区别只在**确认键是不是红的**：
/// 删除 / 归档 / 退出登录这类不可逆或影响面大的动作传 `danger: true`，
/// 其余（比如「清空筛选」）保持默认的主色。
///
/// ⚠️ 不传 `danger` 不等于「不重要」—— 判断依据是「误点一次的代价有多大」。
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  String? hint,
  String? confirmLabel,
  bool danger = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: hint == null ? null : Text(hint),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(L.t('action.cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: danger
              ? FilledButton.styleFrom(backgroundColor: AppColors.danger)
              : null,
          child: Text(confirmLabel ?? L.t('action.delete')),
        ),
      ],
    ),
  );
  // 用户点遮罩/返回键关掉时是 null，与「点了取消」等价 —— 都不是确认。
  return ok ?? false;
}

// ------------------------------------------------------------------ 补零

/// 两位补零。`_p(7) == '07'`。
///
/// 抽之前在 **8 个文件**里各定义了一遍私有 `_p`。它小到容易觉得
/// 「复制一下比抽出去省事」，但正因为它出现在每一处日期/时间格式化里，
/// 8 份的实现**没有一份被测试覆盖** —— 抽出来之后 `compactDate` 等
/// 公共格式化函数才成为可测的单元。
String pad2(int v) => v.toString().padLeft(2, '0');

// ------------------------------------------------------------------ 错误提示

/// 把异常渲染成给用户看的文案。
///
/// 审查发现约 8 处写的是 `error: (e, _) => Text('$e')`，会把
/// `SocketException: Connection refused (OS Error: ...)` 原文甩在界面上。
/// 用户看不懂，而且暴露内部实现（有时候还带 URL）。
///
/// **统一走 `L.error(e)`** —— 它在 `l10n.dart` 里把异常映射成本地化文案。
Widget errorPlaceholder(Object error) => Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.page),
        child: Text(
          L.error(error),
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textSecondary),
        ),
      ),
    );

/// 弹出错误提示条。等价于 `errorPlaceholder` 的 SnackBar 版本。
///
/// 仓储层抛的异常在 UI 层直接用 `'$e'` 显示的地方约 8 处，
/// 统一走这里。
void showErrorSnack(BuildContext context, Object error) {
  showErrorSnackVia(ScaffoldMessenger.of(context), error);
}

/// [showErrorSnack] 的「已经拿到 messenger」版本。
///
/// 为什么需要这个：`await` 之后再 `ScaffoldMessenger.of(context)` 会触发
/// `use_build_context_synchronously`（context 可能已经失效）。正确写法是在
/// await **之前**把 messenger 存下来 —— 这也是很多调用点本来就在做的事
/// （`final messenger = ScaffoldMessenger.of(context);`）。
/// 有了这个入口，那些地方不必为了报错再把 context 用一遍。
void showErrorSnackVia(ScaffoldMessengerState messenger, Object error) {
  messenger.showSnackBar(SnackBar(content: Text(L.error(error))));
}
