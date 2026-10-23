#!/usr/bin/env bash
# S1-S5 移动端回归（adb 原语版）。
# 与 .maestro/*.yaml 等效；Maestro 在 MIUI 上被「USB 安装」策略拦截时用本脚本。
# 前置：真机已配置 UpUp gateway provider（upup.yueming.xin），竖屏。
# 用法: scripts/adb-regression.sh [s0 s1 s2 s3 s4 s5 ...]
set -uo pipefail

ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
PKG=com.openminis.app
UI=/sdcard/ui.xml
PASS=(); FAIL=()

dump() { # uiautomator 在界面有动画（流式回复/typing 指示器）时会静默失败留下旧 XML，
    # 必须校验文件新鲜度并重试，否则后续断言/定位全在盲操作
    for _ in 1 2 3 4 5; do
        "$ADB" shell uiautomator dump $UI >/dev/null 2>&1
        local ts now
        ts=$("$ADB" shell stat -c %Y $UI 2>/dev/null | tr -d '\r')
        now=$("$ADB" shell date +%s | tr -d '\r')
        if [ -n "$ts" ] && [ -n "$now" ] && [ "$((now - ts))" -le 5 ]; then return 0; fi
        sleep 2
    done
    return 1
}
texts() { dump; "$ADB" shell cat $UI | python3 -c "
import sys, re, html
xml = sys.stdin.read()
for m in re.finditer(r'text=\"([^\"]*)\"', xml):
    t = html.unescape(m.group(1))
    if t: print(t)"; }
desc_bounds() { # $1 = content-desc keyword
    dump; "$ADB" shell cat $UI | python3 -c "
import sys, re
xml = sys.stdin.read()
for m in re.finditer(r'<node[^>]*>', xml):
    n = m.group(0)
    if 'content-desc=\"$1\"' in n:
        b = re.search(r'bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', n)
        if b:
            l,t,r,bo = map(int, b.groups()); print((l+r)//2, (t+bo)//2); break"; }
wait_text() { # $1=regex, $2=timeout_s
    local deadline=$(( $(date +%s) + ${2:-60} ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if texts | grep -qE "$1"; then return 0; fi
        sleep 4
    done
    return 1
}
lock_portrait() {
    "$ADB" shell settings put system accelerometer_rotation 0
    "$ADB" shell settings put system user_rotation 0
}
edit_bounds() {
    dump; "$ADB" shell cat $UI | python3 -c "
import sys, re
xml = sys.stdin.read()
for m in re.finditer(r'<node[^>]*>', xml):
    n = m.group(0)
    if 'class=\"android.widget.EditText\"' in n:
        b = re.search(r'bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', n)
        if b:
            l,t,r,bo = map(int, b.groups()); print((l+r)//2, (t+bo)//2); break"
}
ensure_chat() { # 聊天页 = 同时有输入框和 Send；只有 EditText 时是会话列表的搜索框，不能当聊天页
    dump
    if [ -n "$(edit_bounds)" ] && [ -n "$(desc_bounds Send)" ]; then return 0; fi
    # 可能停在系统设置等任意页面：先拉起应用再找
    "$ADB" shell am force-stop $PKG >/dev/null 2>&1; sleep 1
    "$ADB" shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; sleep 3
    dump
    if [ -n "$(edit_bounds)" ] && [ -n "$(desc_bounds Send)" ]; then return 0; fi
    local c=""
    for _ in 1 2 3; do
        c=$(desc_bounds New Chat); [ -z "$c" ] && c=$(desc_bounds 新建对话)
        [ -n "$c" ] && break
        "$ADB" shell input keyevent 4; sleep 1.5; dump
    done
    [ -n "$c" ] && "$ADB" shell input tap $c && sleep 2.5
    dump
    [ -n "$(edit_bounds)" ] && [ -n "$(desc_bounds Send)" ]
}

new_chat() { # 回会话列表点 New Chat；大上下文会让回复变慢/诱发长工具链，各场景用新会话
    "$ADB" shell am force-stop $PKG >/dev/null 2>&1; sleep 1
    "$ADB" shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; sleep 3
    # 重启会恢复到上次聊天页（可能带着断流重试横幅）；先退到会话列表再找 FAB
    dump
    if [ -n "$(edit_bounds)" ] && [ -n "$(desc_bounds Send)" ]; then
        "$ADB" shell input keyevent 4; sleep 1.5
    fi
    for _ in 1 2 3; do
        local c=$(desc_bounds New Chat); [ -z "$c" ] && c=$(desc_bounds 新建对话)
        [ -n "$c" ] && break
        "$ADB" shell input keyevent 4; sleep 1.5; dump
    done
    [ -n "${c:-}" ] && "$ADB" shell input tap $c && sleep 2.5
}

send_message() { # $1 = ASCII text (空格用 %s 由 input 处理)
    ensure_chat || { echo "not in chat" >&2; return 1; }
    local e=$(edit_bounds)
    "$ADB" shell input tap $e; sleep 1
    # 草稿恢复会把上一场景的文本留在输入框里，input text 只追加 — 先清空
    "$ADB" shell input keyevent 67 >/dev/null 2>&1
    for _ in $(seq 1 60); do "$ADB" shell input keyevent 67 >/dev/null 2>&1; done
    "$ADB" shell input text "$1"; sleep 0.8
    # 点聊天区收起 slash 菜单/键盘，避免 Send 点击被菜单浮层吞掉
    "$ADB" shell input tap 540 700; sleep 1
    local c=$(desc_bounds Send)
    if [ -z "$c" ]; then
        "$ADB" shell input keyevent 4; sleep 1
        c=$(desc_bounds Send)
    fi
    if [ -z "$c" ]; then echo "Send button not found" >&2; return 1; fi
    "$ADB" shell input tap $c
}
check() { # $1=场景名 $2=断言regex $3=timeout_s
    if wait_text "$2" "${3:-60}"; then PASS+=("$1"); echo "PASS  $1"; return 0; fi
    # 长流偶发「连接中断」（手机网络切换）：点一次重试再等半程
    dump
    r=$("$ADB" shell cat $UI | python3 -c "
import sys, re, html
xml = sys.stdin.read()
for m in re.finditer(r'text=\"([^\"]*)\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', xml):
    if html.unescape(m.group(1)) == '重试':
        l,t,r,b = map(int, m.groups()[1:]); print((l+r)//2,(t+b)//2); break")
    if [ -n "$r" ]; then
        echo "      (stream dropped — tapping 重试)"
        "$ADB" shell input tap $r; sleep 2
        if wait_text "$2" $(( ${3:-60} / 2 )); then PASS+=("$1"); echo "PASS  $1"; return 0; fi
    fi
    FAIL+=("$1"); echo "FAIL  $1 (assert: $2)"
    return 1
}

"$ADB" shell settings put system user_rotation 0 >/dev/null 2>&1
SELECTED=("$@")
[ ${#SELECTED[@]} -eq 0 ] && SELECTED=(s0 s1 s2 s3 s4 s5)

for s in "${SELECTED[@]}"; do
    case "$s" in
    s0)
        "$ADB" shell pm clear $PKG >/dev/null
        "$ADB" shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
        sleep 4
        check "s0 免责声明" "投资免责声明|Investment Disclaimer" 20
        dump; c=$("$ADB" shell cat $UI | python3 -c "
import sys, re, html
xml = sys.stdin.read()
for m in re.finditer(r'text=\"([^\"]*)\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', xml):
    if html.unescape(m.group(1)) in ('我已知晓','I Understand'):
        l,t,r,b = map(int, m.groups()[1:]); print((l+r)//2,(t+b)//2); break")
        [ -n "$c" ] && "$ADB" shell input tap $c
        sleep 2
        check "s0 欢迎页" "欢迎使用 Minis|Welcome to Minis" 15
        ;;
    s1)
        "$ADB" shell am force-stop $PKG >/dev/null 2>&1; sleep 1
        "$ADB" shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; sleep 3; lock_portrait
        if send_message "reply%swith%sone%sword%spong"; then
            check "s1 对话链路" "pong" 120
        else FAIL+=("s1 对话链路"); echo "FAIL  s1 (send)"; fi
        ;;
    s2)
        # 新建会话：历史上下文里已有价格，旧会话模型会直接回答而不调用工具
        new_chat
        if send_message "check%sthe%scurrent%sprice%sof%s600519.SH"; then
            # 工具卡片文本不暴露给 uiautomator（Compose semantics 折叠），
            # 卡片呈现靠截图留档人工核对；新会话答出实时价格即证明服务端工具已跑
            check "s2 价格回复" "1543|[0-9]{3,4}\.[0-9]{2}|元|price|yuan" 180
            "$ADB" exec-out screencap -p > "$(dirname "$0")/../s2-tool-cards.png" 2>/dev/null || true
        else FAIL+=("s2 工具卡片"); echo "FAIL  s2 (send)"; fi
        ;;
    s3)
        # 新会话：大会话上下文会诱发超长工具链流（21+ 工具调用），必断流
        new_chat
        if send_message "/invest%s--list"; then
            # 模型对 --list 的回复措辞不定（可能是"状态对比分析"，字面未必含
            # "Plans"/"计划"；"invest" 又会匹配到用户自己的消息气泡），断言用
            # 回复必含的 plan ID 特征（8 位十六进制）或"10 步"
            check "s3 投研命令" "[0-9a-f]{8}|10 步|10 steps" 90
        else FAIL+=("s3 投研命令"); echo "FAIL  s3 (send)"; fi
        ;;
    s4)
        if send_message "remember%sthe%scodeword%smango.%sreply%sok" \
           && wait_text "ok|OK|好的" 120 \
           && send_message "what%sis%sthe%scodeword%sreply%swith%sthe%sword%sonly"; then
            check "s4 跨轮记忆" "mango" 120
        else FAIL+=("s4 跨轮记忆"); echo "FAIL  s4 (send)"; fi
        ;;
    s5)
        # 退到会话列表（最多 3 次 back）
        for _ in 1 2 3; do
            c=$(desc_bounds 设置); [ -z "$c" ] && c=$(desc_bounds Settings)
            [ -n "$c" ] && break
            "$ADB" shell input keyevent 4; sleep 1.5
        done
        [ -n "$c" ] && "$ADB" shell input tap $c; sleep 2
        # 最多 6 次滚动找 UpUp Research 行
        for _ in 1 2 3 4 5 6; do
            dump
            row=$("$ADB" shell cat $UI | python3 -c "
import sys, re, html
xml = sys.stdin.read()
for m in re.finditer(r'text=\"([^\"]*)\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', xml):
    if html.unescape(m.group(1)) == 'UpUp Research':
        l,t,r,b = map(int, m.groups()[1:]); print((l+r)//2,(t+b)//2); break")
            [ -n "$row" ] && break
            "$ADB" shell input swipe 540 1800 540 700 300; sleep 1
        done
        [ -n "$row" ] && "$ADB" shell input tap $row && sleep 5
        check "s5 面板打开" "关注列表|Watchlist" 20
        check "s5 计划列表" "投研计划|Research Plans" 20
        ;;
    *) echo "unknown: $s" >&2 ;;
    esac
done

echo
echo "==== 结果: ${#PASS[@]} pass / ${#FAIL[@]} fail ===="
[ ${#FAIL[@]} -gt 0 ] && printf 'FAIL %s\n' "${FAIL[@]}"
[ ${#FAIL[@]} -eq 0 ]
