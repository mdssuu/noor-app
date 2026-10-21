#!/usr/bin/env bash
# Runs once, right after the Codespace / dev container is created.
# Installs the CURRENT Flutter stable so the SDK matches pubspec's ^3.13.5.
set -euo pipefail

FLUTTER_HOME="/opt/flutter"

echo "==> Installing Flutter (stable channel)..."

if [ ! -x "$FLUTTER_HOME/bin/flutter" ]; then
  sudo rm -rf "$FLUTTER_HOME"
  git clone --depth 1 -b stable https://github.com/flutter/flutter.git "$FLUTTER_HOME"
  sudo chown -R "$(id -u):$(id -g)" "$FLUTTER_HOME"
fi

# Flutter refuses to run inside a directory git doesn't own.
git config --global --add safe.directory "$FLUTTER_HOME"

export PATH="$FLUTTER_HOME/bin:$FLUTTER_HOME/bin/cache/dart-sdk/bin:$PATH"

flutter config --no-analytics >/dev/null 2>&1 || true
dart  --disable-analytics >/dev/null 2>&1 || true

echo "==> Flutter version:"
flutter --version

echo "==> Installing project dependencies..."
flutter pub get

echo "==> Done. Open lib/main.dart and start coding."
