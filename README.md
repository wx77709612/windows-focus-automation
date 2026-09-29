# Windows 专注自动化工具

这个工具使用 Windows 自带的“时钟 / 专注”和计划任务，不安装第三方程序。

## 已配置的自动时段

- 每天 14:00–16:20
- 每天 21:00–23:00

电脑在开始时间已登录时，会按时启动完整时段。电脑在时段中途开机、登录或从睡眠恢复时，计划任务会尽快补启动，但只运行到当天固定结束时间；超过结束时间后直接跳过。

任务不会主动唤醒电脑。若已经存在一个专注会话，脚本不会覆盖它。

## 勿扰行为

Windows 专注启动后通常会联动开启“勿扰”。本工具会在确认专注已经激活后，立即把勿扰切回关闭状态，因此普通应用通知仍可显示。脚本只写入当前用户的通知开关，不修改 CloudStore 数据，也不重启资源管理器。

## 常用命令

请在此目录打开 PowerShell，再运行：

```powershell
# 查看当前状态
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WindowsFocusAutomation.ps1 -Mode Status

# 预演安装，不启动专注、不改任务、不写日志
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WindowsFocusAutomation.ps1 -Mode Install -WhatIf

# 执行 1 分钟真实兼容性测试
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WindowsFocusAutomation.ps1 -Mode Test

# 安装或覆盖更新两个自动任务
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WindowsFocusAutomation.ps1 -Mode Install

# 卸载任务并删除本工具日志；脚本、测试和说明文件会保留
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WindowsFocusAutomation.ps1 -Mode Uninstall
```

## 计划任务

任务文件夹为 `\WindowsFocusAutomation\`，固定包含：

- `WindowsFocusAutomation-Afternoon`：每天 14:00
- `WindowsFocusAutomation-Evening`：每天 21:00

两个任务都采用“错过后尽快运行”、不唤醒电脑、忽略重复实例、仅在当前用户登录时运行，并使用最低权限。重复安装只会更新这两个固定名称的任务，不会创建副本。

## 日志清理

日志位于 `logs` 子目录，只记录运行时间、时段、剩余分钟、启动/验证结果和错误原因，不记录通知内容或聊天内容。

脚本最多每 7 天执行一次清理，并删除最后修改时间早于 7 天的 `focus-*.log` 文件。

## 返回码

- `0`：成功，或按规则安全跳过
- `2`：运行参数不完整
- `10`：Windows 时钟、URI 协议或专注状态接口不受支持
- `11`：专注启动或状态验证失败
- `12`：无法确认勿扰已经关闭
- `20`：日志不可写
- `30`：计划任务安装失败；脚本会尝试恢复安装前状态

## Windows 或时钟更新后的修复

先运行 `-Mode Status`。如果兼容性异常，再运行 `-Mode Test`。测试通过后重新运行 `-Mode Install`，即可覆盖更新任务定义。若测试失败，不要反复安装；请保留 `logs` 目录中的最新错误记录用于排查。
