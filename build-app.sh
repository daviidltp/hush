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
# Sparkle (actualizaciones): el framework va en Contents/Frameworks, con sus enlaces simbólicos intactos.
mkdir -p "$APP/Contents/Frameworks"
ditto .build/$CONFIG/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Boveda" 2>/dev/null || true
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Color de acento negro (en vez del azul del sistema) para selecciones e interruptores.
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 15.0 >/dev/null
VERSION=$(cat VERSION)
# Certificado para firmar: variable SIGN_IDENTITY o archivo local .sign-identity (no se sube a git).
# Sin ninguno, firma ad hoc («-»): funciona en tu Mac, pero Touch ID y el llavero piden una firma estable.
[[ -z $SIGN_IDENTITY && -f .sign-identity ]] && SIGN_IDENTITY=$(<.sign-identity)
SIGN_IDENTITY=${SIGN_IDENTITY:--}
# Las versiones publicadas llevan sello de tiempo de Apple (lo exige la notarización); en local no hace falta.
TIMESTAMP=${TIMESTAMP:---timestamp=none}
# Actualizaciones automáticas: solo en las versiones publicadas (UPDATES=1, lo pone el flujo de GitHub).
UPDATE_KEYS=""
[[ $UPDATES == 1 ]] && UPDATE_KEYS="<key>SUFeedURL</key><string>https://github.com/daviidltp/hush/releases/latest/download/appcast.xml</string>
<key>SUPublicEDKey</key><string>$(<Resources/sparkle-public-key.txt)</string>
<key>SUEnableAutomaticChecks</key><true/>"
# La versión de pruebas usa otro identificador para no mezclar sus ajustes con la app real.
BUNDLE_ID=com.david.boveda
NATIVE_HOST=com.david.hush
[[ $CONFIG == debug ]] && { BUNDLE_ID=com.david.boveda.dev; NATIVE_HOST=com.david.hush.dev; }
# Extensión del navegador (carpeta para Chrome/Brave y .xpi para Firefox/Zen).
python3 Extension/build.py "$APP/Contents/Resources/Extension" "$NATIVE_HOST" "$VERSION"
# Traducciones: <idioma>.lproj/Localizable.strings a partir de Resources/i18n (ver scripts/i18n.py).
LOCALIZATIONS=""
for lang in $(python3 scripts/i18n.py build "$APP/Contents/Resources"); do LOCALIZATIONS+="<string>$lang</string>"; done
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
<key>CFBundleVersion</key><string>${VERSION}</string>
${UPDATE_KEYS}
<key>CFBundleDevelopmentRegion</key><string>es</string>
<key>CFBundleLocalizations</key><array>${LOCALIZATIONS}</array>
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
codesign --force --options runtime $TIMESTAMP --identifier "${BUNDLE_ID}.bridge" --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/hush-bridge"
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
codesign --force --options runtime $TIMESTAMP --sign "$SIGN_IDENTITY" "$MENU"
# Sparkle se firma de dentro afuera con el mismo certificado que la app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for part in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
  codesign --force --options runtime $TIMESTAMP --preserve-metadata=entitlements --sign "$SIGN_IDENTITY" "$SPARKLE/$part"
done
codesign --force --options runtime $TIMESTAMP --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime $TIMESTAMP --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"
# La versión de pruebas no se instala.
[[ $CONFIG == debug ]] && { echo "Versión de pruebas en $APP"; exit 0; }
# El flujo de versiones solo quiere la app en build/ (INSTALL=0).
[[ $INSTALL == 0 ]] && { echo "App en $APP"; exit 0; }
mkdir -p ~/Applications
rm -rf ~/Applications/Hush.app
cp -R "$APP" ~/Applications/Hush.app
mdimport ~/Applications/Hush.app
echo "Instalada en ~/Applications/Hush.app"
