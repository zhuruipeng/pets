import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../data/repositories/member_repository.dart';
import '../domain/medication_course.dart';
import '../providers.dart';
import 'widgets.dart';

Future<void> showMedicationCourses(BuildContext context, {required Pet pet}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => MedicationCoursesPage(pet: pet)));

class MedicationCoursesPage extends ConsumerWidget {
  const MedicationCoursesPage({super.key, required this.pet});
  final Pet pet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reminders = ref.watch(petRemindersProvider(pet.id));
    final role = ref.watch(petRoleProvider(pet.id)).valueOrNull;
    final canWrite = role?.canWrite == true;
    return Scaffold(
      appBar: AppBar(title: Text('${pet.name} · ${L.t('med.title')}')),
      floatingActionButton: canWrite
          ? FloatingActionButton.extended(
              onPressed: () => showMedicationCourseForm(context, pet: pet),
              icon: const Icon(Icons.add),
              label: Text(L.t('med.add')),
            )
          : null,
      body: reminders.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (all) {
          final courses = all
              .where((r) => r.rule['mode'] == 'medication')
              .toList()
            ..sort((a, b) => a.enabled == b.enabled
                ? a.nextAt.compareTo(b.nextAt)
                : (a.enabled ? -1 : 1));
          return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
              children: [
                Text(L.t('med.instructions'),
                    style: const TextStyle(color: AppColors.textSecondary)),
                const SizedBox(height: 12),
                if (!canWrite && role != null) Text(L.t('care.readOnly')),
                if (courses.isEmpty) ...[
                  const SizedBox(height: 60),
                  const Icon(Icons.medication_outlined,
                      size: 48, color: AppColors.primary),
                  const SizedBox(height: 16),
                  Text(L.t('med.empty'), textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(L.t('med.emptyHint'), textAlign: TextAlign.center),
                ],
                for (final reminder in courses)
                  _CourseCard(
                      key: ValueKey(reminder.id),
                      pet: pet,
                      reminder: reminder,
                      canWrite: canWrite),
              ]);
        },
      ),
    );
  }
}

class MedicationCoursesLink extends ConsumerWidget {
  const MedicationCoursesLink({super.key, required this.pet});
  final Pet pet;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(petRemindersProvider(pet.id)).valueOrNull ?? [];
    final active =
        all.where((r) => r.rule['mode'] == 'medication' && r.enabled).length;
    return Card(
        child: ListTile(
      leading: const Icon(Icons.medication_outlined, color: AppColors.primary),
      title: Text(L.t('med.title')),
      subtitle: Text(active == 0
          ? L.t('med.emptyHint')
          : '${L.t('med.active')} · $active'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showMedicationCourses(context, pet: pet),
    ));
  }
}

class _CourseCard extends ConsumerStatefulWidget {
  const _CourseCard(
      {super.key,
      required this.pet,
      required this.reminder,
      required this.canWrite});
  final Pet pet;
  final Reminder reminder;
  final bool canWrite;
  @override
  ConsumerState<_CourseCard> createState() => _CourseCardState();
}

