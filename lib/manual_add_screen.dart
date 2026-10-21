import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_look.dart';
import 'main.dart';
import 'services/places_service.dart';

/// Manual entry form — no camera, no OCR.
///
/// Saves with `source: 'manual'` so it is distinguishable from scanned boards.
class ManualAddScreen extends StatefulWidget {
  const ManualAddScreen({
    super.key,
    this.presetName = '',
    this.presetAddress = '',
    this.presetLatitude,
    this.presetLongitude,
    this.existing,
  });

  final String presetName;
  final String presetAddress;
  final double? presetLatitude;
  final double? presetLongitude;

  /// When set, the form edits this masjid instead of creating a new one.
  final Masjid? existing;

  @override
  State<ManualAddScreen> createState() => _ManualAddScreenState();
}

class _ManualAddScreenState extends State<ManualAddScreen> {
  static const List<String> _keys = <String>['fajr', 'dhuhr', 'asr', 'maghrib', 'isha'];
  static const Map<String, String> _labels = <String, String>{
    'fajr': 'Fajr',
    'dhuhr': 'Zuhr',
    'asr': 'Asr',
    'maghrib': 'Maghrib',
    'isha': 'Isha',
  };

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _area;
  late final TextEditingController _address;
  late final TextEditingController _lat;
  late final TextEditingController _lng;

  final Map<String, String?> _times = <String, String?>{};

  bool _saving = false;
  bool _locating = false;

  // --- OpenStreetMap autocomplete on the name field ---
  final LayerLink _layerLink = LayerLink();
  final FocusNode _nameFocus = FocusNode();
  OverlayEntry? _overlay;
  List<MasjidSearchResult> _suggestions = <MasjidSearchResult>[];

  @override
  void initState() {
    super.initState();

    final Masjid? existing = widget.existing;
    _name = TextEditingController(
        text: existing?.name.isNotEmpty == true ? existing!.name : widget.presetName);
    _address = TextEditingController(
        text: existing?.address.isNotEmpty == true ? existing!.address : widget.presetAddress);
    // Prefilled when editing — a blank controller used to wipe the stored
    // locality on every manual edit.
    _area = TextEditingController(text: existing?.area ?? '');
    _lat = TextEditingController(
      text: (existing?.latitude ?? widget.presetLatitude)?.toStringAsFixed(6) ?? '',
    );
    _lng = TextEditingController(
      text: (existing?.longitude ?? widget.presetLongitude)?.toStringAsFixed(6) ?? '',
    );

    for (final String key in _keys) {
      _times[key] = existing?.timeFor(key);
    }
  }

  @override
  void dispose() {
    _removeOverlay();
    _name.dispose();
    _area.dispose();
    _address.dispose();
    _lat.dispose();
    _lng.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- places
  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  int _searchToken = 0;

  void _onNameChanged(String value) {
    final int token = ++_searchToken;
    Future<void>.delayed(const Duration(milliseconds: 650), () {
      if (!mounted || token != _searchToken) return;
      _runSearch(value);
    });
  }

  Future<void> _runSearch(String value) async {
    if (value.trim().length < 3) {
      _removeOverlay();
      if (mounted) setState(() => _suggestions = <MasjidSearchResult>[]);
      return;
    }

    // Bias towards whatever coords are already filled in, so picking a place
    // for a mosque in one city doesn't surface one from another.
    final double? lat = double.tryParse(_lat.text.trim());
    final double? lng = double.tryParse(_lng.text.trim());

    final List<MasjidSearchResult> found = await searchMasjid(
      query: value,
      lat: lat,
      lon: lng,
      limit: 6,
    );
    if (!mounted) return;

    setState(() => _suggestions = found);
    if (found.isEmpty) {
      _removeOverlay();
      return;
    }
    _showOverlay();
  }

  void _showOverlay() {
    _removeOverlay();
    final RenderObject? renderObject = context.findRenderObject();

    _overlay = OverlayEntry(
      builder: (BuildContext context) => Positioned(
        width: MediaQuery.sizeOf(context).width - 32,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: const Offset(0, 62),
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(16),
            color: NoorColors.white,
            child: Container(
              constraints: const BoxConstraints(maxHeight: 260),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: NoorColors.gold.withValues(alpha: 0.7)),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: _suggestions.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: NoorColors.gold.withValues(alpha: 0.25)),
                itemBuilder: (BuildContext context, int i) {
                  final MasjidSearchResult s = _suggestions[i];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.place_outlined,
                        size: 18, color: NoorColors.emeraldDeep),
                    title: Text(
                      s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                          fontSize: 13.5, fontWeight: FontWeight.w600, color: NoorColors.ink),
                    ),
                    subtitle: s.address.isEmpty
                        ? null
                        : Text(
                            s.address,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.outfit(fontSize: 11, color: NoorColors.muted),
                          ),
                    onTap: () => _selectPlace(s),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );

    if (renderObject != null) {
      Overlay.of(context).insert(_overlay!);
    }
  }

