#!/system/bin/sh
# 模块卸载时清理运行状态目录（守护进程会在本次重启后自然消失）
rm -rf /data/adb/coloros_smart_power_saver
