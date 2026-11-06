import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n.dart';
import '../data/sync/sync_api.dart';
import '../providers.dart';

class DeleteAccountPage extends ConsumerStatefulWidget {
  const DeleteAccountPage({super.key});

  @override
  ConsumerState<DeleteAccountPage> createState() => _DeleteAccountPageState();
}

class _DeleteAccountPageState extends ConsumerState<DeleteAccountPage> {
  final _confirmation = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_busy,
        child: Scaffold(
          appBar: AppBar(title: Text(L.t('account.delete'))),
          body: ListView(padding: const EdgeInsets.all(24), children: [
            Text(L.t('account.deleteHint')),
            const SizedBox(height: 20),
            TextField(
              controller: _confirmation,
              enabled: !_busy,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              decoration:
                  InputDecoration(labelText: L.t('account.confirmHint')),
              onChanged: (_) => setState(() {}),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 24),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error),
              onPressed: _busy || _confirmation.text.trim() != 'DELETE'
                  ? null
                  : _delete,
              child: Text(
                  L.t(_busy ? 'account.deleting' : 'account.deleteForever')),
            ),
          ]),
        ),
      );

  Future<void> _delete() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(appActionsProvider).deleteAccount();
      if (!mounted) return;
      setState(() => _busy = false);
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(content: Text(L.t('account.deleted'))));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (error is SyncApiException &&
            error.statusCode == 409 &&
            error.message == 'account_has_shared_pets') {
          _error = L.t('account.sharedBlock');
        } else if (error is SyncApiException && error.isMethodNotAllowed) {
          _error = L.t('account.deleteUnavailable');
        } else {
          _error = L.t('account.deleteFailed');
        }
      });
    }
  }
}
