# ColorOS Smart Screen-Off Power Saver

适用于 ColorOS / Android 平板（Magisk / KernelSU / APatch）的息屏智能省电模块。
息屏后按规则延迟调用系统省电模式，亮屏后延迟 5 秒自动解除，充电时完全豁免，不碰用户自己开启的省电。

当前版本：**v1.7.3**（versionCode 14）  
作者：Deepseek v4.1 Flash & Codex

## 功能

**息屏延迟规则（按下述优先级匹配）**

| 条件 | 息屏后倒计时 |
| --- | --- |
| 电量 < 45% | 2 分钟（不再计算亮屏时长） |
| 电量 >= 45%，本次亮屏不足 5 分钟 | 2 分钟 |
| 电量 >= 45%，本次亮屏满 5 分钟及以上 | 4 分钟 |
| 电量 >= 45%，亮屏时长无法判定 | 4 分钟（保守） |

**其他行为**

- **蓝牙联动**：本模块开启省电后同步关闭蓝牙，解除省电时恢复；有已连接设备也会断开，用户原本关着的蓝牙不会被打开。
- 亮屏后**蓝牙立即恢复**，省电**延迟 5 秒**才解除；这 5 秒内又息屏则省电保持不动，蓝牙重新关闭。
- 亮屏瞬间立即取消待触发的倒计时。
- 充电/供电状态下息屏不触发（`AC/USB/Wireless/Dock powered: true` 均视为供电）。
- 若省电已由用户或 ColorOS 自己开启，模块全程不接管、不关闭，也不计入统计。
- 自动统计：每次"本模块成功开启并验证生效"累计 +1，并写入开启明细。
- 双重触发通道：实时事件（`screen_toggled`）为主，兜底轮询为辅；事件监听意外退出会按 30/60/120/300 秒退避自动重启。
- 全流程不持有 wakelock、不改内核参数、不写系统分区。

## 运行环境

- ColorOS / Android 10 及以上（依赖 `cmd power set-mode` 接口）
- Magisk / KernelSU / APatch（需要 root）
- 已在 OPPO Pad（ColorOS 15 / Android 15 / Magisk 30.6）实机验证

## 安装

1. 下载 `dist/ColorOS_Smart_Power_Saver_v1.7.3.zip`
2. 在 Magisk / KernelSU / APatch 管理器中选择"从本地安装"
3. 重启设备（Magisk 会在 late_start service 阶段自动拉起守护进程）

## 状态目录与日志

运行状态保存在 `/data/adb/coloros_smart_power_saver/`（需要 root 查看）：

| 文件 | 内容 |
| --- | --- |
| `state` | `off` / `pending:<token>` / `on:<原sticky值>` |
| `count` | 累计自动开启次数（纯数字，可手动重置：`echo 0 > count`） |
| `history.log` | 每次开启明细：时间 / 电量 / 延时 / 第几次，超过 512 KB 轮转 |
| `service.log` | 运行日志，超过 512 KB 轮转为 `service.log.1` |
| `bt_off` | 存在即表示蓝牙由本模块关闭，解除省电时据此恢复 |
| `bt_resume` | 亮屏时已临时恢复蓝牙、省电仍在 5 秒宽限期；期间再息屏据此重新关闭蓝牙 |
| `last_on` | 最近一次亮屏时间戳（用于计算亮屏时长） |
| `logcat.err` | 事件监听进程的 stderr（排查监听退出原因） |

查看统计（root shell）：

```sh
R=/data/adb/coloros_smart_power_saver
echo "累计自动开启: $(cat $R/count 2>/dev/null || echo 0) 次"
cat $R/history.log 2>/dev/null
echo -n "state="; cat $R/state; echo
echo -n "low_power="; settings get global low_power
tail -n 10 $R/service.log
```

## 工作原理

- `service.sh` 在 late_start service 阶段运行，等待 `sys.boot_completed=1` 后启动守护逻辑，不阻塞开机。
- 屏幕状态来自 events 缓冲区 `screen_toggled`（`logcat -T 1`：只回放最后一条后实时跟随），解析失败时回退 `dumpsys power`。
- 兜底轮询：模块持有省电（`on:*`）时每 120 秒检查一次；其余时间每 300 秒检查一次；同时检测亮灭屏跳变。
- 倒计时使用墙钟分片检查（每片最多 60 秒），取消延迟用令牌比对，不按 PID kill 进程。
- 状态文件采用临时文件 + `mv` 原子替换；跨进程通信全部走状态文件。
- 开启后回读 `low_power` 验证（最多轮询 10 秒），兼容部分 ROM 上命令异步生效的情况。
- 模块在开启省电后会清零 `low_power_sticky` 以避免拔充电后自动复活，关闭时恢复原值。

## 安全边界

- 只调用系统公开接口 `cmd power set-mode 1/0`，不降频、不改内核参数、不替换系统文件。
- 只写自己的两个目录：`/data/adb/modules/coloros_smart_power_saver/`（模块自身）和 `/data/adb/coloros_smart_power_saver/`（运行状态）。
- 只读取 `settings`/`dumpsys`/`logcat`，除 `low_power_sticky` 的保存与还原、蓝牙开关的关闭与恢复外不修改任何设置。
- 卸载时只删除自己的运行状态目录，不触碰系统状态。

## 已知限制

- 延迟基于 `sleep` 墙钟分片，设备深睡时可能有几十秒到数分钟浮动，不追求精确到秒。
- ColorOS 自己在低电量时开启的省电不归本模块管理（不关闭、不计次）。
- 依赖 ROM 的 `cmd power set-mode` 实现；若接口被裁剪，日志会写"开启未生效"并放弃本次。

## 版本历史

| 版本 | 说明 |
| --- | --- |
| v1.7.3 | 亮屏立即恢复蓝牙；5 秒内再息屏重新关闭蓝牙 |
| v1.7.2 | 有已连接蓝牙设备时也关闭蓝牙 |
| v1.7.1 | 修复蓝牙恢复竞态；开机还原未释放的 sticky；测试脚本不再覆盖 sticky |
| v1.7 | 开启省电时同步关闭蓝牙，解除时恢复；有已连接设备时跳过 |
| v1.6.1 | 延迟规则优先级化：电量 <45% 直接 2 分钟；>=45% 时按亮屏时长（<5 分钟 2 分钟 / >=5 分钟 4 分钟） |
| v1.6 | 亮屏 5 秒后才解除省电；引入亮屏时长判定；修正单实例锁匹配过宽的问题 |
| v1.5 | 开启/关闭回读最多轮询 10 秒；`on:*` 轮询由 60 秒放宽到 120 秒 |
| v1.4 | 新增自动开启计数与明细；监听自愈；`logcat -T 1` 防止旧事件回放 |
| v1.3.1 | 修复监听退出后不自愈、兜底轮询误关用户省电等问题 |
| v1.0 ~ v1.2 | 初版：息屏延迟进入系统省电，亮屏退出，充电豁免 |

## 许可

本仓库未附开源许可证，默认保留所有权利。如需转载或分发请先联系作者。
