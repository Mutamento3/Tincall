#!/bin/sh
set -eu

# Xcode strips ONNX's static archive and embeds a generated stub when archiving.
# Its copied plist still declares the upstream minimum, not the stub's minimum.
[ "${ACTION:-}" = install ] && [ "${PLATFORM_NAME:-}" = iphoneos ] || exit 0

onnx_framework="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/onnxruntime.framework"
onnx_minimum=$(/usr/bin/xcrun vtool -show-build "$onnx_framework/onnxruntime" |
    /usr/bin/awk '$1 == "minos" { print $2; exit }')
if [ -z "$onnx_minimum" ]; then
    echo "error: Cannot read the embedded ONNX framework's minimum iOS version." >&2
    exit 1
fi

/usr/bin/plutil -replace MinimumOSVersion -string "$onnx_minimum" "$onnx_framework/Info.plist"

# The automatic framework copy may already have signed the stub. Sign again
# after changing its metadata; Xcode signs the containing app after this phase.
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
    : "${EXPANDED_CODE_SIGN_IDENTITY:?Missing signing identity for embedded ONNX framework}"
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
        --preserve-metadata=identifier,entitlements,flags \
        --generate-entitlement-der "$onnx_framework"
fi

echo "Embedded ONNX framework minimum iOS version: $onnx_minimum"
