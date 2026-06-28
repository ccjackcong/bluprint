#!/bin/bash
# 配置 Android / macOS 平台权限（从外部文件读取）
# 用法：在 flutter create --platforms=macos . 之后运行此脚本

set -e

echo "🔧 开始配置平台权限..."

# ---------- 工具函数 ----------
# 在文件的指定锚点（独立行）之前插入内容
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

# ---------- Android 权限配置 ----------
ANDROID_MANIFEST="android/app/src/main/AndroidManifest.xml"
ANDROID_PERMS_FILE="platform_config/android_permissions.txt"

if check_file "$ANDROID_MANIFEST"; then
    echo "  → 配置 Android 权限..."

    if check_file "$ANDROID_PERMS_FILE"; then
        # 读取权限文件，过滤空行和注释行（以 # 开头）
        PERM_LINES=$(grep -vE '^\s*$|^\s*#' "$ANDROID_PERMS_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        if [ -z "$PERM_LINES" ]; then
            echo "    ⚠️  权限文件为空，跳过"
        else
            while IFS= read -r perm_line; do
                # 提取权限名称
                if [[ "$perm_line" =~ android:name=\"([^\"]+)\" ]]; then
                    perm_name="${BASH_REMATCH[1]}"
                else
                    echo "    ⚠️  无法解析权限行: $perm_line，跳过"
                    continue
                fi
                
                if grep -q "android:name=\"$perm_name\"" "$ANDROID_MANIFEST"; then
                    echo "    ✅ 权限 $perm_name 已存在"
                else
                    insert_before "$ANDROID_MANIFEST" "</manifest>" "$perm_line"
                    echo "    ➕ 添加权限 $perm_name"
                fi
            done <<< "$PERM_LINES"
        fi
    else
        echo "    ⚠️  未找到 Android 权限配置文件，跳过"
    fi

    # 启用 usesCleartextTraffic（用于 HTTP 服务）
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
fi

# ---------- macOS Entitlements 配置 ----------
MACOS_ENTITLEMENTS_FILE="platform_config/macos_entitlements.txt"

if check_file "$MACOS_ENTITLEMENTS_FILE"; then
    # 解析 entitlements 文件，构建 key-value 数组
    # 假设文件格式为：<key>...</key> 和 <true/> 或 <false/> 交替，忽略空行和注释
    declare -A ENT_MAP
    current_key=""
    while IFS= read -r line; do
        # 去除前后空格
        line_trimmed="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        # 跳过空行和注释（以 # 开头）
        [[ -z "$line_trimmed" || "$line_trimmed" =~ ^# ]] && continue
        # 如果是 <key>...</key>，提取 key 名称
        if [[ "$line_trimmed" =~ ^\<key\>(.+)\</key\>$ ]]; then
            current_key="${BASH_REMATCH[1]}"
        elif [[ -n "$current_key" && "$line_trimmed" =~ ^\<(true|false)\/\>$ ]]; then
            # 遇到 value 行，存储到关联数组
            ENT_MAP["$current_key"]="$line_trimmed"
            current_key=""
        else
            echo "    ⚠️  无法解析 entitlements 行: $line_trimmed"
        fi
    done < "$MACOS_ENTITLEMENTS_FILE"

    if [ ${#ENT_MAP[@]} -eq 0 ]; then
        echo "    ⚠️  macOS entitlements 文件为空或解析失败，跳过"
    else
        echo "  → 配置 macOS entitlements..."
        for ENTITLEMENTS in "macos/Runner/DebugProfile.entitlements" "macos/Runner/Release.entitlements"; do
            if check_file "$ENTITLEMENTS"; then
                for key in "${!ENT_MAP[@]}"; do
                    value="${ENT_MAP[$key]}"
                    if grep -q "<key>$key</key>" "$ENTITLEMENTS"; then
                        echo "    ✅ $key 已存在"
                    else
                        # 插入两行：key 和 value
                        insert_before "$ENTITLEMENTS" "</dict>" "    <key>$key</key>\n    $value"
                        echo "    ➕ 添加 entitlements: $key"
                    fi
                done
            fi
        done
    fi
else
    echo "  ⚠️  未找到 macOS entitlements 配置文件，跳过"
fi

# ---------- macOS Info.plist 蓝牙描述 ----------
INFO_PLIST="macos/Runner/Info.plist"
if check_file "$INFO_PLIST"; then
    echo "  → 配置 macOS Info.plist 蓝牙说明..."
    if ! grep -q 'NSBluetoothAlwaysUsageDescription' "$INFO_PLIST"; then
        insert_before "$INFO_PLIST" "</dict>" "    <key>NSBluetoothAlwaysUsageDescription</key>\n    <string>此应用需要蓝牙权限以连接标签打印机</string>\n    <key>NSBluetoothPeripheralUsageDescription</key>\n    <string>此应用需要蓝牙权限以连接标签打印机</string>"
        echo "    ✅ 蓝牙使用说明已添加"
    else
        echo "    ✅ 蓝牙使用说明已存在"
    fi
fi

echo "✅ 所有平台配置完成"
