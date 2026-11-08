#!/bin/zsh
# Compila Hush, la empaqueta como app, la firma e instala en ~/Applications.
set -e
cd "$(dirname "$0")"
CONFIG=${CONFIG:-release}
swift build -c $CONFIG
APP="build/Hush.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/$CONFIG/Boveda "$APP/Contents/MacOS/Boveda"
cp .build/$CONFIG/HushBridge "$APP/Contents/MacOS/hush-bridge"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Color de acento negro (en vez del azul del sistema) para selecciones e interruptores.
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 15.0 >/dev/null
VERSION=$(cat VERSION)
# Certificado para firmar: variable SIGN_IDENTITY o archivo local .sign-identity (no se sube a git).
# Sin ninguno, firma ad hoc («-»): funciona en tu Mac, pero Touch ID y el llavero piden una firma estable.
[[ -z $SIGN_IDENTITY && -f .sign-identity ]] && SIGN_IDENTITY=$(<.sign-identity)
SIGN_IDENTITY=${SIGN_IDENTITY:--}
# La versión de pruebas usa otro identificador para no mezclar sus ajustes con la app real.
BUNDLE_ID=com.david.boveda
NATIVE_HOST=com.david.hush
[[ $CONFIG == debug ]] && { BUNDLE_ID=com.david.boveda.dev; NATIVE_HOST=com.david.hush.dev; }
# Extensión del navegador (carpeta para Chrome/Brave y .xpi para Firefox/Zen).
python3 Extension/build.py "$APP/Contents/Resources/Extension" "$NATIVE_HOST" "$VERSION"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
<key>CFBundleName</key><string>Hush</string>
<key>CFBundleDisplayName</key><string>Hush</string>
<key>CFBundleExecutable</key><string>Boveda</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSAccentColorName</key><string>AccentColor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleDevelopmentRegion</key><string>es</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSFaceIDUsageDescription</key><string>Hush usa Touch ID para abrir tu base de datos sin escribir la contraseña maestra.</string>
<key>CFBundleDocumentTypes</key><array><dict>
  <key>CFBundleTypeName</key><string>Base de datos KeePass</string>
  <key>CFBundleTypeRole</key><string>Editor</string>
  <key>LSHandlerRank</key><string>Alternate</string>
  <key>LSItemContentTypes</key><array><string>com.david.boveda.kdbx</string></array>
</dict></array>
<key>UTImportedTypeDeclarations</key><array><dict>
  <key>UTTypeIdentifier</key><string>com.david.boveda.kdbx</string>
  <key>UTTypeDescription</key><string>Base de datos KeePass</string>
  <key>UTTypeConformsTo</key><array><string>public.data</string></array>
  <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>kdbx</string></array></dict>
</dict></array>
</dict></plist>
PLIST
# Hardened runtime: impide que otros procesos inyecten código en la app.
codesign --force --options runtime --timestamp=none --identifier "${BUNDLE_ID}.bridge" --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/hush-bridge"
# Ayudante del icono de la barra de menús: en macOS 26 una app SwiftUI no logra mostrarlo; una de AppKit sí.
MENU="$APP/Contents/Helpers/HushMenu.app"
mkdir -p "$MENU/Contents/MacOS" "$MENU/Contents/Resources"
cp .build/$CONFIG/HushMenu "$MENU/Contents/MacOS/HushMenu"
cp Resources/Assets.xcassets/MenuBarIcon.imageset/menubar.png Resources/Assets.xcassets/MenuBarIcon.imageset/menubar@2x.png "$MENU/Contents/Resources/"
cat > "$MENU/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${BUNDLE_ID}.menu</string>
<key>CFBundleName</key><string>Hush</string>
<key>CFBundleDisplayName</key><string>Hush</string>
<key>CFBundleExecutable</key><string>HushMenu</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$MENU"
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"
# La versión de pruebas no se instala.
[[ $CONFIG == debug ]] && { echo "Versión de pruebas en $APP"; exit 0; }
mkdir -p ~/Applications
rm -rf ~/Applications/Hush.app
cp -R "$APP" ~/Applications/Hush.app
mdimport ~/Applications/Hush.app
echo "Instalada en ~/Applications/Hush.app"
