import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' show XFile;
import 'package:uuid/uuid.dart';

import '../core/l10n.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../domain/care_handoff.dart';
import '../providers.dart';
import '../services/report_renderer.dart';
import '../services/share_helper.dart';
import 'contact_sheet.dart';

class CareHandoffPage extends ConsumerStatefulWidget {
  const CareHandoffPage({super.key, required this.pet});
  final Pet pet;
  @override
  ConsumerState<CareHandoffPage> createState() => _CareHandoffPageState();
}

class _CareHandoffPageState extends ConsumerState<CareHandoffPage> {
  late final _instructions = TextEditingController(text: widget.pet.note ?? '');
  DateTime _from = DateTime.now(),
      _to = DateTime.now().add(const Duration(days: 7));
  bool _includeContact = true, _busy = false;
  Uint8List? _preview;
  String? _error;
  @override
  void dispose() {
    _instructions.dispose();
    super.dispose();
  }

  Future<void> _pick(bool from) async {
    final selected = await showDatePicker(
        context: context,
        initialDate: from ? _from : _to,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100));
    if (selected != null && mounted) {
      setState(() {
        if (from) {
          _from = selected;
        } else {
          _to = selected;
        }
        _preview = null;
      });
    }
  }

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
    });
    try {
      final records = await ref.read(petRecordsProvider(widget.pet.id).future);
      final reminders =
          await ref.read(petRemindersProvider(widget.pet.id).future);
      final pet = await ref.read(petRepositoryProvider).findById(widget.pet.id);
      final user = await ref.read(currentUserProvider.future);
      final role = await ref.read(petRoleProvider(widget.pet.id).future);
      if (pet == null || pet.deletedAt != null || role == null) {
        throw StateError('care.denied');
      }
      final contact = _includeContact ? handoffContact(user) : '';
      final report = buildCareHandoff(
          pet: pet,
          records: records,
          reminders: reminders,
          from: _from,
          to: _to,
          now: DateTime.now(),
          instructions: _instructions.text,
          contact: contact);
      final bytes = await renderPetReportPng(report);
      if (mounted) setState(() => _preview = bytes);
    } catch (e) {
      if (mounted) setState(() => _error = L.error(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share(BuildContext buttonContext) async {
    final bytes = _preview;
    if (bytes == null) return;
    final origin = originOf(buttonContext);
    setState(() => _busy = true);
    try {
      final role = await ref.read(petRoleProvider(widget.pet.id).future);
      final pet = await ref.read(petRepositoryProvider).findById(widget.pet.id);
      if (role == null ||
          pet == null ||
          pet.deletedAt != null ||
          pet.archivedAt != null) {
        throw StateError('care.denied');
      }
      final file = File(p.join((await getTemporaryDirectory()).path,
          'MyPet-care-${const Uuid().v4()}.png'));
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      await shareFiles(
          files: [XFile(file.path, mimeType: 'image/png')],
          subject: L.t('handoff.title'),
          origin: origin);
    } catch (e) {
      if (mounted) setState(() => _error = L.error(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _addTemplate(String key) {
    final text = _instructions.text.trimRight();
    _instructions.text = [if (text.isNotEmpty) text, L.t(key)].join('\n');
    setState(() => _preview = null);
  }

  void _zoom() {
    final bytes = _preview;
    if (bytes == null) return;
    showDialog<void>(
        context: context,
        builder: (context) => Dialog.fullscreen(
              child: Scaffold(
                appBar: AppBar(
                    title: Text(L.t('handoff.preview')),
                    leading: IconButton(
                        tooltip: L.t('action.close'),
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close))),
                body: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 5,
                    child: Center(child: Image.memory(bytes))),
              ),
            ));
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider).valueOrNull;
    final contact = handoffContact(user);
    Widget section(List<Widget> children) => Card(
          margin: const EdgeInsets.only(bottom: 16),
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: children)),
        );
    return Scaffold(
      appBar:
          AppBar(title: Text('${widget.pet.name} · ${L.t('handoff.title')}')),
      bottomNavigationBar: SafeArea(
          child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_preview != null)
            TextButton.icon(
                onPressed: _busy ? null : _generate,
                icon: const Icon(Icons.refresh),
                label: Text(L.t('handoff.regenerate'))),
          SizedBox(
              width: double.infinity,
              child: Builder(
                  builder: (buttonContext) => FilledButton.icon(
                        onPressed: _busy
                            ? null
                            : _preview == null
                                ? _generate
                                : () => _share(buttonContext),
                        icon: Icon(_preview == null
                            ? Icons.preview_outlined
                            : Icons.share_outlined),
                        label: Text(L.t(_preview == null
                            ? 'handoff.preview'
                            : 'handoff.share')),
                      ))),
        ]),
      )),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(L.t('handoff.help'),
            style: const TextStyle(color: AppColors.textSecondary)),
        const SizedBox(height: 16),
        section([
          Text(L.t('handoff.period'),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(spacing: 12, runSpacing: 8, children: [
            OutlinedButton(
                onPressed: _busy ? null : () => _pick(true),
                child: Text(
                    '${L.t('handoff.from')}: ${_from.year}/${_from.month}/${_from.day}')),
            OutlinedButton(
                onPressed: _busy ? null : () => _pick(false),
                child: Text(
                    '${L.t('handoff.to')}: ${_to.year}/${_to.month}/${_to.day}')),
          ]),
        ]),
        section([
          Text(L.t('handoff.instructions'),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final key in ['feeding', 'walk', 'emergency'])
              ActionChip(
                label: Text(L.t('handoff.template.$key')),
                onPressed: _busy
                    ? null
                    : () => _addTemplate('handoff.templateText.$key'),
              ),
          ]),
          const SizedBox(height: 12),
          TextField(
              controller: _instructions,
              enabled: !_busy,
              minLines: 4,
              maxLines: 8,
              onChanged: (_) => setState(() => _preview = null),
              decoration: InputDecoration(
                  hintText: L.t('handoff.instructionsHint'),
                  border: const OutlineInputBorder())),
          if ((widget.pet.allergy ?? '').trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                  '${L.t('profile.field.allergy')}: ${widget.pet.allergy}',
                  style: const TextStyle(color: AppColors.danger)),
            ),
        ]),
        section([
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(L.t('handoff.includeContact')),
              value: _includeContact,
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                        _includeContact = v;
                        _preview = null;
                      })),
          if (_includeContact)
            Text(
                user?.hasContact == true
                    ? contact
                    : [
                        if (contact.isNotEmpty) contact,
                        L.t('handoff.noContact')
                      ].join('\n'),
                style: const TextStyle(color: AppColors.textSecondary)),
          if (_includeContact && user != null)
            TextButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        setState(() => _preview = null);
                        await showContactSheet(context, user: user);
                        if (mounted) setState(() => _preview = null);
                      },
                icon: const Icon(Icons.edit_outlined),
                label: Text(L.t('handoff.editContact'))),
        ]),
        if (_error != null)
          Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(_error!,
                  style: const TextStyle(color: AppColors.danger))),
        if (_busy)
          const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: CircularProgressIndicator())),
        if (_preview != null)
          section([
            Text(L.t('handoff.zoomHint'),
                style: const TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: 8),
            InkWell(onTap: _zoom, child: Image.memory(_preview!)),
          ]),
      ]),
    );
  }
}

String handoffContact(LocalUser? user) => user == null
    ? ''
    : [
        user.nickname,
        user.phone,
        user.email,
        user.wechat,
        user.contactNote,
      ]
        .whereType<String>()
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .join('\n');
