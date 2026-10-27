import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_look.dart';
import '../main.dart' show NoorColors;

/// The Privacy Policy as a page the reader actually reads: the policy lives at
/// a public URL and is shown in an **in-app browser**, so what is on screen is
/// the same document everybody else sees — not a copy that has drifted inside
/// the binary.
///
/// The URL is the policy file in this repository. GitHub renders a Markdown
/// blob as a plain readable document, so it needs no hosting of our own and it
/// can never go out of date relative to the app: the file *is* the policy.
/// (If the owner later switches GitHub Pages on for this repo, point
/// [policyUrl] at that page instead — nothing else changes.)
///
/// A webview can fail — no network, a captive portal, a renamed file. When it
/// does, [fallbackCopy] is shown instead of a blank screen, so the reader is
/// never left without the policy they asked for.
class PrivacyPolicyScreen extends StatefulWidget {
  const PrivacyPolicyScreen({super.key});

  /// Where the live copy lives. Public, no login, no tracking.
  static const String policyUrl =
      'https://github.com/mdssuu/noor-app/blob/master/docs/privacy.md';

  /// The same words the old dialog printed, kept for the offline fallback.
  static const String fallbackCopy =
      '• Your GPS position is used on this device only — to sort the '
      'nearby list, compute prayer times and measure “800m away” '
      'badges. It is never sent to a server.\n\n'
      '• Masjid names, times and photos you submit are written to '
      'Cloud Firestore so neighbours see the same board. Your display '
      'name and profile picture are stored with the update.\n\n'
      '• Photos are stored as a small compressed copy (under 450 KB) so '
      'they load without a separate image host.\n\n'
      '• Board photos are read on your device first. If a Gemini key is '
      'configured, the photo is also sent once to Google so the '
      'Jamaat column can be read; with no key configured the photo '
      'never leaves your phone.\n\n'
      '• Search uses OpenStreetMap’s Nominatim — free, no account, no '
      'tracking. Google Sign-In shares only your name, email and '
      'avatar.\n\n'
      '• Azan reminders, favourites and settings live in local storage on '
      'your phone and are removed when you uninstall the app.\n\n'
      '• No advertising SDK, no analytics, no crash tracker, no selling '
      'of data — the full policy lists every permission and every place '
      'a byte leaves the device.';

  @override
  State<PrivacyPolicyScreen> createState() => _PrivacyPolicyScreenState();
}

class _PrivacyPolicyScreenState extends State<PrivacyPolicyScreen> {
  InAppWebViewController? _web;
  double _progress = 0;
  bool _loaded = false;
  bool _failed = false;

  Future<void> _openExternally() async {
    bool opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(PrivacyPolicyScreen.policyUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
    if (!opened && mounted) {
      debugPrint('Noor ▸ could not open ${PrivacyPolicyScreen.policyUrl}');
    }
  }

  /// Keeps the reader inside this browser for ordinary links, and hands
  /// anything the webview cannot show (a `mailto:`) to the platform.
  Future<NavigationActionPolicy?> _route(
      InAppWebViewController controller, NavigationAction action) async {
    // [WebUri] implements [Uri], so no conversion is needed.
    final Uri? uri = action.request.url;
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return NavigationActionPolicy.ALLOW;
    }
    if (uri != null) {
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        // A link that cannot be followed is not worth breaking the page over.
      }
    }
    return NavigationActionPolicy.CANCEL;
  }

  @override
  Widget build(BuildContext context) {
    return NoorScaffold(
      appBar: AppBar(
        title: const Text('Privacy Policy'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh, size: 21),
            onPressed: () {
              setState(() {
                _failed = false;
                _loaded = false;
                _progress = 0;
              });
              _web?.reload();
            },
          ),
          IconButton(
            tooltip: 'Open in browser',
            icon: const Icon(Icons.open_in_new, size: 20),
            onPressed: _openExternally,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Stack(
        children: <Widget>[
          if (!_failed)
            InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri(PrivacyPolicyScreen.policyUrl),
              ),
              initialSettings: InAppWebViewSettings(
                // The policy is one document: no pinch-zoom chrome, no
                // wide-viewport guesswork — GitHub's prose layout is enough.
                supportZoom: false,
                useWideViewPort: false,
                useShouldOverrideUrlLoading: true,
                // Nothing in a policy page should start making noise.
                mediaPlaybackRequiresUserGesture: true,
              ),
              onWebViewCreated: (InAppWebViewController controller) =>
                  _web = controller,
              onProgressChanged: (InAppWebViewController controller,
                  int progress) {
                if (!mounted) return;
                setState(() => _progress = progress / 100);
              },
              onLoadStop: (InAppWebViewController controller, WebUri? url) {
                if (!mounted) return;
                setState(() {
                  _loaded = true;
                  _failed = false;
                });
              },
              onReceivedError: (InAppWebViewController controller,
                  WebResourceRequest request, WebResourceError error) {
                // Only the page itself matters — a blocked sub-resource
                // (a font, an avatar) must not hide the policy behind an
                // error screen. `null` reads as the main frame too, which is
                // how Android < 21 reports it.
                if (request.isForMainFrame == false || !mounted) return;
                setState(() => _failed = true);
                debugPrint(
                    'Noor ▸ privacy page failed: ${error.description}');
              },
              shouldOverrideUrlLoading: _route,
            ),

          // ------------------------------------------------------ loading
          if (!_failed && !_loaded)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                minHeight: 2,
                backgroundColor: NoorColors.goldSoft,
                color: NoorColors.emeraldDeep,
              ),
            ),

          // ------------------------------------------------------ offline
          if (_failed)
            _OfflineFallback(onRetry: () {
              setState(() {
                _failed = false;
                _loaded = false;
                _progress = 0;
              });
              _web?.reload();
            }),
        ],
      ),
    );
  }
}

/// What the reader sees when the live page cannot be fetched: the policy in
/// full, the address it lives at, and a way back in. Never a blank screen.
class _OfflineFallback extends StatelessWidget {
  const _OfflineFallback({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: NoorColors.goldSoft,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(Icons.wifi_off, size: 18, color: NoorColors.ink),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Offline — showing the copy kept in the app',
                      style: GoogleFonts.outfit(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: NoorColors.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      PrivacyPolicyScreen.policyUrl,
                      style: GoogleFonts.outfit(
                        fontSize: 10.5,
                        color: NoorColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          PrivacyPolicyScreen.fallbackCopy,
          style: GoogleFonts.outfit(fontSize: 12.5, height: 1.6),
        ),
        const SizedBox(height: 18),
        Center(
          child: OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 17),
            label: Text('Try again',
                style: GoogleFonts.outfit(fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }
}
