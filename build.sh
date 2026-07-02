#!/bin/bash
set -e

APP_NAME="工具箱"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"

echo "🔨 正在编译计算器应用..."

# 清理旧版本
rm -rf "$APP_BUNDLE"

# 创建 app bundle 目录结构
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# 复制 xterm.js 终端资源
echo "  → 复制 xterm 资源..."
cp -R "$BUILD_DIR/Resources/xterm" "$RESOURCES_DIR/"
echo "  → xterm 资源复制完成"

# 生成应用图标
echo "  → 生成图标..."
python3 "$BUILD_DIR/generate_icon.py" > /dev/null
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$RESOURCES_DIR/AppIcon.icns"
echo "  → 图标生成完成"

# 编译 Swift 源码为可执行文件
echo "  → 编译中..."
swiftc \
    -o "$MACOS_DIR/Calculator" \
    -framework SwiftUI \
    -framework AppKit \
    -framework UserNotifications \
    -framework WebKit \
    -framework AVFoundation \
    -framework Speech \
    -sdk $(xcrun --show-sdk-path --sdk macosx) \
    -parse-as-library \
    -target arm64-apple-macos13.0 \
    "$BUILD_DIR"/*.swift

echo "  → 编译完成"

# 创建 Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>Calculator</string>
    <key>CFBundleIdentifier</key>
    <string>com.macapp.calculator</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>工具箱</string>
    <key>CFBundleDisplayName</key>
    <string>工具箱</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
            <key>CFBundleIconFile</key>
            <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>工具箱需要访问麦克风以进行录音</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>工具箱需要语音识别权限以将录音转写为文字</string>
</dict>
</plist>
PLIST

# 创建 PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "✅ 编译成功！"
echo ""
echo "📂 应用位置: $APP_BUNDLE"
echo "💡 双击即可运行，或者拖到「应用程序」文件夹中使用"
echo ""
echo "也可以命令行运行: open '$APP_BUNDLE'"
echo ""

# 直接打开
open "$APP_BUNDLE"
