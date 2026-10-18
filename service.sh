#!/system/bin/sh
# ColorOS 息屏智能省电守护（v1.7）
# 仅调用系统电池省电模式，并在开启省电时关闭蓝牙、解除时恢复；不改内核参数、不改系统文件、不持有 wakelock。

RUNDIR="/data/adb/coloros_smart_power_saver"
STATE_FILE="$RUNDIR/state"
LOCK_FILE="$RUNDIR/lock"
LOGFILE="$RUNDIR/service.log"
COUNT_FILE="$RUNDIR/count"
HISTORY_FILE="$RUNDIR/history.log"
LAST_ON_FILE="$RUNDIR/last_on"
BT_FLAG_FILE="$RUNDIR/bt_off"

mkdir -p "$RUNDIR" 2>/dev/null
chmod 700 "$RUNDIR" 2>/dev/null

rotate_file() {
    [ -f "$1" ] || return 0
    if size=$(wc -c < "$1" 2>/dev/null) && [ "$size" -gt 524288 ] 2>/dev/null; then
        mv -f "$1" "$1.1" 2>/dev/null
    fi
}

log() {
    rotate_file "$LOGFILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)] $1" >> "$LOGFILE"
}

get_count() {
    [ -r "$COUNT_FILE" ] || { echo 0; return 0; }
    n=$(tr -dc '0-9' < "$COUNT_FILE" 2>/dev/null)
    [ -n "$n" ] || n=0
    echo "$n"
}

# 只在“本模块成功开启并验证生效”时计数，返回最新累计次数
inc_count() {
    n=$(get_count)
    n=$((n + 1))
    printf '%s\n' "$n" > "$COUNT_FILE.tmp" 2>/dev/null && mv -f "$COUNT_FILE.tmp" "$COUNT_FILE" 2>/dev/null
    rotate_file "$HISTORY_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)] level=$1 delay=$2 count=$n" >> "$HISTORY_FILE"
    echo "$n"
}

# ---------- 蓝牙联动：本模块开启省电时关闭蓝牙，解除省电时恢复 ----------
# 只有“蓝牙原本开着且由本模块关掉”时才写 bt_off 标记，也只有带标记时才恢复，
# 不会打开用户本来就关着的蓝牙。息屏时若有已连接的蓝牙设备（耳机/手表/键盘等）则跳过，不打断使用。
get_bt_state() {
    v=$(settings get global bluetooth_on 2>/dev/null | tr -d ' \r\n')
    [ "$v" = "1" ] && echo 1 || echo 0
}

bt_has_connection() {
    dumpsys bluetooth_manager 2>/dev/null | grep -Eq 'ConnectionState: *STATE_CONNECTED' && echo 1 || echo 0
}

# $1 = enable / disable；优先 cmd bluetooth_manager，失败回退 svc bluetooth；最多回读 8 秒
bt_set() {
    want=0
    [ "$1" = "enable" ] && want=1
    cmd bluetooth_manager "$1" >/dev/null 2>&1 || svc bluetooth "$1" >/dev/null 2>&1
    tries=0
    while [ "$tries" -lt 8 ]; do
        [ "$(get_bt_state)" = "$want" ] && return 0
        sleep 1
        tries=$((tries + 1))
    done
    # 第一种接口未生效时再试一次另一种
    svc bluetooth "$1" >/dev/null 2>&1
    sleep 2
    [ "$(get_bt_state)" = "$want" ]
}

