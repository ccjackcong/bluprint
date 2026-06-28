#!/bin/bash
# 配置平台权限（兼容 bash 3.2，不使用关联数组）
# 用法: ./configure_platforms.sh [android|macos|all]
#       默认 all

set -e

echo "🔧 开始配置平台权限..."

# 检测运行平台
TARGET="${1:-all}"

# ---------- 工具函数 ----------
# 检查文件是否存在
check_file() {
    if [ ! -f "$1" ]; then
        echo "    ⚠️  文件不存在: $1"
        return 1
    fi
    return 0
}

# 在文件的指定锚点之前插入内容（兼容 macOS sed）
insert_before() {
    local file="$1"
    local anchor="$2"
    local content="$3"
    if grep -Fq "$anchor" "$file"; then
        # macOS 和 Linux 的 sed 兼容写法
        sed -i.bak "/$anchor/i\\
$content" "$file"
        rm -f "${file}.bak"
        return 0
    else
        echo "    ⚠️  未找到锚点 '$anchor'，跳过插入"
        return 1
    fi
}

# ---------- Android 配置 ----------
configure_android() {
    echo "  → 配置 Android 权限..."

    local ANDROID_MANIFEST="android/app/src/main/AndroidManifest.xml"
    local PERMS_FILE="platform_config/android_permissions.txt"

    if ! check_file "$ANDROID_MANIFEST"; then
        echo "    ⚠️  跳过 Android 配置（文件不存在）"
        return
    fi

    if ! check_file "$PERMS_FILE"; then
        echo "    ⚠️  跳过 Android 配置（权限文件不存在）"
        return
    fi

    # 读取权限文件，逐行处理
    while IFS= read -r line || [ -n "$line" ]; do
        # 去除首尾空格
        line_trimmed="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        # 跳过空行和注释行（以 # 开头）
        [ -z "$line_trimmed" ] && continue
        echo "$line_trimmed" | grep -q '^#' && continue

        # 提取权限名称
        if echo "$line_trimmed" | grep -q 'android:name="'; then
            perm_name=$(echo "$line_trimmed" | sed -n 's/.*android:name="\([^"]*\)".*/\1/p')
            if [ -n "$perm_name" ]; then
                if grep -q "android:name=\"$perm_name\"" "$ANDROID_MANIFEST"; then
                    echo "    ✅ 权限 $perm_name 已存在"
                else
                    insert_before "$ANDROID_MANIFEST" "</manifest>" "$line_trimmed"
                    echo "    ➕ 添加权限 $perm_name"
                fi
            fi
        fi
    done < "$PERMS_FILE"

    # 启用 usesCleartextTraffic
    if ! grep -q 'android:usesCleartextTraffic="true"' "$ANDROID_MANIFEST"; then
        sed -i.bak 's|<application|<application android:usesCleartextTraffic="true"|' "$ANDROID_MANIFEST"
        rm -f "${ANDROID_MANIFEST}.bak"
        echo "    ✅ usesCleartextTraffic 已启用"
    else
        echo "    ✅ usesCleartextTraffic 已存在"
    fi

    # 添加 tools 命名空间
    if ! grep -q 'xmlns:tools="http://schemas.android.com/tools"' "$ANDROID_MANIFEST"; then
        sed -i.bak 's|<manifest |<manifest xmlns:tools="http://schemas.android.com/tools" |' "$ANDROID_MANIFEST"
        rm -f "${ANDROID_MANIFEST}.bak"
        echo "    ✅ tools namespace 已添加"
    else
        echo "    ✅ tools namespace 已存在"
    fi
}

# ---------- macOS 配置 ----------
configure_macos() {
    echo "  → 配置 macOS entitlements..."

    local ENT_FILE="platform_config/macos_entitlements.txt"
    if ! check_file "$ENT_FILE"; then
        echo "    ⚠️  跳过 macOS 配置（entitlements 文件不存在）"
        return
    fi

    # 解析 entitlements 文件，构建 key-value 列表（不使用关联数组）
    # 使用两个简单的数组
    KEYS=()
    VALUES=()
    current_key=""
    while IFS= read -r line || [ -n "$line" ]; do
        line_trimmed="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$line_trimmed" ] && continue
        echo "$line_trimmed" | grep -q '^#' && continue

        if echo "$line_trimmed" | grep -q '^<key>'; then
            current_key=$(echo "$line_trimmed" | sed 's/^<key>\(.*\)<\/key>$/\1/')
        elif [ -n "$current_key" ] && echo "$line_trimmed" | grep -q '^<\(true\|false\)/>$'; then
            KEYS+=("$current_key")
            VALUES+=("$line_trimmed")
            current_key=""
        fi
    done < "$ENT_FILE"

    if [ ${#KEYS[@]} -eq 0 ]; then
        echo "    ⚠️  entitlements 解析失败或为空"
        return
    fi

    for ENTITLEMENTS in "macos/Runner/DebugProfile.entitlements" "macos/Runner/Release.entitlements"; do
        if check_file "$ENTITLEMENTS"; then
            for idx in "${!KEYS[@]}"; do
                key="${KEYS[$idx]}"
                value="${VALUES[$idx]}"
                if grep -q "<key>$key</key>" "$ENTITLEMENTS"; then
                    echo "    ✅ $key 已存在"
                else
                    insert_before "$ENTITLEMENTS" "</dict>" "    <key>$key</key>\n    $value"
                    echo "    ➕ 添加 entitlements: $key"
                fi
            done
        fi
    done

    # 配置 Info.plist 蓝牙说明
    local INFO_PLIST="macos/Runner/Info.plist"
    if check_file "$INFO_PLIST"; then
        echo "  → 配置 macOS Info.plist 蓝牙说明..."
        if ! grep -q 'NSBluetoothAlwaysUsageDescription' "$INFO_PLIST"; then
            insert_before "$INFO_PLIST" "</dict>" "    <key>NSBluetoothAlwaysUsageDescription</key>\n    <string>此应用需要蓝牙权限以连接标签打印机</string>\n    <key>NSBluetoothPeripheralUsageDescription</key>\n    <string>此应用需要蓝牙权限以连接标签打印机</string>"
            echo "    ✅ 蓝牙使用说明已添加"
        else
            echo "    ✅ 蓝牙使用说明已存在"
        fi
    fi
}

# ---------- 主入口 ----------
case "$TARGET" in
    android)
        configure_android
        ;;
    macos)
        configure_macos
        ;;
    all|*)
        configure_android
        configure_macos
        ;;
esac

echo "✅ 所有平台配置完成"
