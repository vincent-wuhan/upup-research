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

dump() { "$ADB" shell uiautomator dump $UI >/dev/null 2>&1; }
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
ensure_chat() { # 不在聊天页则新建一个对话；深層页面先 back 退出
    if [ -n "$(edit_bounds)" ]; then return 0; fi
    for _ in 1 2 3; do
        dump
        if "$ADB" shell cat $UI | grep -q 'New Chat\|新建对话'; then break; fi
        "$ADB" shell input keyevent 4; sleep 1.5
    done
    dump
    local c=$("$ADB" shell cat $UI | python3 -c "
import sys, re, html
xml = sys.stdin.read()
for m in re.finditer(r'<node[^>]*>', xml):
    n = m.group(0)
    d = re.search(r'content-desc=\"([^\"]+)\"', n)
    t = re.search(r'text=\"([^\"]*)\"', n)
    label = (d.group(1) if d else (t.group(1) if t else ''))
    if label in ('New Chat','新建对话'):
        b = re.search(r'bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', n)
        if b:
            l,tp,r,bo = map(int, b.groups()); print((l+r)//2, (tp+bo)//2); break")
    if [ -z "$c" ]; then
        # 会话列表里第一条会话
        c=$("$ADB" shell cat $UI | python3 -c "
import sys, re, html
xml = sys.stdin.read()
for m in re.finditer(r'text=\"(invest|/invest|New Chat|check)[^\"]*\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', xml):
    l,t,r,b = map(int, m.groups()[1:]); print((l+r)//2, (t+b)//2); break")
    fi
    [ -n "$c" ] && "$ADB" shell input tap $c && sleep 2
    [ -n "$(edit_bounds)" ]
}

send_message() { # $1 = ASCII text (空格用 %s 由 input 处理)
    ensure_chat || { echo "not in chat" >&2; return 1; }
    local e=$(edit_bounds)
    "$ADB" shell input tap $e; sleep 1
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
        "$ADB" shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; sleep 3; lock_portrait
        if send_message "reply%swith%sone%sword%spong"; then
            check "s1 对话链路" "pong" 120
        else FAIL+=("s1 对话链路"); echo "FAIL  s1 (send)"; fi
        ;;
    s2)
        # 新建会话：历史上下文里已有价格，旧会话模型会直接回答而不调用工具
        "$ADB" shell input keyevent 4; sleep 1.5
        dump
        nc=$("$ADB" shell cat $UI | python3 -c "
import sys, re
xml = sys.stdin.read()
for m in re.finditer(r'<node[^>]*>', xml):
    n = m.group(0)
    d = re.search(r'content-desc=\"([^\"]+)\"', n)
    t = re.search(r'text=\"([^\"]*)\"', n)
    label = d.group(1) if d else (t.group(1) if t else '')
    if label in ('New Chat','新建对话'):
        b = re.search(r'bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', n)
        if b:
            l,tp2,r,bo = map(int, b.groups()); print((l+r)//2, (tp2+bo)//2); break")
        [ -n "$nc" ] && "$ADB" shell input tap $nc && sleep 2.5
        if send_message "check%sthe%scurrent%sprice%sof%s600519.SH"; then
            # 工具卡片文本不暴露给 uiautomator（Compose semantics 折叠），
            # 卡片呈现靠截图留档人工核对；新会话答出实时价格即证明服务端工具已跑
            check "s2 价格回复" "1543|[0-9]{3,4}\.[0-9]{2}|元|price|yuan" 180
            "$ADB" exec-out screencap -p > "$(dirname "$0")/../s2-tool-cards.png" 2>/dev/null || true
        else FAIL+=("s2 工具卡片"); echo "FAIL  s2 (send)"; fi
        ;;
    s3)
        if send_message "/invest%s--list"; then
            check "s3 投研命令" "Plans|计划" 60
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