bt_off_for_saver() {
    [ "$(get_bt_state)" = "1" ] || { log "蓝牙：原本已关闭，无需处理"; return 0; }
    if [ "$(bt_has_connection)" = "1" ]; then
        log "蓝牙：有已连接设备，跳过关闭"
        return 0
    fi
    # 先写标记再关闭：关闭过程中若亮屏触发解除，恢复逻辑也能看到标记
    echo 1 > "$BT_FLAG_FILE" 2>/dev/null
    if bt_set disable; then
        log "蓝牙：已随省电模式关闭"
        # 关闭过程中若省电已被解除（亮屏较快时恢复逻辑可能先跑完），这里补一次恢复，避免蓝牙一直关着
        case "$(read_state)" in
            on:*) ;;
            *)
                rm -f "$BT_FLAG_FILE" 2>/dev/null
                bt_set enable && log "蓝牙：关闭期间省电已解除，已重新开启"
                ;;
        esac
    else
        rm -f "$BT_FLAG_FILE" 2>/dev/null
        log "蓝牙：关闭未生效（系统受限或不支持），保持原状"
    fi
}

bt_restore() {
    [ -f "$BT_FLAG_FILE" ] || return 0
    rm -f "$BT_FLAG_FILE" 2>/dev/null
    if [ "$(get_bt_state)" = "1" ]; then
        log "蓝牙：已被手动打开，无需恢复"
        return 0
    fi
    if bt_set enable; then
        log "蓝牙：已恢复开启"
    else
        log "蓝牙：恢复开启未生效，请手动打开"
    fi
}

# ---------- 单实例保护 ----------
if [ -r "$LOCK_FILE" ]; then
    old=$(tr -dc '0-9' < "$LOCK_FILE" 2>/dev/null)
    if [ -n "$old" ] && [ -d "/proc/$old" ] && grep -qa 'coloros_smart_power_saver/service.sh' "/proc/$old/cmdline" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"

# ---------- 基础查询 ----------
get_saver_state() {
    v=$(settings get global low_power 2>/dev/null | tr -d ' \r\n')
    [ "$v" = "1" ] && echo 1 || echo 0
}

is_powered() {
    dumpsys battery 2>/dev/null | grep -Eq '(AC|USB|Wireless|Dock) powered: true' && echo 1 || echo 0
}

get_battery_level() {
    v=$(dumpsys battery 2>/dev/null | grep -m1 -E '^[[:space:]]*level:' | tr -dc '0-9')
    [ -z "$v" ] && v=100
    if [ "$v" -gt 100 ] 2>/dev/null; then v=100; fi
    echo "$v"
}

get_wakefulness() {
    v=$(dumpsys power 2>/dev/null | grep -m1 'mWakefulness=' | cut -d'=' -f2 | tr -d ' \r\n')
    [ -z "$v" ] && v=Unknown
    echo "$v"
}

# 本次亮屏已持续多少秒（判定 <5 分钟 / >=5 分钟）；无法判定时返回 999999
get_on_seconds() {
    last=$(tr -dc '0-9' < "$LAST_ON_FILE" 2>/dev/null)
    now=$(date +%s)
    if [ -n "$last" ] && [ "$now" -ge "$last" ]; then
        echo $((now - last))
    else
        echo 999999
    fi
}

# 亮屏后延迟 5 秒再解除本模块开启的省电；这 5 秒内若又息屏，则保持省电不动
schedule_saver_off() {
    st=$(read_state)
    case "$st" in
        on:*) ;;
        *) return 0 ;;
    esac
    (
        sleep 5
        [ "$(read_state)" = "$st" ] || exit 0
        case "$(get_wakefulness)" in
            Awake) ;;
            *) exit 0 ;;
        esac
        log "亮屏已保持 5 秒，解除本模块开启的省电"
        disable_ours
    ) &
}

# ---------- 状态文件：off / pending:<token> / on:<原 sticky 值> ----------
# 只有 state=on:* 才代表“当前省电模式是本模块开启的”，也只有这种状态允许被本模块关闭。
SEQ=0

read_state() {
    cat "$STATE_FILE" 2>/dev/null | tr -d ' \r\n'
}

write_state() {
    printf '%s\n' "$1" > "$STATE_FILE.tmp" 2>/dev/null && mv -f "$STATE_FILE.tmp" "$STATE_FILE" 2>/dev/null
}

