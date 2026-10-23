import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';

import '../app_look.dart';
import '../main.dart';

/// Puts a masjid on the spot it actually stands.
///
/// Distance is only as good as the coordinates behind it, and a handful of
/// documents have the pair transposed or a pin dropped on the wrong street —
/// which makes that masjid sort as if it were in another city. This screen is
/// the correction: drag the marker (or tap anywhere on the map) and write the
/// new position back, keeping the old one so the mistake stays recoverable.
class FixLocationMapScreen extends StatefulWidget {
  const FixLocationMapScreen({super.key, required this.masjid});

  final Masjid masjid;

  @override
  State<FixLocationMapScreen> createState() => _FixLocationMapScreenState();
}

class _FixLocationMapScreenState extends State<FixLocationMapScreen> {
  late final MapController _mapController;

  /// Built once and reused. FlutterMap compares options by identity on every
  /// rebuild — rebuilding them per drag frame would run the whole options
  /// change path sixty times a second for no reason.
  late final MapOptions _mapOptions;

  late final LatLng _original;

  /// Where the user is putting it. `setState` only, never a parent's — the
  /// page underneath must not be able to rebuild out from under this screen.
  late LatLng _target;

  bool _hadCoords = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();

    _hadCoords = widget.masjid.latitude != 0 || widget.masjid.longitude != 0;
    _original = _hadCoords
        ? LatLng(widget.masjid.latitude, widget.masjid.longitude)
        // A document with no position at all still needs somewhere to start;
        // the anchor is the fallback the rest of the app already sorts from.
        : LatLng(LocationService.fallbackAnchor.x, LocationService.fallbackAnchor.y);
    _target = _original;

    _mapOptions = MapOptions(
      initialCenter: _original,
      initialZoom: 16,
      // Double-tap zoom has to go on a screen whose primary gesture is a tap.
      // While it is enabled flutter_map holds every tap for ~300 ms to see
      // whether a second one is coming, so the marker would jump noticeably
      // after the finger had already left the glass — and a second nudge would
      // zoom the map instead of moving the marker. Pinch still zooms.
      interactionOptions: InteractionOptions(
        flags: InteractiveFlag.all &
            ~(InteractiveFlag.doubleTapZoom | InteractiveFlag.doubleTapDragZoom),
      ),
      onTap: (TapPosition tapPosition, LatLng point) => _moveTo(point),
    );
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  bool get _moved => _target.latitude != _original.latitude ||
      _target.longitude != _original.longitude;

  /// True when the new position is still nowhere near Mumbai — the same
  /// check the list applies, so a pin dropped into the sea is called out here
  /// rather than silently re-sorting the masjid as thousands of km away.
  bool get _looksWrong => !LocationService.isInMumbai(_target.latitude, _target.longitude);

  double get _movedBy => LocationService.between(
        _original.latitude,
        _original.longitude,
        _target.latitude,
        _target.longitude,
      );

  void _moveTo(LatLng point) {
    if (_saving) return;
    setState(() => _target = point);
  }

  /// Turns a screen-space drag into a coordinate change using the camera's
  /// current zoom — one screen pixel is a different distance on the ground at
  /// every zoom level, so the number has to come from the live camera.
  void _dragBy(Offset delta) {
    if (_saving) return;

    final double cosLatitude =
        math.cos(_target.latitude * math.pi / 180);
    if (cosLatitude.abs() < 0.01) return;

    final double metresPerPixel =
        156543.03392 * cosLatitude / math.pow(2, _mapController.camera.zoom).toDouble();

    setState(() {
      _target = LatLng(
        _target.latitude - (delta.dy * metresPerPixel) / 111320,
        _target.longitude + (delta.dx * metresPerPixel) / (111320 * cosLatitude),
      );
    });
  }

  Future<void> _save() async {
    if (_saving || !_moved) return;
    setState(() => _saving = true);

    try {
      final String uid = await _requireSignedIn();

      await FirebaseFirestore.instance.collection('masjids').doc(widget.masjid.id).update(
        <String, Object?>{
          'lat': _target.latitude,
          'lon': _target.longitude,
          'latitude': _target.latitude,
          'longitude': _target.longitude,
          'locationFixedByUser': true,
          'locationFixedAt': FieldValue.serverTimestamp(),
          'originalLat': _original.latitude,
          'originalLon': _original.longitude,
          // The rules insist `updatedByUid == request.auth.uid` on every
          // write, so correcting somebody else's document is rejected outright
          // unless the correction names its own author.
          'updatedByUid': uid,
        },
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location fixed! ❤️')),
      );
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not fix the location: $error',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
  }

  Future<String> _requireSignedIn() async {
    final String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) throw StateError('Sign in to fix a location.');
    return uid;
  }

