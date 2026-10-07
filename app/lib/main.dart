import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

// Where the Node server lives. On the iOS simulator localhost also reaches the
// Mac; an Android emulator would need 10.0.2.2 instead.
const server = 'http://localhost:8787';

void main() => runApp(const AcornApp());

class AcornApp extends StatelessWidget {
  const AcornApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Acorn Scan',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2E7D5B),
        useMaterial3: true,
      ),
      home: const ScheduleScreen(),
    );
  }
}

// ---------------------------------------------------------------- data model

/// One medication, as read from a label and (optionally) edited by the user.
/// Mirrors the JSON the server returns, with the computed `schedule` attached.
class Medication {
  String drugName;
  String? strength;
  int? doseQuantity;
  String? doseUnit;
  String? frequencyAsWritten;
  String? withFood;
  bool prn;
  String sourceQuote;
  double confidence;

  // The schedule the server worked out (plain code, not the model).
  List<String> times; // clock times like "08:00"; empty for PRN / unknown
  bool timesAssumed; // true = app default times, user should check
  bool needsReview; // true = something essential is missing
  String? reason; // human-readable why

  Medication({
    required this.drugName,
    this.strength,
    this.doseQuantity,
    this.doseUnit,
    this.frequencyAsWritten,
    this.withFood,
    required this.prn,
    required this.sourceQuote,
    required this.confidence,
    required this.times,
    required this.timesAssumed,
    required this.needsReview,
    this.reason,
  });

  factory Medication.fromJson(Map<String, dynamic> m) {
    final s = (m['schedule'] ?? {}) as Map<String, dynamic>;
    return Medication(
      drugName: (m['drug_name'] ?? '') as String,
      strength: m['strength'] as String?,
      doseQuantity: (m['dose_quantity'] as num?)?.toInt(),
      doseUnit: m['dose_unit'] as String?,
      frequencyAsWritten: m['frequency_as_written'] as String?,
      withFood: m['with_food'] as String?,
      prn: m['prn'] == true,
      sourceQuote: (m['source_quote'] ?? '') as String,
      confidence: (m['confidence'] as num?)?.toDouble() ?? 0.5,
      times: ((s['times'] ?? []) as List).map((e) => e.toString()).toList(),
      timesAssumed: s['times_assumed'] == true,
      needsReview: s['needs_review'] == true,
      reason: s['reason'] as String?,
    );
  }

  /// A short, human line for the schedule, e.g. "Metformin 500 mg ×1 (after food)".
  String get label {
    final parts = <String>[drugName];
    if (strength != null && strength!.isNotEmpty) parts.add(strength!);
    if (doseQuantity != null) parts.add('×$doseQuantity');
    final line = parts.join(' ');
    final food = _foodText(withFood);
    return food == null ? line : '$line ($food)';
  }
}

String? _foodText(String? w) {
  switch (w) {
    case 'before_food':
      return 'before food';
    case 'with_food':
      return 'with food';
    case 'after_food':
      return 'after food';
    case 'empty_stomach':
      return 'empty stomach';
    default:
      return null;
  }
}

// --------------------------------------------------------------- the network

/// Pick an image and POST it to the server. Works on web and phones.
Future<List<Medication>> scanLabel() async {
  final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
  if (picked == null) throw 'No image chosen';
  final bytes = await picked.readAsBytes();

  final req = http.MultipartRequest('POST', Uri.parse('$server/scan'))
    ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: picked.name));
  final res = await http.Response.fromStream(await req.send());

  final data = jsonDecode(res.body) as Map<String, dynamic>;
  if (res.statusCode != 200) throw (data['error'] ?? 'Scan failed').toString();

  final meds = (data['medications'] ?? []) as List;
  return meds.map((m) => Medication.fromJson(m as Map<String, dynamic>)).toList();
}

// ----------------------------------------------------------- screen 1: home

class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  // The whole app state: one in-memory list of confirmed medications.
  final List<Medication> _meds = [];

  Future<void> _onScan() async {
    List<Medication> scanned;
    try {
      // Show a blocking spinner while the server reads the label.
      final future = scanLabel();
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _LoadingDialog(),
      );
      scanned = await future;
      if (mounted) Navigator.pop(context); // close spinner
    } catch (e) {
      if (mounted) Navigator.pop(context); // close spinner on error too
      _toast(e.toString());
      return;
    }

    if (scanned.isEmpty) {
      _toast('No medications were found on that label.');
      return;
    }

    // Hand the scanned list to the review screen; get back what the user confirmed.
    if (!mounted) return;
    final confirmed = await Navigator.push<List<Medication>>(
      context,
      MaterialPageRoute(builder: (_) => ReviewScreen(medications: scanned)),
    );
    if (confirmed != null && confirmed.isNotEmpty) {
      setState(() => _meds.addAll(confirmed));
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final scheduled = _meds.where((m) => !m.prn && m.times.isNotEmpty).toList();
    final asNeeded = _meds.where((m) => m.prn).toList();

    // Group scheduled doses by clock time: { "08:00": [Metformin, ...], ... }.
    final byTime = <String, List<Medication>>{};
    for (final m in scheduled) {
      for (final t in m.times) {
        byTime.putIfAbsent(t, () => []).add(m);
      }
    }
    final times = byTime.keys.toList()..sort();

    return Scaffold(
      appBar: AppBar(title: const Text('Today')),
      body: _meds.isEmpty
          ? const _EmptyState()
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              children: [
                for (final t in times) ...[
                  _TimeHeader(t),
                  for (final m in byTime[t]!) _DoseTile(m),
                ],
                if (asNeeded.isNotEmpty) ...[
                  const _TimeHeader('As needed'),
                  for (final m in asNeeded) _DoseTile(m),
                ],
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _onScan,
        icon: const Icon(Icons.document_scanner_outlined),
        label: Text(_meds.isEmpty ? 'Scan a label' : 'Scan another label'),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.medication_outlined,
              size: 72, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          const Text('Scan your first prescription label',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text('Your medication schedule will appear here.',
              style: TextStyle(color: Colors.black54)),
        ],
      ),
    );
  }
}