disable_ours() {
    st=$(read_state)
    case "$st" in
        on:*) sticky_saved=${st#on:} ;;
        *) return 0 ;;
    esac
    [ -n "$sticky_saved" ] || sticky_saved=0

    if [ "$(get_saver_state)" = "1" ]; then
        cmd power set-mode 0
        off=0
        tries=0
        while [ "$tries" -lt 10 ]; do
            [ "$(get_saver_state)" = "0" ] && { off=1; break; }
            sleep 1
            tries=$((tries + 1))
        done
        if [ "$off" = "0" ]; then
            log "关闭省电未生效（充电或系统受限），保留标记稍后重试"
            return 0
        fi
        log "已关闭本模块开启的省电模式"
    fi
    settings put global low_power_sticky "$sticky_saved" 2>/dev/null
    write_state off
    bt_restore
}

handle_screen_off() {
    src=$1
    [ -n "$src" ] || src=event

    case "$(read_state)" in
        pending:*|on:*)
            log "息屏：模块已持有省电状态，忽略重复触发的息屏事件"
            return 0
            ;;
    esac

    if [ "$(is_powered)" = "1" ]; then
        log "息屏：充电/供电中，豁免"
        return 0
    fi

    if [ "$(get_saver_state)" = "1" ]; then
        write_state off
        log "息屏：省电模式已由用户/系统开启，本模块不接管"
        return 0
    fi

    # 延迟优先级：电量 < 45% 直接 2 分钟（不再看亮屏时长）；电量 >= 45% 才按亮屏时长判断
    bat=$(get_battery_level)
    if [ "$bat" -lt 45 ]; then
        delay=120
        why="电量 ${bat}% < 45%"
    else
        on_secs=$(get_on_seconds)
        if [ "$on_secs" -lt 300 ]; then
            delay=120
            why="电量 ${bat}%；亮屏仅 ${on_secs}s < 300s"
        elif [ "$on_secs" -lt 999999 ]; then
            delay=240
            why="电量 ${bat}%；亮屏 ${on_secs}s >= 300s"
        else
            delay=240
            why="电量 ${bat}%；亮屏时长未知"
        fi
    fi

    SEQ=$((SEQ + 1))
    token="$src-$SEQ-$(date +%s)"
    write_state "pending:$token"
    log "息屏：${why}，${delay}s 后开启系统省电（token=${token}）"

    (
        end=$(( $(date +%s) + delay ))
        while :; do
            [ "$(read_state)" = "pending:$token" ] || exit 0
            now=$(date +%s)
            [ "$now" -ge "$end" ] && break
            left=$((end - now))
            [ "$left" -gt 60 ] && left=60
            sleep "$left"
        done

        [ "$(read_state)" = "pending:$token" ] || exit 0
        case "$(get_wakefulness)" in
            Asleep|Dozing) ;;
            *) exit 0 ;;
        esac
        [ "$(is_powered)" = "1" ] && exit 0
        [ "$(get_saver_state)" = "1" ] && exit 0

        sticky_before=$(settings get global low_power_sticky 2>/dev/null | tr -dc '01')
        [ -n "$sticky_before" ] || sticky_before=0

        cmd power set-mode 1
        write_state "on:$sticky_before"
        on=0
        tries=0
        while [ "$tries" -lt 10 ]; do
            [ "$(get_saver_state)" = "1" ] && { on=1; break; }
            sleep 1
            tries=$((tries + 1))
        done

        if [ "$(get_wakefulness)" = "Awake" ]; then
            disable_ours
            log "开启后检测到已亮屏，立即回滚"
            exit 0
        fi

        if [ "$on" = "1" ]; then
            # cmd power set-mode 1 会顺带置位 low_power_sticky，清掉可避免插拔充电后自动复活
            settings put global low_power_sticky 0 2>/dev/null
            n=$(inc_count "$bat" "$delay")
            log "息屏 ${delay}s：已开启系统省电模式（累计自动开启第 ${n} 次，电量 ${bat}%）"
            bt_off_for_saver
        else
            write_state off
            log "开启未生效（充电中/系统受限/不支持），放弃本次"
        fi
    ) &
}

