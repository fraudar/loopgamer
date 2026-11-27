#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

SDK_ROOT="$HOME/.local/share/loopgamer-toolchain"
JDK_DIR="$SDK_ROOT/jdk-17"
ANDROID_SDK_DIR="$SDK_ROOT/android-sdk"
FLUTTER_DIR="$SDK_ROOT/flutter"
# O toolchain pinado em 3.35.7 fica em flutter35; o 3.50 quebra
# phosphor_flutter (IconData virou final). Prefere o pinado quando existe.
if [ -x "$SDK_ROOT/flutter35/flutter/bin/flutter" ]; then
  FLUTTER_DIR="$SDK_ROOT/flutter35/flutter"
fi

mkdir -p "$SDK_ROOT"

# 1. Usa ou baixa OpenJDK 17 portátil
if ! command -v javac >/dev/null 2>&1; then
  if [ ! -x "$JDK_DIR/bin/javac" ]; then
    echo "==> [1/4] Baixando OpenJDK 17 portátil..."
    JDK_TAR="$SDK_ROOT/openjdk17.tar.gz"
    curl -L --fail --progress-bar \
      "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.12%2B7/OpenJDK17U-jdk_x64_linux_hotspot_17.0.12_7.tar.gz" \
      -o "$JDK_TAR"
    mkdir -p "$JDK_DIR"
    tar -xzf "$JDK_TAR" -C "$JDK_DIR" --strip-components=1
    rm -f "$JDK_TAR"
  fi
  export JAVA_HOME="$JDK_DIR"
  export PATH="$JAVA_HOME/bin:$PATH"
fi

# 2. Configura Android SDK + NDK
export ANDROID_HOME="$ANDROID_SDK_DIR"
export ANDROID_SDK_ROOT="$ANDROID_SDK_DIR"
export PATH="$ANDROID_SDK_DIR/cmdline-tools/latest/bin:$ANDROID_SDK_DIR/platform-tools:$PATH"

# 3. Configura Flutter SDK
export PATH="$FLUTTER_DIR/bin:$PATH"

# 4. Garante Gradle 8.7 no gradle-wrapper.properties (exigido pelo AGP 8.5.2)
cat > "$PROJECT_DIR/android/gradle/wrapper/gradle-wrapper.properties" << 'EOF'
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-8.7-all.zip
EOF

echo "==> Compilando LoopGamer APK Release (Gradle 8.7 + NDK 27 + Libretro JNI)..."
flutter pub get

flutter build apk --release \
  --target-platform android-arm64 \
  --split-per-abi \
  --dart-define=IGDB_CLIENT_ID="${IGDB_CLIENT_ID:-}" \
  --dart-define=IGDB_CLIENT_SECRET="${IGDB_CLIENT_SECRET:-}" \
  --dart-define=SGDB_API_KEY="${SGDB_API_KEY:-}"

APK_OUT="$PROJECT_DIR/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
if [ ! -f "$APK_OUT" ]; then
  APK_OUT="$PROJECT_DIR/build/app/outputs/flutter-apk/app-release.apk"
fi
if [ -f "$APK_OUT" ]; then
  cp "$APK_OUT" "$PROJECT_DIR/loopgamer-release.apk"
  echo ""
  echo "=================================================================="
  echo " APK GERADO COM SUCESSO:"
  echo " $PROJECT_DIR/loopgamer-release.apk"
  echo "=================================================================="
else
  echo "ERRO: APK release não encontrado em $PROJECT_DIR/build/app/outputs/flutter-apk/" >&2
  exit 1
fi
