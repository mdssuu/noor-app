import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';

import 'app_look.dart';
import 'main.dart';
import 'manual_add_screen.dart';
import 'services/places_service.dart';

/// Result of picking a search suggestion: show what the provider knows, then
/// let the user contribute the Jamaat times to Firestore.
class PlaceDetailsScreen extends StatelessWidget {
  const PlaceDetailsScreen({super.key, required this.result});

  final MasjidSearchResult result;

  bool get _hasCoords => result.latitude != 0 || result.longitude != 0;

  Future<void> _addTimes(BuildContext context) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ManualAddScreen(
          presetName: result.name,
          presetAddress: result.address,
          presetLatitude: _hasCoords ? result.latitude : null,
          presetLongitude: _hasCoords ? result.longitude : null,
        ),
      ),
    );
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final bool hasCoords = _hasCoords;
    final String name = result.name;
    final String address = result.address;

    return NoorScaffold(
      appBar: AppBar(title: const Text('Masjid details')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: <Widget>[
          GoldCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const MasjidLogo(size: 44),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            name,
                            style: GoogleFonts.outfit(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w700,
                              color: NoorColors.onGlass,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            address.isEmpty ? 'Address unavailable' : address,
                            style:
                                GoogleFonts.outfit(fontSize: 12, color: NoorColors.onGlassMuted, height: 1.5),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                      decoration: BoxDecoration(
                        color: NoorColors.onGlassChip,
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(color: NoorColors.gold.withValues(alpha: 0.6)),
                      ),
                      child: Text(
                        hasCoords ? 'From $kProviderLabel' : 'Details unavailable',
                        style: GoogleFonts.outfit(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: NoorColors.onGlassGold,
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (hasCoords)
                      Text(
                        '${result.latitude.toStringAsFixed(4)}, '
                        '${result.longitude.toStringAsFixed(4)}',
                        style: GoogleFonts.outfit(fontSize: 11, color: NoorColors.onGlassMuted),
                      ),
                  ],
                ),
              ],
            ),
          ),

          if (!hasCoords)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'No coordinates came back for this place. You can still add it — '
                'the form will ask you to fill them in.',
                style: GoogleFonts.outfit(
                  fontSize: 11.5,
                  color: NoorColors.muted,
                  height: 1.5,
                ),
              ),
            ),

          if (hasCoords) ...<Widget>[
            const SizedBox(height: 18),
            SectionHeader(title: 'Location'),
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Container(
                height: 200,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: NoorColors.gold.withValues(alpha: 0.6)),
                ),
                child: FlutterMap(
                  options: MapOptions(
                    initialCenter: LatLng(result.latitude, result.longitude),
                    initialZoom: 16,
                  ),
                  children: <Widget>[
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.sunesra_app',
                    ),
                    MarkerLayer(
                      markers: <Marker>[
                        Marker(
                          point: LatLng(result.latitude, result.longitude),
                          width: 50,
                          height: 50,
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: NoorColors.emeraldDeep,
                              border: Border.all(color: NoorColors.gold, width: 2),
                            ),
                            child: const Icon(Icons.mosque_outlined, color: NoorColors.white, size: 24),
                          ),
                        ),
                      ],
                    ),
                    const SimpleAttributionWidget(
                      source: Text('© OpenStreetMap contributors'),
                    ),
                  ],
                ),
              ),
            ),
          ],

          const SizedBox(height: 22),
          GradientButton(
            label: 'Add Jamaat Time for this Masjid',
            icon: Icons.access_time_outlined,
            onPressed: () => _addTimes(context),
          ),
          const SizedBox(height: 8),
          Text(
            'Saves this place to the shared list with its coordinates, so it '
            'shows up in “Nearby Masjids” next time.',
            textAlign: TextAlign.center,
            style: GoogleFonts.outfit(
              fontSize: 11,
              color: NoorColors.muted,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
