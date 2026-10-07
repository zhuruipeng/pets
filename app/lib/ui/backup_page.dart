import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../core/l10n.dart';
import '../core/theme.dart';
import 'widgets.dart';
import 'medication_courses.dart';
import '../providers.dart';
import '../services/share_helper.dart';

const backupFileType = XTypeGroup(
    label: 'My Pet backup',
    extensions: ['zip'],
    mimeTypes: ['application/zip'],
    uniformTypeIdentifiers: ['public.zip-archive']);

class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});
  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage> {
  bool _busy = false;
  String? _message, _restoredPetId;
  String _phase = 'backup.preparing';
  bool _failed = false;
  void _stage(String phase) {
    if (mounted) setState(() => _phase = phase);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
      _failed = false;
      _phase = 'backup.preparing';
      _restoredPetId = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = L.error(e);
          _failed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export(BuildContext buttonContext) async {
    final origin = originOf(buttonContext);
    await _run(() async {
      final service = await ref.read(backupServiceProvider.future);
      _stage('backup.packing');
      final file = await service.exportTo(p.join(
          (await getTemporaryDirectory()).path,
          'MyPet-backup-${DateTime.now().millisecondsSinceEpoch}-${const Uuid().v4()}.zip'));
      _stage('backup.verifying');
      final preview = await service.inspect(file.path);
      await service.markGenerated(preview);
      if (!mounted) return;
      ref.invalidate(backupInventoryProvider);
      _stage('backup.saving');
      await shareFiles(
          files: [XFile(file.path, mimeType: 'application/zip')],
          subject: L.t('backup.title'),
          origin: origin);
      if (mounted) {
        setState(() => _message = L.tp(
            'backup.exported', {'pets': preview.pets, 'files': preview.files}));
      }
    });
  }

  Future<void> _restore() => _run(() async {
        _stage('backup.selecting');
        final selected = await openFile(acceptedTypeGroups: [backupFileType]);
        if (selected == null) return;
        final service = await ref.read(backupServiceProvider.future);
        _stage('backup.verifying');
        final preview = await service.inspect(selected.path);
        if (!mounted) return;
        var restoreContact = false;
        _stage('backup.awaitingConfirm');
        final go = await showDialog<bool>(
            context: context,
            builder: (_) => StatefulBuilder(
                builder: (context, update) => AlertDialog(
                        title: Text(L.t('backup.confirm')),
                        content: SingleChildScrollView(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                              Text(L.tp('backup.preview', {
                                'date':
                                    '${preview.createdAt.year}/${preview.createdAt.month}/${preview.createdAt.day}',
                                'pets': preview.pets,
                                'records': preview.records,
                                'files': preview.files
                              })),
                              const SizedBox(height: 12),
                              Text(L.t('backup.restoreInfo')),
                              CheckboxListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(L.t('backup.contact')),
                                  value: restoreContact,
                                  onChanged: (value) => update(
                                      () => restoreContact = value ?? false)),
                            ])),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: Text(L.t('action.cancel'))),
                          FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: Text(L.t('backup.restore'))),
                        ])));
        if (go != true) return;
        if (!mounted) return;
        _stage('backup.importing');
        final ids = await service.restore(selected.path,
            expectedId: preview.id, restoreContact: restoreContact);
        if (!mounted) return;
        ref.invalidate(backupInventoryProvider);
        ref.invalidate(petsProvider);
        ref.invalidate(petRecordsProvider);
        ref.invalidate(petRemindersProvider);
        ref.invalidate(petMembersProvider);
        ref.invalidate(petRoleProvider);
        ref.invalidate(petPhotosProvider);
        ref.invalidate(petDocumentsProvider);
        ref.invalidate(petExpensesProvider);
        ref.invalidate(weightSeriesProvider);
        ref.invalidate(currentUserProvider);
        ref.invalidate(careLogsProvider);
        ref.invalidate(upcomingRemindersProvider);
        if (ids.isNotEmpty) {
          ref.read(selectedPetIdProvider.notifier).state = ids.first;
          for (final id in ids) {
            final pet = await ref.read(petRepositoryProvider).findById(id);
            if (!mounted) return;
            if (pet != null &&
                pet.deletedAt == null &&
                pet.archivedAt == null) {
              _restoredPetId = id;
              ref.read(selectedPetIdProvider.notifier).state = id;
              break;
            }
          }
        }
        setState(
            () => _message = L.tp('backup.restored', {'count': preview.pets}));
      });

  Future<void> _reviewCourses() async {
    final pet = await ref.read(petRepositoryProvider).findById(_restoredPetId!);
    if (mounted && pet != null) await showMedicationCourses(context, pet: pet);
  }

  @override
  Widget build(BuildContext context) {
    final inventory = ref.watch(backupInventoryProvider);
    Widget section(List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children)));
    return Scaffold(
      appBar: AppBar(title: Text(L.t('backup.title'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        section([
          Text(L.t('backup.export'),
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(L.t('backup.help'),
              style: const TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          inventory.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text(L.error(e)),
            data: (data) =>
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 8, runSpacing: 4, children: [
                Chip(
                    label: Text(L.tp('backup.petCount', {'count': data.pets}))),
                Chip(
                    label: Text(
                        L.tp('backup.recordCount', {'count': data.records}))),
                Chip(
                    label: Text(L.tp('backup.attachmentCount',
                        {'count': data.attachments}))),
              ]),
              const SizedBox(height: 8),
              Text(
                  data.lastGenerated == null
                      ? L.t('backup.neverGenerated')
                      : L.tp('backup.lastGenerated', {
                          'time':
                              '${data.lastGenerated!.year} ${compactDateTime(data.lastGenerated!)}'
                        }),
                  style: const TextStyle(color: AppColors.textSecondary)),
            ]),
          ),
          const SizedBox(height: 16),
          SizedBox(
              width: double.infinity,
              child: Builder(
                  builder: (buttonContext) => FilledButton.icon(
                      onPressed: _busy ? null : () => _export(buttonContext),
                      icon: const Icon(Icons.save_alt),
                      label: Text(L.t('backup.export'))))),
        ]),
        section([
          Text(L.t('backup.restore'),
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(L.t('backup.restoreInfo'),
              style: const TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: 16),
          SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                  onPressed: _busy ? null : _restore,
                  icon: const Icon(Icons.restore),
                  label: Text(L.t('backup.restore')))),
        ]),
        if (_busy)
          section([
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(L.t(_phase)),
          ]),
        if (_message != null)
          section([
            Icon(_failed ? Icons.error_outline : Icons.check_circle_outline,
                color: _failed ? AppColors.danger : AppColors.primary),
            const SizedBox(height: 8),
            Text(_message!,
                style: TextStyle(
                    color: _failed ? AppColors.danger : AppColors.textPrimary)),
            if (_restoredPetId != null && !_failed) ...[
              const SizedBox(height: 12),
              Text(L.t('backup.pausedHint')),
              TextButton(
                  onPressed: _busy ? null : _reviewCourses,
                  child: Text(L.t('backup.reviewCourses'))),
            ],
          ]),
        Text(L.t('backup.privacy'),
            style:
                const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
      ]),
    );
  }
}
