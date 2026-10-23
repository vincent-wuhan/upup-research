#!/usr/bin/env bash
# Maestro S0-S5 回归入口。真机需已配置 UpUp gateway provider（upup.yueming.xin）。
# 用法:
#   scripts/maestro-run.sh            # 跑 S1-S5（保留应用数据）
#   scripts/maestro-run.sh s0         # 额外跑 S0（先清应用数据，走首启流程）
#   scripts/maestro-run.sh s1 s3      # 只跑指定场景
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
MAESTRO="$HOME/.maestro/bin/maestro"

FLOWS=("s0_onboarding" "s1_chat_roundtrip" "s2_tool_cards" "s3_invest_cli" "s4_session_continuity" "s5_panel")
SELECTED=("$@")

if [[ ${#SELECTED[@]} -eq 0 ]]; then
    SELECTED=("s1_chat_roundtrip" "s2_tool_cards" "s3_invest_cli" "s4_session_continuity" "s5_panel")
fi

FILES=()
for sel in "${SELECTED[@]}"; do
    match=""
    for f in "${FLOWS[@]}"; do
        [[ "$f" == "${sel}"* ]] && match="$f"
    done
    if [[ -z "$match" ]]; then
        echo "unknown scenario: $sel" >&2; exit 1
    fi
    if [[ "$match" == "s0"* ]]; then
        "$ADB" shell pm clear com.openminis.app >/dev/null || true
    fi
    FILES+=("$REPO/.maestro/$match.yaml")
done
# 单次调用共享驱动会话：MIUI 对每个新 dadb 连接的驱动安装都会弹确认，
# 多次独立调用会随机被拒（INSTALL_FAILED_USER_RESTRICTED）。
exec "$MAESTRO" test "${FILES[@]}"
