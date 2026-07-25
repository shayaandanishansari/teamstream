/// The single place the backend location lives — the swappable seam.
///
/// Resolution order:
///   1. --dart-define=PB_URL=...   explicit override (used for local dev, where
///      the Flutter dev server and PocketBase run on different ports).
///   2. web (no override): SAME-ORIGIN. In production the Flutter web app is
///      served *by* PocketBase out of `backend/pb_public/`, so the API lives at
///      the same host that served the page. We talk back to whatever that is —
///      LAN IP, Tailscale name, or the public domain — with zero reconfig.
///   3. native (no override): the public domain (no serving origin exists).
///
/// When TeamStream moves onto the Dash OS mesh, nothing here needs to change on
/// web; for native you'd point the fallback at the mesh hostname.
/// Note: Android emulators reach the host machine via 10.0.2.2, not 127.0.0.1
/// (use --dart-define=PB_URL=http://10.0.2.2:8090 for emulator dev).
library;

import 'package:flutter/foundation.dart' show kIsWeb;

const String _pbUrlOverride = String.fromEnvironment('PB_URL');

final String kPocketBaseUrl = _pbUrlOverride.isNotEmpty
    ? _pbUrlOverride
    : (kIsWeb ? Uri.base.origin : 'https://teamstream.shayaandanishansari.com');