  void _recentre() {
    // Inferred rather than named so this file does not need a geolocator
    // import for one field access.
    final position = LocationService.lastPosition;
    if (position == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Waiting for a GPS fix…')),
      );
      return;
    }
    _mapController.move(LatLng(position.latitude, position.longitude), 16);
  }

  @override
  Widget build(BuildContext context) {
    return NoorScaffold(
      appBar: AppBar(title: const Text('Fix location')),
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: FlutterMap(
              mapController: _mapController,
              options: _mapOptions,
              children: <Widget>[
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.sunesra_app',
                ),
                MarkerLayer(
                  markers: <Marker>[
                    // Where it is now, kept faint so "Moved by" has something
                    // to be measured against once the marker has travelled.
                    Marker(
                      point: _original,
                      width: 26,
                      height: 26,
                      child: IgnorePointer(
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: NoorColors.ink, width: 2),
                          ),
                        ),
                      ),
                    ),
                    Marker(
                      point: _target,
                      width: 52,
                      height: 52,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanUpdate: (DragUpdateDetails details) => _dragBy(details.delta),
                        child: Container(
                          width: 44,
                          height: 44,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: NoorColors.emeraldDeep,
                            border: Border.all(color: NoorColors.gold, width: 2),
                          ),
                          child: const Icon(Icons.location_on_outlined, size: 26, color: NoorColors.white),
                        ),
                      ),
                    ),
                  ],
                ),
                // Attribution, but not as flutter_map ships it.
                // SimpleAttributionWidget is a Row of two non-flexible Texts,
                // so it blows past the map edge and paints debug stripes the
                // moment the system font scale goes up — and this screen is
                // one nobody should have to scroll to fix. Bounded and
                // ellipsised instead; the credit itself is unchanged.
                Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: 210),
                          child: Text(
                            'flutter_map | © OpenStreetMap contributors',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 9, color: NoorColors.ink),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          if (_looksWrong)
            Positioned(
              top: 12,
              left: 12,
              right: 76,
              child: Material(
                color: const Color(0xFFB4433B),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  child: Text(
                    'These coordinates are outside Mumbai — drag the marker '
                    'onto the masjid.',
                    style: GoogleFonts.outfit(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
            ),

          Positioned(
            top: 12,
            right: 12,
            child: Material(
              color: Colors.white,
              shape: CircleBorder(side: BorderSide(color: NoorColors.gold.withValues(alpha: 0.6))),
              elevation: 2,
              child: IconButton(
                tooltip: 'My location',
                onPressed: _recentre,
                icon: const Icon(Icons.my_location, size: 20, color: NoorColors.emeraldDeep),
              ),
            ),
          ),

          Positioned(left: 0, right: 0, bottom: 0, child: _buildPanel(context)),
        ],
      ),
    );
  }

  Widget _buildPanel(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 22),
      decoration: BoxDecoration(
        color: NoorColors.cream,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: NoorColors.gold.withValues(alpha: 0.6)),
        boxShadow: <BoxShadow>[
          BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 16, offset: const Offset(0, -4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  widget.masjid.name.isEmpty ? 'This masjid' : widget.masjid.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.w700, color: NoorColors.ink),
                ),
              ),
              Text(
                _saving ? 'Saving…' : _moved ? 'Moved' : 'Not moved yet',
                style: GoogleFonts.outfit(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: _moved ? NoorColors.emerald : NoorColors.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _PanelRow(label: 'Current', value: _formatPoint(_original)),
          _PanelRow(label: 'New', value: _formatPoint(_target)),
          _PanelRow(label: 'Moved by', value: _moved ? _formatMetres(_movedBy) : '—'),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: NoorColors.ink,
                    side: BorderSide(color: NoorColors.gold.withValues(alpha: 0.8)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: (!_moved || _saving) ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: NoorColors.emerald,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: NoorColors.emerald.withValues(alpha: 0.35),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  child: Text(
                    _saving ? 'Saving…' : 'Save Location',
                    style: GoogleFonts.outfit(fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                ),
              ),
            ],
          ),
          if (!_moved) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              'Drag the marker, or tap anywhere on the map, to move it.',
              style: GoogleFonts.outfit(fontSize: 10.5, color: NoorColors.muted),
            ),
          ],
        ],
      ),
    );
  }

  String _formatPoint(LatLng point) =>
      '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}';

  String _formatMetres(double metres) {
    if (metres < 1000) return '${metres.round()} m';
    return '${(metres / 1000).toStringAsFixed(2)} km';
  }
}

class _PanelRow extends StatelessWidget {
  const _PanelRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 78,
            child: Text(
              label,
              style: GoogleFonts.outfit(fontSize: 11.5, color: NoorColors.muted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: GoogleFonts.outfit(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: NoorColors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
