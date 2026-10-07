import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../core/l10n.dart';
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
  String? _message;
  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _message = L.error(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export(BuildContext buttonContext) async {
    final origin = originOf(buttonContext);
    await _run(() async {
      final service = await ref.read(backupServiceProvider.future);
      final file = await service.exportTo(p.join(
          (await getTemporaryDirectory()).path,
          'MyPet-backup-${DateTime.now().millisecondsSinceEpoch}-${const Uuid().v4()}.zip'));
      final preview = await service.inspect(file.path);
      if (!mounted) return;
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
        final selected = await openFile(acceptedTypeGroups: [backupFileType]);
        if (selected == null) return;
        final service = await ref.read(backupServiceProvider.future);
        final preview = await service.inspect(selected.path);
        if (!mounted) return;
        var restoreContact = false;
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
        final ids = await service.restore(selected.path,
            expectedId: preview.id, restoreContact: restoreContact);
        if (!mounted) return;
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
        }
        setState(
            () => _message = L.tp('backup.restored', {'count': preview.pets}));
      });

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(L.t('backup.title'))),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Text(L.t('backup.help')),
        const SizedBox(height: 16),
        Text(L.t('backup.privacy')),
        const SizedBox(height: 24),
        Builder(
            builder: (buttonContext) => FilledButton.icon(
                onPressed: _busy ? null : () => _export(buttonContext),
                icon: const Icon(Icons.save_alt),
                label: Text(L.t('backup.export')))),
        const SizedBox(height: 12),
        OutlinedButton.icon(
            onPressed: _busy ? null : _restore,
            icon: const Icon(Icons.restore),
            label: Text(L.t('backup.restore'))),
        if (_busy)
          const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator())),
        if (_message != null)
          Padding(
              padding: const EdgeInsets.only(top: 20), child: Text(_message!)),
      ]));
}
