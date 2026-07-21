#!/bin/bash
# Automatically increments the build number (CFBundleVersion) in Info.plist during Xcode Archive / Release builds

INFOPLIST_PATH="${PROJECT_DIR}/Info.plist"
if [ ! -f "$INFOPLIST_PATH" ]; then
    INFOPLIST_PATH="./NudgeAlarm/Info.plist"
fi

if [ -f "$INFOPLIST_PATH" ]; then
    # Generate a unique, strictly increasing build number based on current date & timestamp (e.g. 202607212325)
    BUILD_NUMBER=$(date +%Y%m%d%H%M)
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFOPLIST_PATH" || true
    echo "PulseWake: Set build number (CFBundleVersion) to $BUILD_NUMBER in $INFOPLIST_PATH"
fi
