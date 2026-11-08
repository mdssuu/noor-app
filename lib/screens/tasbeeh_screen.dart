import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app_look.dart';
import '../main.dart';
import '../services/tasbeeh.dart';

/// The bead counter every mosque keeps in a pocket.
///
/// The whole screen is one button, because that is the whole use: a thumb
/// in a sitting, the count kept, the rounds remembered. The ring shows
/// progress through the current round of thirty-three (or ninety-nine for
/// the two dhikrs counted that way), the buzz marks a completed round the
/// way a string of beads does under the fingers, and the count survives
/// leaving the screen, closing the app and the phone being restarted — it
/// is written per bead, not per visit.
class TasbeehScreen extends StatefulWidget {
  const TasbeehScreen({super.key});

  @override
  State<TasbeehScreen> createState() => _TasbeehScreenState();
}

class _TasbeehScreenState extends State<TasbeehScreen> {
  final Tasbeeh _tasbeeh = Tasbeeh.instance;
  final TextEditingController _duaController = TextEditingController();
  final TextEditingController _labelController = TextEditingController();
  final TextEditingController _arabicController = TextEditingController();
  String _customDua = '';

  Future<void> _editTasbeeh() async {
    _labelController.text = _tasbeeh.selected.label;
    _arabicController.text = _tasbeeh.selected.arabic;
    final List<String>? value = await showDialog<List<String>>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Custom tasbeeh'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(controller: _labelController, decoration: const InputDecoration(labelText: 'Name')),
            TextField(controller: _arabicController, textDirection: TextDirection.rtl, decoration: const InputDecoration(labelText: 'Tasbeeh / Arabic text')),
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, <String>[_labelController.text, _arabicController.text]), child: const Text('Save')),
        ],
      ),
    );
    if (value != null && mounted) {
      await _tasbeeh.setCustom(label: value[0], arabic: value[1]);
    }
  }

  Future<void> _editDua() async {
    _duaController.text = _customDua;
    final String? value = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Custom dua'),
        content: TextField(
          controller: _duaController,
          autofocus: true,
          maxLines: 5,
          decoration: const InputDecoration(hintText: 'Write your dua here'),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, _duaController.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (value != null && mounted) {
      await _tasbeeh.setCustomDua(value);
      setState(() => _customDua = value);
    }
  }

  @override
  void initState() {
    super.initState();
    _tasbeeh.addListener(_changed);
    if (!_tasbeeh.isLoaded) {
      // The screen can open before the first load finishes on a very fast
      // tap; the listener repaints when it does.
      _tasbeeh.load();
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tasbeeh.removeListener(_changed);
    _duaController.dispose();
    _labelController.dispose();
    _arabicController.dispose();
    super.dispose();
  }

  void _tap() {
    final bool roundDone = _tasbeeh.tap();
    // The bead itself is light; a *round* lands hard, the way a completed
    // string does when it is pulled through the fingers.
    HapticFeedback.selectionClick();
    if (roundDone) {
      HapticFeedback.heavyImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    final Dhikr dhikr = _tasbeeh.selected;
    final int count = _tasbeeh.todayOf(dhikr.key);
    if (_customDua != _tasbeeh.customDua) _customDua = _tasbeeh.customDua;
    final int roundOf = _tasbeeh.roundOf;
    final int inRound = _tasbeeh.inRound;

    return NoorScaffold(
      appBar: AppBar(
        title: const Text('Tasbeeh'),
        actions: <Widget>[
          IconButton(
            tooltip: "Today's count starts again",
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: count == 0
                ? null
                : () {
                    _tasbeeh.reset();
                    HapticFeedback.selectionClick();
                  },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
        children: <Widget>[
          SizedBox(
            height: 42,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: kDhikr.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (BuildContext context, int i) {
                final Dhikr d = kDhikr[i];
                final bool on = d.key == dhikr.key;
                return ChoiceChip(
                  selected: on,
                  onSelected: (_) {
                    _tasbeeh.select(d.key);
                    HapticFeedback.selectionClick();
                  },
                  label: Text(
                    d.label,
                    style: GoogleFonts.outfit(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: on ? NoorColors.ink : NoorColors.onGlass,
                    ),
                  ),
                  selectedColor: NoorColors.gold,
                  backgroundColor: NoorColors.onGlassChip,
                  side: BorderSide(
                    color: on
                        ? NoorColors.gold
                        : NoorColors.onGlassMuted.withValues(alpha: 0.4),
                  ),
                  showCheckmark: false,
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _editTasbeeh,
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Edit custom tasbeeh'),
            ),
          ),
          const SizedBox(height: 4),

          // The bead itself: the entire screen is this button.
          Center(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _tap,
              child: Container(
                width: 264,
                height: 264,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    center: const Alignment(-0.3, -0.4),
                    colors: <Color>[
                      NoorColors.gold.withValues(alpha: 0.28),
                      NoorColors.gold.withValues(alpha: 0.06),
                    ],
                  ),
                  border: Border.all(
                    color: NoorColors.gold.withValues(alpha: 0.7),
                    width: 1.4,
                  ),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: NoorColors.gold.withValues(alpha: 0.18),
                      blurRadius: 30,
                    ),
                  ],
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    // The round's progress, drawn as the ring of beads it
                    // stands for.
                    SizedBox(
                      width: 264,
                      height: 264,
                      child: CustomPaint(
                        painter: _RoundRingPainter(
                          progress: roundOf == 0 ? 0 : inRound / roundOf,
                        ),
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          dhikr.arabic,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.amiri(
                            fontSize: 26,
                            color: NoorColors.gold,
                            height: 1.6,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '$count',
                          style: GoogleFonts.outfit(
                            fontSize: 46,
                            height: 1,
                            fontWeight: FontWeight.w700,
                            color: NoorColors.onGlass,
                          ),
                        ),
                        Text(
                          _tasbeeh.roundsToday == 0
                              ? 'tap to count'
                              : '${_tasbeeh.roundsToday} round'
                                  '${_tasbeeh.roundsToday == 1 ? '' : 's'} today',
                          style: GoogleFonts.outfit(
                            fontSize: 11.5,
                            color: NoorColors.onGlassMuted,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          GoldCard(
            child: Row(
              children: <Widget>[
                const Icon(Icons.menu_book_outlined, color: NoorColors.gold),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _customDua.isEmpty ? 'Add your custom dua' : _customDua,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(onPressed: _editDua, icon: const Icon(Icons.edit_outlined)),
              ],
            ),
          ),
          const SizedBox(height: 10),
          GoldCard(
            child: Row(
              children: <Widget>[
                Expanded(
                  child: _stat(
                    'Today',
                    '$count of $roundOf per round',
                  ),
                ),
                Container(width: 1, height: 34, color: NoorColors.onGlassChip),
                Expanded(
                  child: _stat(
                    'All time',
                    '${_tasbeeh.totalOf(dhikr.key)} of ${dhikr.label}',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              'This is your custom tasbeeh. Tap Edit custom tasbeeh above '
              'to choose the name and Arabic text you want to count.',
              style: GoogleFonts.outfit(
                fontSize: 11.5,
                height: 1.5,
                color: NoorColors.onGlassMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: GoogleFonts.outfit(
              fontSize: 11,
              color: NoorColors.onGlassMuted,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.outfit(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: NoorColors.onGlass,
            ),
          ),
        ],
      );
}

/// The ring of beads around the counter: one arc for the current round, gold
/// as far as the fingers have got.
class _RoundRingPainter extends CustomPainter {
  const _RoundRingPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final Paint track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = NoorColors.onGlass.withValues(alpha: 0.10);
    final Paint fill = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = NoorColors.gold;

    final Rect inset = rect.deflate(7);
    canvas.drawArc(inset, -1.5708, 6.2832, false, track);
    if (progress > 0) {
      canvas.drawArc(inset, -1.5708, 6.2832 * progress.clamp(0.0, 1.0), false, fill);
    }
  }

  @override
  bool shouldRepaint(_RoundRingPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
