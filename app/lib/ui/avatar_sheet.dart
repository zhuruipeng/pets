/// 头像选择弹层。
///
/// 用 `image_picker` 而不是自建相机页：系统相册/相机不需要自管一堆权限，
/// 而且用户对系统选图界面更熟（尤其是「最近照片」那一栏）。
///
/// **选完的图不能直接用**：`image_picker` 给的是缓存目录里的临时文件，
/// 系统清缓存后头像就没了。所以统一交给 `AvatarStore` 拷进应用目录，
/// 再把新路径写库 —— 这条规矩与附件系统一样。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../core/l10n.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../providers.dart';

Future<void> showAvatarSheet(
  BuildContext context,
  WidgetRef ref,
  Pet pet,
) async {
  final hasAvatar = (pet.avatarUrl ?? '').trim().isNotEmpty;

  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.page,
              AppSpace.gapL,
              AppSpace.page,
              AppSpace.gapS,
            ),
            child: Row(
              children: [
                Text(
                  L.t('avatar.title'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          _Option(
            icon: Icons.photo_camera_rounded,
            label: L.t('avatar.camera'),
            onTap: () => Navigator.pop(ctx, 'camera'),
          ),
          _Option(
            icon: Icons.photo_library_rounded,
            label: L.t('avatar.gallery'),
            onTap: () => Navigator.pop(ctx, 'gallery'),
          ),
          if (hasAvatar)
            _Option(
              icon: Icons.delete_outline_rounded,
              label: L.t('avatar.remove'),
              danger: true,
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
          const SizedBox(height: AppSpace.gapS),
        ],
      ),
    ),
  );

  if (action == null || !context.mounted) return;

  if (action == 'remove') {
    await ref.read(appActionsProvider).removeAvatar(pet);
    return;
  }

  XFile? picked;
  try {
    picked = await ImagePicker().pickImage(
      source: action == 'camera' ? ImageSource.camera : ImageSource.gallery,
      // 头像最大只显示 96pt，原图几千万像素纯属浪费磁盘和内存。
      // 这里先让系统缩到 1024 再落盘。
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 88,
    );
  } catch (_) {
    if (context.mounted) _failed(context);
    return;
  }
  // 用户在系统界面里按了返回。
  if (picked == null) return;

  try {
    await ref.read(appActionsProvider).setAvatar(pet, picked.path);
  } catch (_) {
    if (context.mounted) _failed(context);
  }
}

void _failed(BuildContext context) {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(L.t('avatar.failed'))));
}

class _Option extends StatelessWidget {
  const _Option({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.danger : AppColors.textPrimary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.page,
          vertical: 14,
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: danger ? AppColors.danger : AppColors.primary),
            const SizedBox(width: AppSpace.gapM),
            Text(label, style: TextStyle(fontSize: 14, color: color)),
          ],
        ),
      ),
    );
  }
}