handle_screen_on() {
    date +%s > "$LAST_ON_FILE" 2>/dev/null
    case "$(read_state)" in
        pending:*)
            write_state off
            log "亮屏：已取消息屏省电倒计时"
            ;;
    esac
    schedule_saver_off
}

# ---------- 等待开机完成 ----------
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 3
done
sleep 10

write_state off
# 上次运行期间由本模块关掉的蓝牙（例如省电中重启），开机后恢复
bt_restore
case "$(get_wakefulness)" in
    Awake) date +%s > "$LAST_ON_FILE" 2>/dev/null ;;
    *) : > "$LAST_ON_FILE" 2>/dev/null ;;
esac
log "=== ColorOS 省电守护启动（v1.7，累计自动开启 $(get_count) 次） ==="

# 事件监听（自愈）：screen_toggled payload 0=灭屏 1=亮屏；解析失败回退 dumpsys。
# logcat 管道一旦退出（logd 重启、被系统清理、读取被拒等）自动重启，并把 stderr 落盘供排查。
(
    backoff=30
    while :; do
        LAST_STATE=$(get_wakefulness)
        case "$LAST_STATE" in
            Awake|Asleep|Dozing) ;;
            *) LAST_STATE=Awake ;;
        esac
        : > "$RUNDIR/logcat.err" 2>/dev/null
        log "事件监听启动（异常重启间隔 ${backoff}s）"
        # -T 1：只回放最后一条事件后开始实时跟随，避免重启监听时把缓冲区旧事件全部重放
        logcat -b events -v raw -s screen_toggled -T 1 2>"$RUNDIR/logcat.err" | while read -r line; do
            payload=${line##*: }
            payload=${payload%%,*}
            case "$payload" in
                0) WAKE=Asleep ;;
                1) WAKE=Awake ;;
                *) WAKE=$(get_wakefulness) ;;
            esac
            [ "$WAKE" = "Unknown" ] && continue
            [ "$WAKE" = "$LAST_STATE" ] && continue
            case "$WAKE" in
                Awake) handle_screen_on ;;
                Asleep|Dozing) handle_screen_off ;;
            esac
            LAST_STATE="$WAKE"
        done
        err=$(tr '\n' ' ' < "$RUNDIR/logcat.err" 2>/dev/null | cut -c1-200)
        log "事件监听退出：${err:-无错误输出}；${backoff}s 后重启"
        sleep "$backoff"
        case "$backoff" in
            30) backoff=60 ;;
            60) backoff=120 ;;
            *) backoff=300 ;;
        esac
    done
) &

# 兜底轮询：事件丢失或 ROM 不上报 screen_toggled 时仍可工作。
# 只有模块自己持有省电（on:*）时才按 120 秒节奏检查，其余时间 300 秒一次。
POLL_LAST=$(get_wakefulness)
case "$POLL_LAST" in
    Awake|Asleep|Dozing) ;;
    *) POLL_LAST=Awake ;;
esac

while :; do
    case "$(read_state)" in
        on:*) sleep 120 ;;
        *) sleep 300 ;;
    esac

    WAKE_CHECK=$(get_wakefulness)
    case "$WAKE_CHECK" in
        Awake)
            if [ "$POLL_LAST" != "Awake" ]; then
                handle_screen_on
            else
                schedule_saver_off
            fi
            POLL_LAST=Awake
            ;;
        Asleep|Dozing)
            if [ "$POLL_LAST" = "Awake" ] && [ "$(read_state)" = "off" ]; then
                handle_screen_off poll
            fi
            POLL_LAST=$WAKE_CHECK
            ;;
    esac
done
