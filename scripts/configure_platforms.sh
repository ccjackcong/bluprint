#!/bin/bash
# 配置 Android / macOS 平台的蓝牙、网络等权限（适用于 GitHub Actions）
# 用法：在 flutter create --platforms=macos . 之后运行此脚本

set -e

echo "🔧 开始配置平台权限..."

# ---------- 工具函数 ----------
# 安全地插入一段内容到文件的指定锚点之前（锚点必须是独立行，且内容不包含特殊字符）
insert_before() {
    local file="$1"
    local anchor="$2"
    local content="$3"
    if grep -Fq "$anchor" "$file"; then
        sed -i.bak "/$anchor/i\\
$content" "$file"
        rm -f "${file}.bak"
        return 0
    else
        echo "    ⚠️  未找到锚点 '$anchor'，跳过插入"
        return 1
    fi
}

# 检查文件是否存在
check_file() {
    if [ ! -f "$1" ]; then
        echo "    ⚠️  文件不存在: $1"
        return 1
    fi
    return 0
}

# ---------- Android 配置 ----------
ANDROID_MANIFEST="android/app/src/main/AndroidManifest.xml"
if check_file "$ANDROID_MANIFEST"; then
    echo "  → 配置 Android 权限..."

    # 定义需要添加的权限列表（每个权限一行，不含 <uses-permission> 标签）
    # 注意：BLUETOOTH_SCAN 使用 neverForLocation，BLUETOOTH_CONNECT 指定 targetApi="s"
    declare -A PERMS=(
        ["android.permission.BLUETOOTH"]='<uses-permission android:name="android.permission.BLUETOOTH" />'
        ["android.permission.BLUETOOTH_ADMIN"]='<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />'
        ["android.permission.BLUETOOTH_SCAN"]='<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" tools:targetApi="s" />'
        ["android.permission.BLUETOOTH_CONNECT"]='<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" tools:targetApi="s" />'
        ["android.permission.ACCESS_FINE_LOCATION"]='<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />'
        ["android.permission.ACCESS_COARSE_LOCATION"]='<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />'
        ["android.permission.INTERNET"]='<uses-permission android:name="android.permission.INTERNET" />'
    )

    # 逐个检查并添加缺失的权限
    for perm_name in "${!PERMS[@]}"; do
        if grep -q "android:name=\"$perm_name\"" "$ANDROID_MANIFEST"; then
            echo "    ✅ 权限 $perm_name 已存在"
        else
            # 在 </manifest> 前插入该权限
            insert_before "$ANDROID_MANIFEST" "</manifest>" "${PERMS[$perm_name]}"
            echo "    ➕ 添加权限 $perm_name"
        fi
    done

    # 添加 usesCleartextTraffic（允许明文流量，用于 HTTP 服务）
    if ! grep -q 'android:usesCleartextTraffic="true"' "$ANDROID_MANIFEST"; then
        sed -i.bak 's|<application|<application android:usesCleartextTraffic="true"|' "$ANDROID_MANIFEST"
        rm -f "${ANDROID_MANIFEST}.bak"
        echo "    ✅ usesCleartextTraffic 已启用"
    else
        echo "    ✅ usesCleartextTraffic 已存在"
    fi

    # 添加 tools 命名空间（如果缺失）
    if ! grep -q 'xmlns:tools="http://schemas.android.com/tools"' "$ANDROID_MANIFEST"; then
        sed -i.bak 's|<manifest |<manifest xmlns:tools="http://schemas.android.com/tools" |' "$ANDROID_MANIFEST"
        rm -f "${ANDROID_MANIFEST}.bak"
        echo "    ✅ tools namespace 已添加"
    else
        echo "    ✅ tools namespace 已存在"
    fi
fi

# ---------- macOS 配置 ----------
echo "  → 配置 macOS entitlements..."

for ENTITLEMENTS in "macos/Runner/DebugProfile.entitlements" "macos/Runner/Release.entitlements"; do
    if check_file "$ENTITLEMENTS"; then
        # 需要添加的 entitlements key
        declare -A ENT_KEYS=(
            ["com.apple.security.device.bluetooth"]="true"
            ["com.apple.security.network.server"]="true"
            ["com.apple.security.network.client"]="true"
        )

        for key in "${!ENT_KEYS[@]}"; do
            if grep -q "<key>$key</key>" "$ENTITLEMENTS"; then
                echo "    ✅ $key 已存在"
            else
                # 在 </dict> 前插入新的 key-value 对
                insert_before "$ENTITLEMENTS" "</dict>" "    <key>$key</key>\n    <${ENT_KEYS[$key]}/>"
                echo "    ➕ 添加 entitlements: $key"
            fi
        done
    fi
done

# 配置 macOS Info.plist 蓝牙使用说明
INFO_PLIST="macos/Runner/Info.plist"
if check_file "$INFO_PLIST"; then
    echo "  → 配置 macOS Info.plist 蓝牙说明..."

    # 插入蓝牙使用说明（如果缺失）
    if ! grep -q 'NSBluetoothAlwaysUsageDescription' "$INFO_PLIST"; then
        # 在 </dict> 前插入两个 key
        insert_before "$INFO_PLIST" "</dict>" "    <key>NSBluetoothAlwaysUsageDescription</key>\n    <string>此应用需要蓝牙权限以连接标签打印机</string>\n    <key>NSBluetoothPeripheralUsageDescription</key>\n    <string>此应用需要蓝牙权限以连接标签打印机</string>"
        echo "    ✅ 蓝牙使用说明已添加"
    else
        echo "    ✅ 蓝牙使用说明已存在"
    fi
fi

echo "✅ 所有平台配置完成"
