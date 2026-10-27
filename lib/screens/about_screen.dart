import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_look.dart';
import '../main.dart' show GoldCard, NoorColors, SectionHeader;
import 'privacy_policy_screen.dart';

/// The app's own page: what version this is, who built it, and how to reach
/// him. Opened from the Profile tab's "About Noor" row.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  /// Where help requests, bug reports and masjid-owners' questions land.
  static const String supportEmail = 'mdsunesra@gmail.com';

  /// The public, no-login APK — the same link the app is shared with.
  ///
  /// `releases/download/latest/...` hamesha wahi file deta hai jo har
  /// `master` push par update hoti hai. (`mdssuu/noor-apk` naam ki koi repo
  /// hai hi nahi - purana link 404 deta tha.)
  static const String downloadUrl =
      'https://github.com/mdssuu/noor-app/releases/download/latest/noor-masjid-time-latest.apk';

  /// The listing this build would open on Google Play.
  ///
  /// The package is `com.sunesra_app`, and as of writing Play returns 404 for
  /// it — the app ships as the APK above, not through Play. This therefore
  /// points at the Play search for the app's own name: it opens the store, it
  /// never pretends to be a listing that does not exist, and the day the app
  /// is published the same constant takes the exact
  /// `store/apps/details?id=com.sunesra_app` URL and nothing else changes.
  static const String playStoreUrl =
      'https://play.google.com/store/search?q=Noor%20Masjid%20Time&c=apps';

  Future<void> _open(String url) async {
    bool opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
    if (!opened) debugPrint('Noor ▸ could not open $url');
  }

  @override
  Widget build(BuildContext context) {
    return NoorScaffold(
      appBar: AppBar(title: const Text('About Noor')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          // ================================================== identity
          Center(
            child: Column(
              children: <Widget>[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(26),
                  child: Image.asset(
                    'assets/logo/noor_logo.jpg',
                    width: 128,
                    height: 128,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Noor • Masjid Time',
                  style: GoogleFonts.amiri(
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                    color: NoorColors.ink,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Real Masjid, Real Time.',
                  style: GoogleFonts.outfit(
                    fontSize: 12.5,
                    color: NoorColors.muted,
                  ),
                ),
                const SizedBox(height: 12),
                FutureBuilder<PackageInfo>(
                  future: PackageInfo.fromPlatform(),
                  builder:
                      (BuildContext context, AsyncSnapshot<PackageInfo> snap) {
                    if (!snap.hasData) return const SizedBox.shrink();
                    final PackageInfo info = snap.data!;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 13, vertical: 6),
                      decoration: BoxDecoration(
                        color: NoorColors.goldSoft,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'Version ${info.version} (${info.buildNumber})',
                        style: GoogleFonts.outfit(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: NoorColors.emeraldDeep,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ================================================== developer
          const SectionHeader(title: 'Developer'),
          GoldCard(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Icon(Icons.code_outlined,
                    size: 20, color: NoorColors.gold),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Mohammad Siddique Sunesra',
                        style: GoogleFonts.outfit(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: NoorColors.ink,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Designed and developed by Mohammad Siddique '
                        'Sunesra — every screen, prayer window and Azaan '
                        'reminder in this app was built by hand.',
                        style: GoogleFonts.outfit(
                          fontSize: 11.5,
                          height: 1.55,
                          color: NoorColors.onGlassMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 6),

          // ================================================== help & contact
          const SectionHeader(title: 'Help & contact'),
          GoldCard(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Column(
              children: <Widget>[
                _AboutRow(
                  icon: Icons.mail_outlined,
                  title: 'Email the developer',
                  subtitle: supportEmail,
                  onTap: () => _open(
                    'mailto:$supportEmail?subject='
                    '${Uri.encodeComponent('Noor app — help')}',
                  ),
                ),
                Divider(height: 1, color: NoorColors.gold.withValues(alpha: 0.25)),
                _AboutRow(
                  icon: Icons.download_outlined,
                  title: 'Download / update the app',
                  subtitle: 'The latest APK — share this link with anyone',
                  onTap: () => _open(downloadUrl),
                ),
                Divider(height: 1, color: NoorColors.gold.withValues(alpha: 0.25)),
                _AboutRow(
                  icon: Icons.storefront_outlined,
                  title: 'Find it on Google Play',
                  subtitle: 'Search the store for “Noor • Masjid Time”',
                  onTap: () => _open(playStoreUrl),
                ),
                Divider(height: 1, color: NoorColors.gold.withValues(alpha: 0.25)),
                _AboutRow(
                  icon: Icons.shield_outlined,
                  title: 'Privacy Policy',
                  // Same screen Settings opens: the live page in an in-app
                  // browser, with the URL in its own bar so it can be copied
                  // or read outside the app.
                  subtitle: 'Read it in the in-app browser',
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => const PrivacyPolicyScreen(),
                    ),
                  ),
                ),
                Divider(height: 1, color: NoorColors.gold.withValues(alpha: 0.25)),
                _AboutRow(
                  icon: Icons.description_outlined,
                  title: 'Open-source licenses',
                  subtitle: 'The packages Noor is built on',
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'Noor • Masjid Time',
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),
          Center(
            child: Text(
              '© 2026 Noor • Masjid Time\nMade with Flutter',
              textAlign: TextAlign.center,
              style: GoogleFonts.outfit(
                fontSize: 11,
                height: 1.6,
                color: NoorColors.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One tappable row on the white cards — the Profile tab's row shape,
/// redrawn here so About does not reach into main.dart's private widget.
class _AboutRow extends StatelessWidget {
  const _AboutRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Row(
            children: <Widget>[
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: NoorColors.goldSoft,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, size: 18, color: NoorColors.emeraldDeep),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: GoogleFonts.outfit(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: NoorColors.ink,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                        fontSize: 10.5,
                        color: NoorColors.onGlassMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  size: 20, color: NoorColors.muted.withValues(alpha: 0.7)),
            ],
          ),
        ),
      ),
    );
  }
}
