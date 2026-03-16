#!/bin/bash
set -euo pipefail

# Configuration
APP_NAME="AIPointer"
BUNDLE_ID="com.aipointer.app"
VERSION="1.0.0"
BUILD_NUMBER="1"
MIN_OS="26.0"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/.build/release"
DIST_DIR="${PROJECT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"

echo "==> Cleaning previous build artifacts..."
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

# Step 1: Build release
echo "==> Building release..."
cd "${PROJECT_DIR}"
swift build -c release

EXECUTABLE="${BUILD_DIR}/${APP_NAME}"
if [ ! -f "${EXECUTABLE}" ]; then
    echo "ERROR: Executable not found at ${EXECUTABLE}"
    exit 1
fi

# Step 2: Create .app bundle structure
echo "==> Creating .app bundle..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${EXECUTABLE}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Copy SPM resource bundle (contains videos, icons used by Bundle.module)
# Place in Contents/Resources/ — Bundle.module is overridden in code to find it here.
RESOURCE_BUNDLE="${BUILD_DIR}/AIPointer_AIPointer.bundle"
if [ -d "${RESOURCE_BUNDLE}" ]; then
    cp -R "${RESOURCE_BUNDLE}" "${APP_BUNDLE}/Contents/Resources/AIPointer_AIPointer.bundle"
    echo "    Copied resource bundle"
fi

# Compile app icon via actool
ACTOOL_OUT="${DIST_DIR}/actool-out"
mkdir -p "${ACTOOL_OUT}"
xcrun actool \
    --output-format human-readable-text \
    --platform macosx \
    --minimum-deployment-target "${MIN_OS}" \
    --app-icon appicon \
    --output-partial-info-plist "${ACTOOL_OUT}/partial.plist" \
    --compile "${ACTOOL_OUT}" \
    "${PROJECT_DIR}/AIPointer/Resources/appicon.icon" > /dev/null
cp "${ACTOOL_OUT}/appicon.icns" "${APP_BUNDLE}/Contents/Resources/appicon.icns"

# Step 3: Create Info.plist
cat > "${APP_BUNDLE}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>AIPointer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_OS}</string>
    <key>CFBundleIconFile</key>
    <string>appicon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>NSAccessibilityUsageDescription</key>
    <string>AIPointer needs Accessibility access to detect mouse and keyboard events.</string>
    <key>NSInputMonitoringUsageDescription</key>
    <string>AIPointer needs Input Monitoring access to respond to the Fn shortcut key.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>AIPointer needs Screen Recording access to take screenshots and send them to AI.</string>
</dict>
</plist>
PLIST

# Step 4: Create entitlements for distribution
cat > "${DIST_DIR}/entitlements.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
PLIST

# Step 5: Code sign + strip quarantine for local testing
echo "==> Code signing..."
xattr -cr "${APP_BUNDLE}"
codesign --force --deep --sign "Developer ID Application: Han Li (GV33A558Z4)" \
    --entitlements "${DIST_DIR}/entitlements.plist" \
    "${APP_BUNDLE}"

# Step 6: Create DMG
echo "==> Creating DMG..."
# Create a temporary directory for DMG contents
DMG_STAGING="${DIST_DIR}/dmg-staging"
mkdir -p "${DMG_STAGING}"
cp -R "${APP_BUNDLE}" "${DMG_STAGING}/"

# Add a symlink to /Applications for drag-and-drop install
ln -s /Applications "${DMG_STAGING}/Applications"

# Create DMG
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGING}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

# Cleanup staging
rm -rf "${DMG_STAGING}"
rm -f "${DIST_DIR}/entitlements.plist"

echo ""
echo "==> Done! DMG created at:"
echo "    ${DMG_PATH}"
echo ""
echo "    App bundle: ${APP_BUNDLE}"
ls -lh "${DMG_PATH}"