class _CourseCardState extends ConsumerState<_CourseCard> {
  bool _busy = false;
  @override
  Widget build(BuildContext context) {
    final reminder = widget.reminder;
    final course = MedicationCourse.fromReminder(reminder);
    if (course == null) {
      return Card(child: ListTile(title: Text(L.t('med.error.schedule'))));
    }
    final logsState = ref.watch(careLogsProvider(widget.pet.id));
    final logs = (logsState.valueOrNull ?? <Map<String, Object?>>[])
        .where((l) => l['reminder_id'] == reminder.id && l['action'] == 'done')
        .toList();
    final used = logs.fold<double>(
        0, (n, l) => n + ((l['stock_used'] as num?)?.toDouble() ?? 0));
    final remaining = course.remaining(used);
    final finalDone = logs.any(
            (l) => l['due_at'] == reminder.nextAt.millisecondsSinceEpoch) &&
        course.nextAt(reminder.nextAt, inclusive: false) == null;
    final finished = finalDone ||
        MedicationCourse.day(course.end)
            .isBefore(MedicationCourse.day(DateTime.now()));
    final status = finished
        ? 'med.finished'
        : (reminder.enabled ? 'med.active' : 'med.paused');
    final currentUser = ref.watch(currentUserProvider).valueOrNull;
    return Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                  child: Text(course.name,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700))),
              Text(L.t(status),
                  style: const TextStyle(color: AppColors.textSecondary)),
              if (widget.canWrite)
                PopupMenuButton<String>(
                    enabled: !_busy,
                    onSelected: (value) {
                      if (value == 'edit') {
                        showMedicationCourseForm(context,
                            pet: widget.pet, existing: reminder);
                      } else if (value == 'toggle') {
                        _run(() => ref
                            .read(appActionsProvider)
                            .toggleMedicationCourse(
                                reminder, !reminder.enabled));
                      } else if (value == 'delete') {
                        _delete();
                      }
                    },
                    itemBuilder: (_) => [
                          PopupMenuItem(
                              value: 'edit', child: Text(L.t('med.edit'))),
                          if (!finished)
                            PopupMenuItem(
                                value: 'toggle',
                                child: Text(L.t(reminder.enabled
                                    ? 'med.pause'
                                    : 'med.resume'))),
                          PopupMenuItem(
                              value: 'delete',
                              child: Text(L.t('reminder.delete'))),
                        ]),
            ]),
            Text(
                '${course.dose} · ${L.t('addRecord.med.route.${course.route}')}'),
            const SizedBox(height: 6),
            Text(
                '${MedicationCourse.date(course.start)} — ${MedicationCourse.date(course.end)}'),
            Text(course.times.map((m) => _time(m)).join(' · ')),
            if (reminder.enabled && !finished)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(L.tp(
                      'med.next', {'time': compactDateTime(reminder.nextAt)}))),
            if (remaining != null && logsState.hasValue) ...[
              const SizedBox(height: 8),
              Text(L.tp('med.remaining', {'count': _quantity(remaining)})),
              if (remaining < course.unitsPerDose && !finished)
                Text(L.t('med.lowStock'),
                    style: const TextStyle(color: AppColors.danger)),
            ],
            if (widget.canWrite && reminder.enabled && !finished) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                  onPressed: _busy ? null : _give,
                  icon: const Icon(Icons.check),
                  label: Text(L.t('med.given'))),
            ],
            if (_busy) const LinearProgressIndicator(),
            ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(L.tp('med.history', {'count': '${logs.length}'})),
                children: [
                  if (logsState.isLoading) const LinearProgressIndicator(),
                  if (logsState.hasError) Text('${logsState.error}'),
                  if (logs.isEmpty && logsState.hasValue)
                    Text(L.t('med.noHistory')),
                  for (final log in logs)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(compactDateTime(
                          DateTime.fromMillisecondsSinceEpoch(
                              log['done_at'] as int))),
                      subtitle: Text(log['created_by'] == currentUser?.id
                          ? L.t('care.me')
                          : (log['actor_name'] as String? ??
                              L.t('care.other'))),
                    ),
                ]),
          ]),
        ));
  }

  Future<void> _give() async {
    final reminder = widget.reminder;
    final course = MedicationCourse.fromReminder(reminder)!;
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(L.t('med.givenConfirm')),
              content: Text(L.tp('med.givenHint', {
                'name': course.name,
                'dose': course.dose,
                'time': compactDateTime(reminder.nextAt)
              })),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(L.t('action.cancel'))),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(L.t('med.given')))
              ],
            ));
    if (ok != true || !mounted) return;
    await _run(() async {
      final result = await ref
          .read(appActionsProvider)
          .completeReminder(reminder.id, expectedDueAt: reminder.nextAt);
      if (mounted && result.alreadyCompleted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(L.t('care.alreadyDone'))));
      }
    });
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(L.t('reminder.deleteConfirm')),
              content: Text(L.t('reminder.deleteConfirm.hint')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(L.t('action.cancel'))),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(L.t('reminder.delete')))
              ],
            ));
    if (ok == true && mounted) {
      await _run(
          () => ref.read(appActionsProvider).deleteReminder(widget.reminder));
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_error(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

Future<void> showMedicationCourseForm(BuildContext context,
        {required Pet pet, Reminder? existing}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => MedicationCourseForm(pet: pet, existing: existing)));

class MedicationCourseForm extends ConsumerStatefulWidget {
  const MedicationCourseForm({super.key, required this.pet, this.existing});
  final Pet pet;
  final Reminder? existing;
  @override
  ConsumerState<MedicationCourseForm> createState() =>
      _MedicationCourseFormState();
}

class _MedicationCourseFormState extends ConsumerState<MedicationCourseForm> {
  final _form = GlobalKey<FormState>();
  late TextEditingController _name, _dose, _stock, _units;
  late DateTime _start, _end;
  late List<int> _times;
  String _route = 'oral';
  String? _problem;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final course = widget.existing == null
        ? null
        : MedicationCourse.fromReminder(widget.existing!);
    _name = TextEditingController(text: course?.name ?? '');
    _dose = TextEditingController(text: course?.dose ?? '');
    _stock = TextEditingController(
        text: course?.stock == null ? '' : _quantity(course!.stock!));
    _units = TextEditingController(text: _quantity(course?.unitsPerDose ?? 1));
    _start = course?.start ?? MedicationCourse.day(DateTime.now());
    _end = course?.end ?? DateTime(_start.year, _start.month, _start.day + 6);
    _times = [...?course?.times];
    if (_times.isEmpty) _times = [9 * 60];
    if (['oral', 'topical', 'injection'].contains(course?.route)) {
      _route = course!.route;
    }
  }

  @override
  void dispose() {
    for (final controller in [_name, _dose, _stock, _units]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: Text(L.t(widget.existing == null ? 'med.add' : 'med.edit'))),
        body: Form(
            key: _form,
            child: ListView(padding: const EdgeInsets.all(20), children: [
              Text(L.t('med.instructions'),
                  style: const TextStyle(color: AppColors.textSecondary)),
              const SizedBox(height: 16),
              TextFormField(
                  controller: _name,
                  maxLength: 100,
                  decoration:
                      InputDecoration(labelText: L.t('addRecord.med.name')),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? L.t('med.error.required')
                      : null),
              const SizedBox(height: 12),
              TextFormField(
                  controller: _dose,
                  maxLength: 100,
                  decoration: InputDecoration(
                      labelText: L.t('addRecord.med.dose'),
                      hintText: L.t('addRecord.med.doseHint')),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? L.t('med.error.required')
                      : null),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _route,
                decoration:
                    InputDecoration(labelText: L.t('addRecord.med.route')),
                items: [
                  for (final route in ['oral', 'topical', 'injection'])
                    DropdownMenuItem(
                        value: route,
                        child: Text(L.t('addRecord.med.route.$route')))
                ],
                onChanged: _saving ? null : (v) => setState(() => _route = v!),
              ),
              const SizedBox(height: 16),
              ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(L.t('med.start')),
                  trailing: TextButton(
                      onPressed: _saving ? null : () => _pickDate(true),
                      child: Text(MedicationCourse.date(_start)))),
              ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(L.t('med.end')),
                  trailing: TextButton(
                      onPressed: _saving ? null : () => _pickDate(false),
                      child: Text(MedicationCourse.date(_end)))),
              const SizedBox(height: 12),
              Text(L.t('med.times'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              Wrap(spacing: 8, children: [
                for (final minute in _times)
                  InputChip(
                      label: Text(_time(minute)),
                      onDeleted: _saving
                          ? null
                          : () => setState(() => _times.remove(minute))),
                if (_times.length < 8)
                  ActionChip(
                      avatar: const Icon(Icons.add, size: 18),
                      label: Text(L.t('med.addTime')),
                      onPressed: _saving ? null : _pickTime),
              ]),
              const SizedBox(height: 20),
              TextFormField(
                  controller: _stock,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                      labelText: L.t('med.stock'),
                      helperText: L.t('med.stockHint'),
                      helperMaxLines: 2),
                  validator: (v) {
                    if ((v ?? '').trim().isEmpty) return null;
                    final n = double.tryParse(v!);
                    return n == null || !n.isFinite || n < 0
                        ? L.t('med.error.stock')
                        : null;
                  }),
              const SizedBox(height: 16),
              TextFormField(
                  controller: _units,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: L.t('med.units')),
                  validator: (v) {
                    final n = double.tryParse(v ?? '');
                    return n == null || !n.isFinite || n <= 0
                        ? L.t('med.error.stock')
                        : null;
                  }),
              if (_problem != null)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(_problem!,
                        style: const TextStyle(color: AppColors.danger))),
              const SizedBox(height: 20),
              FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(L.t('action.save'))),
            ])),
      );

  Future<void> _pickDate(bool start) async {
    final chosen = await showDatePicker(
        context: context,
        initialDate: start ? _start : _end,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100));
    if (chosen != null && mounted) {
      setState(() {
        if (start) {
          _start = chosen;
        } else {
          _end = chosen;
        }
      });
    }
  }

  Future<void> _pickTime() async {
    final chosen = await showTimePicker(
        context: context, initialTime: const TimeOfDay(hour: 9, minute: 0));
    if (chosen == null || !mounted) return;
    final minute = chosen.hour * 60 + chosen.minute;
    if (!_times.contains(minute)) {
      setState(() => _times = [..._times, minute]..sort());
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _saving = true;
      _problem = null;
    });
    try {
      await ref.read(appActionsProvider).saveMedicationCourse(
          widget.pet.id,
          MedicationCourse(
            name: _name.text,
            dose: _dose.text,
            route: _route,
            start: _start,
            end: _end,
            times: _times,
            stock:
                _stock.text.trim().isEmpty ? null : double.parse(_stock.text),
            unitsPerDose: double.parse(_units.text),
          ),
          existing: widget.existing);
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(content: Text(L.t('med.saved'))));
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _problem = _error(e);
        });
      }
    }
  }
}

String _time(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
String _quantity(num value) =>
    value == value.roundToDouble() ? '${value.toInt()}' : '$value';
String _error(Object error) => L.error(error);