  void _selectPlace(MasjidSearchResult suggestion) {
    _removeOverlay();
    FocusScope.of(context).unfocus();

    setState(() {
      _suggestions = <MasjidSearchResult>[];
      _name.text = suggestion.name;
      if (_address.text.trim().isEmpty && suggestion.address.isNotEmpty) {
        _address.text = suggestion.address;
      }
      if (suggestion.latitude != 0 || suggestion.longitude != 0) {
        _lat.text = suggestion.latitude.toStringAsFixed(6);
        _lng.text = suggestion.longitude.toStringAsFixed(6);
      }
    });
  }

  // -------------------------------------------------------------- helpers
  Future<void> _useMyLocation() async {
    if (_locating) return;
    setState(() => _locating = true);
    try {
      final Position? position = await LocationService.currentPosition();
      if (position == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Location unavailable — check GPS permission.')),
          );
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        _lat.text = position.latitude.toStringAsFixed(6);
        _lng.text = position.longitude.toStringAsFixed(6);
      });

      if (_address.text.trim().isEmpty) {
        final String resolved =
            await LocationService.reverseGeocode(position.latitude, position.longitude);
        if (resolved.isNotEmpty && mounted) _address.text = resolved;
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _pickTime(String key) async {
    TimeOfDay initial = TimeOfDay.now();
    final String? current = _times[key];
    if (current != null && RegExp(r'^\d{1,2}:\d{2}$').hasMatch(current)) {
      final List<String> parts = current.split(':');
      initial = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
    }

    final TimeOfDay? picked =
        await showTimePicker(context: context, initialTime: initial);
    if (picked == null || !mounted) return;
    setState(() {
      _times[key] =
          '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final String name = _name.text.trim();
    if (name.isEmpty) return;

    final double latitude = double.tryParse(_lat.text.trim()) ?? 0;
    final double longitude = double.tryParse(_lng.text.trim()) ?? 0;

    setState(() => _saving = true);
    try {
      final User? user = FirebaseAuth.instance.currentUser;
      final Timestamp now = Timestamp.now();

      final Map<String, dynamic> payload = <String, dynamic>{
        'masjidName': name,
        for (final String key in _keys) key: (_times[key] ?? '').trim(),
        // Manual entries have no Juma time field in this form — keep the key
        // so Firestore rules that require all prayer fields still pass.
        'juma': widget.existing?.juma ?? '',
        'latitude': latitude,
        'longitude': longitude,
        'address': _address.text.trim(),
        'area': _area.text.trim(),
        // Editing must not erase the board photo that came with a scan.
        'photoProofPath': widget.existing?.photoProofPath ?? '',
        'photoProofBase64': widget.existing?.photoProofBase64 ?? '',
        'lastUpdated': now,
        'updatedAt': now,
        'source': 'manual',
        'updatedBy': user?.displayName ?? user?.email ?? 'Anonymous',
        'updatedByUid': user?.uid ?? '',
        'updateCount': FieldValue.increment(1),
      };

      if (widget.existing == null) {
        // Recorded on create only: an update must never re-attribute the
        // document, or anyone who edits it would gain the delete button.
        payload['createdByUid'] = user?.uid ?? '';
        payload['createdAt'] = FieldValue.serverTimestamp();
      }

      // De-duplicate: same normalised name within 200 m updates that document.
      String? targetId = widget.existing?.id;
      if (targetId == null) {
        final QuerySnapshot<Map<String, dynamic>> existing =
            await FirebaseFirestore.instance.collection('masjids').get();
        for (final DocumentSnapshot<Map<String, dynamic>> doc in existing.docs) {
          final Masjid other = Masjid.fromDoc(doc);
          if (normaliseName(other.name) != normaliseName(name)) continue;
          final double distance = Geolocator.distanceBetween(
            latitude,
            longitude,
            other.latitude,
            other.longitude,
          );
          if (distance <= 200) {
            targetId = doc.id;
            break;
          }
        }
      }

      final CollectionReference<Map<String, dynamic>> collection =
          FirebaseFirestore.instance.collection('masjids');

      if (targetId != null) {
        await collection.doc(targetId).set(payload, SetOptions(merge: true));
      } else {
        await collection.add(payload);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(targetId != null
              ? '$name updated for everyone nearby ✅'
              : '$name added for everyone nearby ✅'),
        ),
      );
      Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save: $error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ----------------------------------------------------------------- build
  InputDecoration _decoration(String hint, {IconData? icon}) => InputDecoration(
        hintText: hint,
        prefixIcon: icon == null ? null : Icon(icon, size: 18, color: NoorColors.muted),
        filled: true,
        fillColor: NoorColors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: NoorColors.gold.withValues(alpha: 0.5)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: NoorColors.gold, width: 1.4),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return NoorScaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'Add masjid manually' : 'Edit times'),
      ),
      body: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          children: <Widget>[
            if (kPlacesEnabled)
              Text(
                'Tip: start typing a masjid name — $kProviderLabel will suggest '
                'nearby masjids and fill the address and coordinates for you.',
                style: GoogleFonts.outfit(
                  fontSize: 11.5,
                  color: NoorColors.muted,
                  height: 1.5,
                ),
              )
            else
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: NoorColors.onGlassChip,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: NoorColors.gold.withValues(alpha: 0.6)),
                ),
                child: Text(
                  'Search provider $kProviderLabel has no API key yet — enter the '
                  'masjid details by hand. Add the key in '
                  'lib/services/places_service.dart.',
                  style: GoogleFonts.outfit(
                    fontSize: 11.5,
                    color: NoorColors.onGlassMuted,
                    height: 1.5,
                  ),
                ),
              ),

