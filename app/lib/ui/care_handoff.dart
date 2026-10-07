import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' show XFile;
import 'package:uuid/uuid.dart';

import '../core/l10n.dart';
import '../data/models.dart';
import '../domain/care_handoff.dart';
import '../providers.dart';
import '../services/report_renderer.dart';
import '../services/share_helper.dart';

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
      final contact = !_includeContact || user == null
          ? ''
          : [
              user.nickname,
              user.phone,
              user.email,
              user.wechat,
              user.contactNote,
            ].whereType<String>().where((s) => s.trim().isNotEmpty).join('\n');
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

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar:
          AppBar(title: Text('${widget.pet.name} · ${L.t('handoff.title')}')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(L.t('handoff.help')),
        const SizedBox(height: 12),
        Wrap(spacing: 12, children: [
          OutlinedButton(
              onPressed: _busy ? null : () => _pick(true),
              child: Text(
                  '${L.t('handoff.from')}: ${_from.year}/${_from.month}/${_from.day}')),
          OutlinedButton(
              onPressed: _busy ? null : () => _pick(false),
              child: Text(
                  '${L.t('handoff.to')}: ${_to.year}/${_to.month}/${_to.day}')),
        ]),
        const SizedBox(height: 12),
        TextField(
            controller: _instructions,
            enabled: !_busy,
            minLines: 3,
            maxLines: 6,
            onChanged: (_) => setState(() => _preview = null),
            decoration: InputDecoration(
                labelText: L.t('handoff.instructions'),
                hintText: L.t('handoff.instructionsHint'),
                border: const OutlineInputBorder())),
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
        if (_error != null)
          Text(_error!, style: const TextStyle(color: Colors.red)),
        FilledButton.icon(
            onPressed: _busy ? null : _generate,
            icon: const Icon(Icons.preview_outlined),
            label: Text(L.t('handoff.preview'))),
        if (_busy)
          const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: CircularProgressIndicator())),
        if (_preview != null) ...[
          const SizedBox(height: 16),
          Image.memory(_preview!),
          const SizedBox(height: 12),
          Builder(
              builder: (buttonContext) => OutlinedButton.icon(
                  onPressed: _busy ? null : () => _share(buttonContext),
                  icon: const Icon(Icons.share_outlined),
                  label: Text(L.t('handoff.share')))),
        ],
      ]));
}
