import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../data/repositories/member_repository.dart';
import '../providers.dart';

class DeletePetButton extends ConsumerStatefulWidget {
  const DeletePetButton({super.key, required this.pet});
  final Pet pet;
  @override
  ConsumerState<DeletePetButton> createState() => _DeletePetButtonState();
}

class _DeletePetButtonState extends ConsumerState<DeletePetButton> {
  bool _busy = false;
  @override
  Widget build(BuildContext context) {
    if (ref.watch(petRoleProvider(widget.pet.id)).valueOrNull !=
        MemberRole.owner) {
      return const SizedBox.shrink();
    }
    return Center(
        child: TextButton.icon(
      onPressed: _busy ? null : _delete,
      icon: const Icon(Icons.delete_outline),
      label: Text(L.t('pet.delete')),
      style: TextButton.styleFrom(foregroundColor: AppColors.danger),
    ));
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(L.tp('pet.delete.title', {'name': widget.pet.name})),
              content: Text(L.t('pet.delete.hint')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(L.t('action.cancel'))),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(L.t('pet.delete'),
                        style: const TextStyle(color: AppColors.danger))),
              ],
            ));
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(appActionsProvider).deletePet(widget.pet.id);
      messenger.showSnackBar(SnackBar(content: Text(L.t('pet.deleted'))));
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text(L.error(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