            const SizedBox(height: 16),

            // ------------------------------------------------------ name
            CompositedTransformTarget(
              link: _layerLink,
              child: TextFormField(
                controller: _name,
                focusNode: _nameFocus,
                onChanged: _onNameChanged,
                textCapitalization: TextCapitalization.words,
                validator: (String? v) =>
                    (v ?? '').trim().isEmpty ? 'Masjid name is required' : null,
                decoration: _decoration('Masjid name', icon: Icons.mosque_outlined),
              ),
            ),

            const SizedBox(height: 12),

            // ------------------------------------------------------ area
            TextFormField(
              controller: _area,
              textCapitalization: TextCapitalization.words,
              decoration: _decoration('Area / locality (e.g. Kurla)',
                  icon: Icons.location_city_outlined),
            ),

            const SizedBox(height: 12),

            // --------------------------------------------------- address
            TextFormField(
              controller: _address,
              textCapitalization: TextCapitalization.sentences,
              maxLines: 2,
              decoration: _decoration('Full address', icon: Icons.place_outlined),
            ),

            const SizedBox(height: 14),

            // -------------------------------------------------- coordinates
            Row(
              children: <Widget>[
                Expanded(
                  child: TextFormField(
                    controller: _lat,
                    keyboardType:
                        const TextInputType.numberWithOptions(signed: true, decimal: true),
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
                    ],
                    validator: (String? v) =>
                        double.tryParse((v ?? '').trim()) == null ? 'Lat?' : null,
                    decoration: _decoration('Latitude'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextFormField(
                    controller: _lng,
                    keyboardType:
                        const TextInputType.numberWithOptions(signed: true, decimal: true),
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
                    ],
                    validator: (String? v) =>
                        double.tryParse((v ?? '').trim()) == null ? 'Lng?' : null,
                    decoration: _decoration('Longitude'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _locating ? null : _useMyLocation,
                style: TextButton.styleFrom(foregroundColor: NoorColors.gold),
                icon: _locating
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.my_location, size: 16),
                label: Text(
                  _locating ? 'Locating…' : 'Use my current location',
                  style: GoogleFonts.outfit(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ),
            ),

            const SizedBox(height: 10),
            const Divider(),
            const SizedBox(height: 6),

            SectionHeader(title: 'Prayer times'),
            const SizedBox(height: 4),

            for (final String key in _keys)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: InkWell(
                  onTap: () => _pickTime(key),
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                    decoration: BoxDecoration(
                      color: NoorColors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: (_times[key] ?? '').isEmpty
                            ? NoorColors.gold.withValues(alpha: 0.5)
                            : NoorColors.gold,
                      ),
                    ),
                    child: Row(
                      children: <Widget>[
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: NoorColors.cardGreen,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            prayerByKey(key).icon,
                            size: 16,
                            // The chip behind it is cream, so the light accent
                            // would all but disappear here.
                            color: NoorColors.emeraldDeep,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _labels[key]!,
                            style: GoogleFonts.outfit(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: NoorColors.ink,
                            ),
                          ),
                        ),
                        Text(
                          (_times[key] ?? '').isEmpty
                              ? 'Tap to set'
                              : _times[key]!,
                          // This row sits on a white card: the read time has to
                          // be dark or the value looks missing entirely.
                          style: GoogleFonts.outfit(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: (_times[key] ?? '').isEmpty
                                ? NoorColors.muted
                                : NoorColors.ink,
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(Icons.schedule_outlined,
                            size: 17, color: NoorColors.muted),
                      ],
                    ),
                  ),
                ),
              ),

            const SizedBox(height: 14),
            GradientButton(
              label: widget.existing == null ? 'Save masjid' : 'Save changes',
              icon: Icons.check_outlined,
              busy: _saving,
              onPressed: _saving ? null : _save,
            ),
            const SizedBox(height: 6),
            Text(
              'Saved to the shared list so everyone nearby sees it. '
              'No photo is attached for manual entries.',
              textAlign: TextAlign.center,
              style: GoogleFonts.outfit(
                fontSize: 11,
                color: NoorColors.muted,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