class _TimeHeader extends StatelessWidget {
  final String text;
  const _TimeHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 6),
      child: Text(text,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.primary,
          )),
    );
  }
}

class _DoseTile extends StatelessWidget {
  final Medication m;
  const _DoseTile(this.m);

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: const Icon(Icons.medication),
        title: Text(m.label),
        subtitle: m.frequencyAsWritten != null
            ? Text(m.frequencyAsWritten!, style: const TextStyle(color: Colors.black54))
            : null,
      ),
    );
  }
}

class _LoadingDialog extends StatelessWidget {
  const _LoadingDialog();

  @override
  Widget build(BuildContext context) {
    return const Dialog(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
            SizedBox(width: 20),
            Text('Reading the label…'),
          ],
        ),
      ),
    );
  }
}

// --------------------------------------------------------- screen 2: review

class ReviewScreen extends StatefulWidget {
  final List<Medication> medications;
  const ReviewScreen({super.key, required this.medications});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  // A local, editable copy. "kept" lets the user drop a wrongly read line.
  late final List<Medication> _meds;
  late final List<bool> _kept;

  @override
  void initState() {
    super.initState();
    _meds = widget.medications;
    _kept = List<bool>.filled(_meds.length, true);
  }

  void _confirm() {
    final result = <Medication>[];
    for (var i = 0; i < _meds.length; i++) {
      if (_kept[i]) result.add(_meds[i]);
    }
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Check before adding')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'We read this from the label. Fix anything wrong, then confirm.',
              style: TextStyle(color: Colors.black54),
            ),
          ),
          for (var i = 0; i < _meds.length; i++)
            _MedCard(
              med: _meds[i],
              kept: _kept[i],
              onKeptChanged: (v) => setState(() => _kept[i] = v),
              onChanged: () => setState(() {}),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _confirm,
        icon: const Icon(Icons.check),
        label: const Text('Confirm'),
      ),
    );
  }
}

class _MedCard extends StatelessWidget {
  final Medication med;
  final bool kept;
  final ValueChanged<bool> onKeptChanged;
  final VoidCallback onChanged;

  const _MedCard({
    required this.med,
    required this.kept,
    required this.onKeptChanged,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // Amber border when the schedule needs a human to look.
    final border = med.needsReview
        ? const BorderSide(color: Color(0xFFF2A000), width: 2)
        : BorderSide(color: Colors.grey.shade300);

    return Card(
      shape: RoundedRectangleBorder(
        side: border,
        borderRadius: BorderRadius.circular(12),
      ),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Opacity(
        opacity: kept ? 1 : 0.4,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(med.drugName,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                  if (med.prn) const _Pill('As needed'),
                  IconButton(
                    tooltip: kept ? 'Remove this line' : 'Add back',
                    icon: Icon(kept ? Icons.delete_outline : Icons.undo),
                    onPressed: () => onKeptChanged(!kept),
                  ),
                ],
              ),

              if (med.needsReview && med.reason != null) _Banner(med.reason!),

              // Editable fields. Editing updates the in-memory object directly.
              _Field('Name', med.drugName, (v) { med.drugName = v; onChanged(); }),
              _Field('Strength', med.strength ?? '', (v) { med.strength = v.isEmpty ? null : v; onChanged(); }),
              _Field('How often', med.frequencyAsWritten ?? '', (v) { med.frequencyAsWritten = v.isEmpty ? null : v; onChanged(); }),

              const SizedBox(height: 10),

              // The scheduled times, and a note when they are app defaults.
              if (!med.prn && med.times.isNotEmpty)
                Text('Scheduled: ${med.times.join(', ')}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              if (med.timesAssumed)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'Times are app defaults — change if your doctor said otherwise.',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ),

              const SizedBox(height: 10),

              // The exact text on the label this came from: the trust anchor.
              Text('“${med.sourceQuote}”',
                  style: const TextStyle(fontStyle: FontStyle.italic, color: Colors.black54)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  const _Field(this.label, this.value, this.onChanged);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextFormField(
        initialValue: value,
        onChanged: onChanged,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final String text;
  const _Banner(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E0),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFFF2A000), size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  const _Pill(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text, style: const TextStyle(fontSize: 12)),
    );
  }
}
