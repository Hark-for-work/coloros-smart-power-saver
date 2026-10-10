#!/system/bin/sh
# ColorOS 省电模式接口实测脚本（需要 root，必须拔掉充电器）
#
# 只做三件事：
#   1) 读取当前供电/电量/省电相关设置与 dumpsys（只读）
#   2) 尝试 cmd power set-mode 1 并回读验证
#   3) 恢复：确保 low_power=0 / 关闭本次测试开启的省电
#
# 不写系统分区、不改其它设置、不重启、不动任何进程。

echo "== 1. 供电与电量 =="
dumpsys battery | grep -E 'AC powered|USB powered|Wireless powered|Dock powered|status:|level:'

if dumpsys battery | grep -qE '(AC|USB|Wireless|Dock) powered: true'; then
    echo
    echo "！检测到仍在供电（充电）。AOSP 的 set-mode 1 在供电时会直接被拒绝，"
    echo "！请拔掉充电线后重新运行本脚本。"
    exit 1
fi

echo
echo "== 2. 测试前状态 =="
BEFORE=$(settings get global low_power 2>/dev/null | tr -d ' \r\n')
echo "low_power=$BEFORE"
echo "low_power_sticky=$(settings get global low_power_sticky 2>/dev/null)"
echo "low_power_trigger_level=$(settings get global low_power_trigger_level 2>/dev/null)"
echo "automatic_power_save_mode=$(settings get global automatic_power_save_mode 2>/dev/null)"

if [ "$BEFORE" = "1" ]; then
    echo
    echo "！当前省电已经处于开启状态（可能是你自己开的）。"
    echo "！请先在系统里手动关闭省电，再重新运行本脚本，否则测不出'能否开启'。"
    exit 1
fi

echo
echo "== 3. 执行 cmd power set-mode 1 =="
cmd power set-mode 1
echo "cmd 退出码=$?（注意：这个命令无论成败都返回 0，必须看下面的回读）"
sleep 2
AFTER=$(settings get global low_power 2>/dev/null | tr -d ' \r\n')
echo "回读 low_power=$AFTER"
echo "回读 low_power_sticky=$(settings get global low_power_sticky 2>/dev/null)"
echo "--- dumpsys power 相关行 ---"
dumpsys power 2>/dev/null | grep -i -E 'lowpower|battery.?saver' | head -n 10

if [ "$AFTER" = "1" ]; then
    echo
    echo ">> 结论：cmd power set-mode 1 生效（AOSP 省电已打开）。"
    echo ">> 请同时看一眼状态栏/设置→电池里是否显示'省电模式'，确认和系统 UI 是同一个东西。"
else
    echo
    echo ">> 结论：cmd power set-mode 1 未生效（ColorOS 可能用自己的省电实现）。"
    echo
    echo "== 4. 备选接口探测（只读） =="
    echo "--- 与 power/battery 相关的系统服务 ---"
    service list 2>/dev/null | grep -i -E 'power|battery|saver' | head -n 20
    echo "--- 与 power/saver 相关的全局设置键 ---"
    settings list global 2>/dev/null | grep -i -E 'power|saver|battery' | head -n 20
    echo
    echo "== 5. 备选尝试 settings put global low_power 1（仅部分厂商 ROM 有效） =="
    settings put global low_power 1
    sleep 2
    echo "回读 low_power=$(settings get global low_power 2>/dev/null)"
    dumpsys power 2>/dev/null | grep -i -E 'lowpower|battery.?saver' | head -n 10
fi

echo
echo "== 6. 恢复（确保省电关闭、设置回 0） =="
cmd power set-mode 0
settings put global low_power 0
settings put global low_power_sticky 0
sleep 1
echo "恢复后 low_power=$(settings get global low_power 2>/dev/null)"
echo "恢复后 low_power_sticky=$(settings get global low_power_sticky 2>/dev/null)"
echo
echo "请把以上完整输出贴回来。"
