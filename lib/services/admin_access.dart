import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Who may see the controls that only the app's owner should touch.
///
/// The line is drawn at a signed-in **email**, not a uid, and that is a
/// deliberate choice: a uid is invisible to the person who has to remember it
/// and changes nothing when a device is wiped, while an email is something the
/// owner already knows by heart and can check on any screen the app shows.
/// Comparing case-insensitively after a trim is what makes `Kook80028@Gmail.com`
/// and `kook80028@gmail.com` the same person, because they are.
///
/// Nothing here is a security boundary in the strong sense — the client cannot
/// keep a determined person out of its own code — and it is not pretending to
/// be one. It is a *courtesy boundary*: these controls are diagnostics and
/// tests, useful to the owner and noise to everyone else, so they are hidden
/// rather than gated. The one thing that genuinely needs enforcement lives on
/// the server, in the Firestore rules, where a claim can be checked.
class AdminAccess {
  AdminAccess._();

  /// The single address that owns this app.
  static const String adminEmail = 'kook80028@gmail.com';

  /// Stands in for the signed-in account in tests, where there is no Firebase
  /// to ask and the answer would otherwise always be "nobody".
  ///
  /// Null means "ask FirebaseAuth"; the screens under test read it exactly as
  /// production does, so a crash that only happens behind the owner's door —
  /// an unassigned controller, a build that assumes a document — is one the
  /// test can still walk into.
  @visibleForTesting
  static bool? isAdminOverride;

  /// Whether the signed-in account is the one in [adminEmail].
  ///
  /// `false` rather than a throw when nobody is signed in — a signed-out app
  /// has no owner to show these to, and a panel that crashed on the login
  /// screen would be worse than one that simply stays away — and `false` too
  /// when Firebase has not been asked yet, which is the same answer said
  /// earlier in the app's life.
  static bool get isAdmin {
    final bool? forced = isAdminOverride;
    if (forced != null) return forced;
    try {
      final String? email = FirebaseAuth.instance.currentUser?.email;
      if (email == null) return false;
      return email.trim().toLowerCase() == adminEmail;
    } catch (_) {
      return false;
    }
  }

  /// Same question, as a stream, so a screen can rebuild when the account
  /// changes underneath it — signing out while the panel is open must not
  /// leave its controls live.
  static Stream<bool> get isAdminStream =>
      FirebaseAuth.instance.authStateChanges().map((User? _) => isAdmin);
}
