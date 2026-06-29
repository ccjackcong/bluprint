#!/bin/bash
# 在 flutter create . 之后运行此脚本，配置 Android/macOS 平台权限

set -e

echo "🔧 配置平台权限..."

# ========== Android 配置 ==========

ANDROID_MANIFEST="android/app/src/main/AndroidManifest.xml"

if [ -f "$ANDROID_MANIFEST" ]; then
    echo "  → 配置 Android 权限..."

    # 检查是否已有 BLUETOOTH_SCAN（Android 12+ 版带 neverForLocation）
    if grep -q 'neverForLocation' "$ANDROID_MANIFEST" 2>/dev/null; then
        echo "    Android 蓝牙权限已存在，跳过"
    else
        echo "    ✅ 写入蓝牙权限..."
        python3 << 'PYEOF'
import re

path = "android/app/src/main/AndroidManifest.xml"

with open(path, 'r') as f:
    content = f.read()

# 1. 删除所有可能残留的蓝牙/定位权限
for perm in ['BLUETOOTH', 'BLUETOOTH_ADMIN', 'BLUETOOTH_SCAN', 'BLUETOOTH_CONNECT',
             'ACCESS_FINE_LOCATION', 'ACCESS_COARSE_LOCATION']:
    content = re.sub(
        r'\s*<uses-permission[^>]*' + re.escape(perm) + r'[^>]*/?>\s*',
        '\n',
        content
    )

# 2. 写入标准权限集
perms = '''
    <!-- 蓝牙相关权限 -->
    <uses-permission android:name="android.permission.BLUETOOTH" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <uses-permission android:name="android.permission.INTERNET" />
    <!-- Android 12+ -->
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN"
        android:usesPermissionFlags="neverForLocation"
        tools:targetApi="s" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT"
        tools:targetApi="s" />
'''

content = re.sub(r'\n{3,}', '\n\n', content)
content = content.replace('</manifest>', perms + '\n</manifest>')

with open(path, 'w') as f:
    f.write(content)
PYEOF
    fi

    # 添加 usesCleartextTraffic
    if ! grep -q 'android:usesCleartextTraffic' "$ANDROID_MANIFEST"; then
        sed -i.bak 's|<application|<application android:usesCleartextTraffic="true"|' "$ANDROID_MANIFEST"
        echo "    ✅ usesCleartextTraffic 已启用"
    fi

    # 添加 tools 命名空间
    if ! grep -q 'xmlns:tools' "$ANDROID_MANIFEST"; then
        sed -i.bak 's|<manifest |<manifest xmlns:tools="http://schemas.android.com/tools" |' "$ANDROID_MANIFEST"
        echo "    ✅ tools namespace 已添加"
    fi

    rm -f "${ANDROID_MANIFEST}.bak"
fi

# ========== 设置 App 显示名称 ==========
echo "  → 设置 Android app label..."

if [ -f "$ANDROID_MANIFEST" ]; then
    sed -i.bak 's|android:label="[^"]*"|android:label="SANJOY"|' "$ANDROID_MANIFEST"
    rm -f "${ANDROID_MANIFEST}.bak"
    echo "    ✅ Android label → SANJOY"
fi

# macOS: CFBundleDisplayName → "SANJOY"
INFO_PLIST_MAC="macos/Runner/Info.plist"
if [ -f "$INFO_PLIST_MAC" ]; then
    echo "  → 设置 macOS Bundle Display Name..."
    if grep -q 'CFBundleDisplayName' "$INFO_PLIST_MAC" 2>/dev/null; then
        sed -i.bak 's|<key>CFBundleDisplayName</key>.*<string>[^<]*</string>|<key>CFBundleDisplayName</key>\n    <string>SANJOY</string>|' "$INFO_PLIST_MAC"
    else
        sed -i.bak 's|</dict>|    <key>CFBundleDisplayName</key>\n    <string>SANJOY</string>\n</dict>|' "$INFO_PLIST_MAC"
    fi
    rm -f "${INFO_PLIST_MAC}.bak"
    echo "    ✅ macOS Bundle Display Name → SANJOY"
fi

# ========== macOS 配置 ==========

for ENTITLEMENTS in "macos/Runner/DebugProfile.entitlements" "macos/Runner/Release.entitlements"; do
    if [ -f "$ENTITLEMENTS" ]; then
        echo "  → 配置 macOS entitlements: $ENTITLEMENTS"

        # 添加蓝牙权限
        if ! grep -q 'com.apple.security.device.bluetooth' "$ENTITLEMENTS"; then
            sed -i.bak 's|</dict>|    <key>com.apple.security.device.bluetooth</key>\n    <true/>\n</dict>|' "$ENTITLEMENTS"
            echo "    ✅ 蓝牙权限已添加"
        fi

        # 添加网络权限
        if ! grep -q 'com.apple.security.network.server' "$ENTITLEMENTS"; then
            sed -i.bak 's|</dict>|    <key>com.apple.security.network.server</key>\n    <true/>\n</dict>|' "$ENTITLEMENTS"
            echo "    ✅ 网络服务端权限已添加"
        fi

        if ! grep -q 'com.apple.security.network.client' "$ENTITLEMENTS"; then
            sed -i.bak 's|</dict>|    <key>com.apple.security.network.client</key>\n    <true/>\n</dict>|' "$ENTITLEMENTS"
            echo "    ✅ 网络客户端权限已添加"
        fi

        rm -f "${ENTITLEMENTS}.bak"
    fi
done

# 配置 macOS Info.plist 蓝牙权限说明
INFO_PLIST="macos/Runner/Info.plist"
if [ -f "$INFO_PLIST" ]; then
    echo "  → 配置 macOS Info.plist 蓝牙说明..."

    if ! grep -q 'NSBluetoothAlwaysUsageDescription' "$INFO_PLIST"; then
        sed -i.bak 's|</dict>|    <key>NSBluetoothAlwaysUsageDescription</key>\n    <string>此应用需要蓝牙权限以连接标签打印机</string>\n    <key>NSBluetoothPeripheralUsageDescription</key>\n    <string>此应用需要蓝牙权限以连接标签打印机</string>\n</dict>|' "$INFO_PLIST"
        echo "    ✅ 蓝牙权限说明已添加"
    fi

    rm -f "${INFO_PLIST}.bak"
fi

echo "✅ 平台配置完成"
