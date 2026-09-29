[CmdletBinding()]
param(
    [ValidateSet('Install', 'Run', 'Test', 'Status', 'Uninstall')]
    [string]$Mode = 'Status',

    [ValidateSet('Afternoon', 'Evening')]
    [string]$Window,

    [switch]$WhatIf
)

Set-StrictMode -Version 2.0

$script:DefaultLogDirectory = Join-Path $PSScriptRoot 'logs'
$script:FocusTaskPath = '\WindowsFocusAutomation\'

function Get-FocusWindowDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Window
    )

    switch ($Window) {
        'Afternoon' {
            return [pscustomobject]@{
                Name  = 'Afternoon'
                Start = [TimeSpan]::FromHours(14)
                End   = [TimeSpan]::FromMinutes(16 * 60 + 20)
            }
        }
        'Evening' {
            return [pscustomobject]@{
                Name  = 'Evening'
                Start = [TimeSpan]::FromHours(21)
                End   = [TimeSpan]::FromHours(23)
            }
        }
        default {
            throw "未知的专注时段：$Window"
        }
    }
}

function Get-FocusRunDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Definition,

        [Parameter(Mandatory = $true)]
        [datetime]$Now
    )

    $startTime = $Now.Date.Add($Definition.Start)
    $endTime = $Now.Date.Add($Definition.End)

    if ($Now -lt $startTime) {
        return [pscustomobject]@{
            Action          = 'Skip'
            DurationMinutes = 0
            EndTime         = $endTime
            Reason          = 'BeforeWindow'
        }
    }

    if ($Now -ge $endTime) {
        return [pscustomobject]@{
            Action          = 'Skip'
            DurationMinutes = 0
            EndTime         = $endTime
            Reason          = 'WindowEnded'
        }
    }

    return [pscustomobject]@{
        Action          = 'Start'
        DurationMinutes = [int][Math]::Ceiling(($endTime - $Now).TotalMinutes)
        EndTime         = $endTime
        Reason          = 'WithinWindow'
    }
}

function New-FocusSessionUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$EndTime
    )

    $endTimeMilliseconds = ([DateTimeOffset]$EndTime).ToUnixTimeMilliseconds()
    return "ms-clock://createfocustimer?skipBreaks=false&displayMode=aot&force=true&endTime=$endTimeMilliseconds"
}

function Start-NativeFocusSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$EndTime,

        [switch]$WhatIf
    )

    $uri = New-FocusSessionUri -EndTime $EndTime
    if ($WhatIf) {
        return [pscustomobject]@{
            Started = $false
            Uri     = $uri
            Reason  = 'WhatIf'
        }
    }

    if (Test-FocusSessionActive) {
        return [pscustomobject]@{
            Started = $false
            Uri     = $uri
            Reason  = 'FocusAlreadyActive'
        }
    }

    try {
        Start-Process -FilePath $uri -ErrorAction Stop
        return [pscustomobject]@{
            Started = $true
            Uri     = $uri
            Reason  = 'LaunchRequested'
        }
    }
    catch {
        return [pscustomobject]@{
            Started = $false
            Uri     = $uri
            Reason  = "LaunchFailed: $($_.Exception.Message)"
        }
    }
}

function Get-ClockPackage {
    [CmdletBinding()]
    param()

    return Get-AppxPackage -Name 'Microsoft.WindowsAlarms' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

function Test-MsClockProtocolRegistered {
    [CmdletBinding()]
    param()

    return Test-Path -LiteralPath 'Registry::HKEY_CLASSES_ROOT\ms-clock'
}

function Test-FocusApiSupported {
    [CmdletBinding()]
    param()

    try {
        $managerType = [Windows.UI.Shell.FocusSessionManager, Windows.UI.Shell, ContentType = WindowsRuntime]
        return [bool]$managerType::IsSupported
    }
    catch {
        return $false
    }
}

function Test-ClockCompatibility {
    [CmdletBinding()]
    param()

    $package = Get-ClockPackage
    if ($null -eq $package) {
        return [pscustomobject]@{
            Supported    = $false
            Reason       = 'ClockPackageMissing'
            ClockVersion = $null
        }
    }

    if (-not (Test-MsClockProtocolRegistered)) {
        return [pscustomobject]@{
            Supported    = $false
            Reason       = 'ClockProtocolMissing'
            ClockVersion = $package.Version.ToString()
        }
    }

    if (-not (Test-FocusApiSupported)) {
        return [pscustomobject]@{
            Supported    = $false
            Reason       = 'FocusApiUnsupported'
            ClockVersion = $package.Version.ToString()
        }
    }

    return [pscustomobject]@{
        Supported    = $true
        Reason       = 'Supported'
        ClockVersion = $package.Version.ToString()
    }
}

function Test-FocusSessionActive {
    [CmdletBinding()]
    param()

    try {
        $managerType = [Windows.UI.Shell.FocusSessionManager, Windows.UI.Shell, ContentType = WindowsRuntime]
        if (-not $managerType::IsSupported) {
            return $false
        }

        $manager = $managerType::GetDefault()
        return [bool]$manager.IsFocusActive
    }
    catch {
        return $false
    }
}

function Set-DoNotDisturbOff {
    [CmdletBinding()]
    param()

    $registryPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings'
    $valueName = 'NOC_GLOBAL_SETTING_TOASTS_ENABLED'

    try {
        New-Item -Path $registryPath -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -LiteralPath $registryPath -Name $valueName -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        $current = Get-ItemProperty -LiteralPath $registryPath -Name $valueName -ErrorAction Stop
        return ([int]$current.$valueName -eq 1)
    }
    catch {
        return $false
    }
}

function Ensure-DoNotDisturbOff {
    [CmdletBinding()]
    param(
        [TimeSpan]$Timeout = ([TimeSpan]::FromSeconds(5)),
        [TimeSpan]$PollInterval = ([TimeSpan]::FromMilliseconds(500))
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        if (Set-DoNotDisturbOff) {
            return $true
        }

        if ($timer.Elapsed -lt $Timeout) {
            Start-Sleep -Milliseconds ([Math]::Max(1, [int]$PollInterval.TotalMilliseconds))
        }
    } while ($timer.Elapsed -lt $Timeout)

    return $false
}

function Write-FocusLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Event,

        [hashtable]$Data = @{},

        [datetime]$Now = (Get-Date),

        [string]$LogDirectory = $script:DefaultLogDirectory,

        [switch]$WhatIf
    )

    if ($WhatIf) {
        return
    }

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force -ErrorAction Stop | Out-Null
    }

    $dataText = @(
        $Data.GetEnumerator() |
            Sort-Object Key |
            ForEach-Object { '{0}={1}' -f $_.Key, ([string]$_.Value -replace '[\r\n]+', ' ') }
    ) -join ' '

    $line = '{0} [{1}] {2}' -f $Now.ToString('o'), $Level, $Event
    if ($dataText) {
        $line = "$line $dataText"
    }

    $logPath = Join-Path $LogDirectory ('focus-{0}.log' -f $Now.ToString('yyyy-MM-dd'))
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 -ErrorAction Stop
}

function Invoke-LogMaintenance {
    [CmdletBinding()]
    param(
        [datetime]$Now = (Get-Date),

        [string]$LogDirectory = $script:DefaultLogDirectory,

        [switch]$WhatIf
    )

    if ($WhatIf) {
        return [pscustomobject]@{ Ran = $false; DeletedCount = 0; Reason = 'WhatIf' }
    }

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force -ErrorAction Stop | Out-Null
    }

    $markerPath = Join-Path $LogDirectory '.last-cleanup'
    if (Test-Path -LiteralPath $markerPath) {
        try {
            $lastCleanup = [DateTimeOffset]::Parse((Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop)).UtcDateTime
            if (($Now.ToUniversalTime() - $lastCleanup).TotalDays -lt 7) {
                return [pscustomobject]@{ Ran = $false; DeletedCount = 0; Reason = 'NotDue' }
            }
        }
        catch {
            # 清理标记损坏时按“已到期”处理，并在本次清理后重建。
        }
    }

    $cutoff = $Now.AddDays(-7)
    $oldLogs = @(
        Get-ChildItem -LiteralPath $LogDirectory -Filter 'focus-*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff }
    )

    foreach ($oldLog in $oldLogs) {
        Remove-Item -LiteralPath $oldLog.FullName -Force -ErrorAction Stop
    }

    $Now.ToUniversalTime().ToString('o') | Set-Content -LiteralPath $markerPath -Encoding UTF8 -Force -ErrorAction Stop
    return [pscustomobject]@{ Ran = $true; DeletedCount = $oldLogs.Count; Reason = 'Completed' }
}

function Enter-FocusRunLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Afternoon', 'Evening', 'Test')]
        [string]$Window
    )

    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($true, "Local\WindowsFocusAutomation-$Window", ([ref]$createdNew))
    if (-not $createdNew) {
        $mutex.Dispose()
        return $null
    }

    return $mutex
}

function Wait-FocusSessionActive {
    [CmdletBinding()]
    param(
        [TimeSpan]$Timeout = ([TimeSpan]::FromSeconds(10)),
        [TimeSpan]$PollInterval = ([TimeSpan]::FromMilliseconds(500))
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        if (Test-FocusSessionActive) {
            return $true
        }

        if ($timer.Elapsed -lt $Timeout) {
            Start-Sleep -Milliseconds ([Math]::Max(1, [int]$PollInterval.TotalMilliseconds))
        }
    } while ($timer.Elapsed -lt $Timeout)

    return $false
}

function Invoke-FocusRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Afternoon', 'Evening')]
        [string]$Window,

        [datetime]$Now = (Get-Date),

        [string]$LogDirectory = $script:DefaultLogDirectory,

        [switch]$WhatIf
    )

    $definition = Get-FocusWindowDefinition -Window $Window
    $decision = Get-FocusRunDecision -Definition $definition -Now $Now

    if ($WhatIf) {
        Write-Host ('预演：时段={0} 动作={1} 分钟={2} 结束={3:o}' -f
            $Window, $decision.Action, $decision.DurationMinutes, $decision.EndTime)
        return 0
    }

    $lock = Enter-FocusRunLock -Window $Window
    if ($null -eq $lock) {
        return 0
    }

    try {
        try {
            Invoke-LogMaintenance -Now $Now -LogDirectory $LogDirectory | Out-Null
        }
        catch {
            Write-Error "日志维护失败：$($_.Exception.Message)"
            return 20
        }

        if ($decision.Action -eq 'Skip') {
            Write-FocusLog -Level INFO -Event 'FocusSkipped' -Data @{ Window = $Window; Reason = $decision.Reason } -Now $Now -LogDirectory $LogDirectory
            return 0
        }

        $launch = Start-NativeFocusSession -EndTime $decision.EndTime
        if (-not $launch.Started) {
            if ($launch.Reason -eq 'FocusAlreadyActive') {
                Write-FocusLog -Level INFO -Event 'FocusSkipped' -Data @{ Window = $Window; Reason = $launch.Reason } -Now $Now -LogDirectory $LogDirectory
                return 0
            }

            Write-FocusLog -Level ERROR -Event 'FocusLaunchFailed' -Data @{ Window = $Window; Reason = $launch.Reason } -Now $Now -LogDirectory $LogDirectory
            return 11
        }

        if (-not (Wait-FocusSessionActive)) {
            Write-FocusLog -Level ERROR -Event 'FocusVerificationFailed' -Data @{ Window = $Window; Uri = $launch.Uri } -Now $Now -LogDirectory $LogDirectory
            return 11
        }

        if (-not (Ensure-DoNotDisturbOff)) {
            Write-FocusLog -Level ERROR -Event 'DoNotDisturbDisableFailed' -Data @{ Window = $Window } -Now $Now -LogDirectory $LogDirectory
            return 12
        }

        Write-FocusLog -Level INFO -Event 'FocusStarted' -Data @{
            Window  = $Window
            Minutes = $decision.DurationMinutes
            EndTime = $decision.EndTime.ToString('o')
            DndOff  = $true
        } -Now $Now -LogDirectory $LogDirectory
        return 0
    }
    catch {
        try {
            Write-FocusLog -Level ERROR -Event 'UnhandledRunFailure' -Data @{ Window = $Window; Reason = $_.Exception.Message } -Now $Now -LogDirectory $LogDirectory
        }
        catch {
            Write-Error "运行失败且无法写入日志：$($_.Exception.Message)"
            return 20
        }
        return 11
    }
    finally {
        $lock.ReleaseMutex()
        $lock.Dispose()
    }
}

function Get-FocusTaskDefinitions {
    [CmdletBinding()]
    param()

    @(
        [pscustomobject]@{
            TaskName = 'WindowsFocusAutomation-Afternoon'
            Window   = 'Afternoon'
            At       = [TimeSpan]::FromHours(14)
        }
        [pscustomobject]@{
            TaskName = 'WindowsFocusAutomation-Evening'
            Window   = 'Evening'
            At       = [TimeSpan]::FromHours(21)
        }
    )
}

function Register-FocusScheduledTasks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [switch]$WhatIf
    )

    $resolvedScriptPath = [System.IO.Path]::GetFullPath($ScriptPath)
    $definitions = @(Get-FocusTaskDefinitions)

    if ($WhatIf) {
        foreach ($definition in $definitions) {
            Write-Host ('预演：每天 {0:hh\:mm} 自动运行 {1}（不唤醒电脑）' -f $definition.At, $definition.TaskName)
        }
        return
    }

    $previousXml = @{}
    foreach ($definition in $definitions) {
        $existing = Get-ScheduledTask -TaskPath $script:FocusTaskPath -TaskName $definition.TaskName -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            $previousXml[$definition.TaskName] = Export-ScheduledTask -TaskPath $script:FocusTaskPath -TaskName $definition.TaskName -ErrorAction Stop
        }
    }

    $registered = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($definition in $definitions) {
            $argument = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode Run -Window {1}' -f
                $resolvedScriptPath.Replace('"', '""'), $definition.Window
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument
            $triggerTime = (Get-Date).Date.Add($definition.At)
            $trigger = New-ScheduledTaskTrigger -Daily -At $triggerTime
            $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun:$false -MultipleInstances IgnoreNew
            $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited

            Register-ScheduledTask -TaskPath $script:FocusTaskPath -TaskName $definition.TaskName `
                -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
                -Description '按固定结束时间自动开启 Windows 专注，并保持勿扰关闭。' -Force -ErrorAction Stop | Out-Null
            $registered.Add($definition.TaskName)
        }
    }
    catch {
        $registrationError = $_
        foreach ($definition in $definitions) {
            if ($previousXml.ContainsKey($definition.TaskName)) {
                Register-ScheduledTask -TaskPath $script:FocusTaskPath -TaskName $definition.TaskName `
                    -Xml $previousXml[$definition.TaskName] -Force -ErrorAction SilentlyContinue | Out-Null
            }
            elseif ($registered.Contains($definition.TaskName)) {
                Unregister-ScheduledTask -TaskPath $script:FocusTaskPath -TaskName $definition.TaskName `
                    -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
        throw $registrationError
    }

    return $definitions
}

function Unregister-FocusScheduledTasks {
    [CmdletBinding()]
    param([switch]$WhatIf)

    foreach ($definition in @(Get-FocusTaskDefinitions)) {
        if ($WhatIf) {
            Write-Host ('预演：移除计划任务 {0}' -f $definition.TaskName)
            continue
        }

        Unregister-ScheduledTask -TaskPath $script:FocusTaskPath -TaskName $definition.TaskName `
            -Confirm:$false -ErrorAction SilentlyContinue
    }

    if (-not $WhatIf) {
        try {
            $scheduler = New-Object -ComObject 'Schedule.Service'
            $scheduler.Connect()
            $rootFolder = $scheduler.GetFolder('\')
            $toolFolder = $scheduler.GetFolder($script:FocusTaskPath.TrimEnd('\'))
            if ($toolFolder.GetTasks(0).Count -eq 0 -and $toolFolder.GetFolders(0).Count -eq 0) {
                $rootFolder.DeleteFolder($script:FocusTaskPath.Trim('\'), 0)
            }
        }
        catch {
            # 文件夹不存在或系统仍在释放任务时，无需把卸载判定为失败。
        }
    }
}

function Invoke-FocusCompatibilityTest {
    [CmdletBinding()]
    param(
        [datetime]$Now = (Get-Date),
        [string]$LogDirectory = $script:DefaultLogDirectory,
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-Host '预演：启动 1 分钟 Windows 专注、验证已激活，并关闭勿扰。'
        return 0
    }

    $compatibility = Test-ClockCompatibility
    if (-not $compatibility.Supported) {
        Write-Error ('兼容性检查失败：{0}' -f $compatibility.Reason)
        return 10
    }

    $lock = Enter-FocusRunLock -Window Test
    if ($null -eq $lock) {
        return 0
    }

    try {
        Invoke-LogMaintenance -Now $Now -LogDirectory $LogDirectory | Out-Null
        $endTime = $Now.AddMinutes(1)
        $launch = Start-NativeFocusSession -EndTime $endTime

        if ($launch.Started) {
            if (-not (Wait-FocusSessionActive)) {
                Write-FocusLog -Level ERROR -Event 'CompatibilityFocusVerificationFailed' -Data @{ Uri = $launch.Uri } -Now $Now -LogDirectory $LogDirectory
                return 11
            }
        }
        elseif ($launch.Reason -ne 'FocusAlreadyActive') {
            Write-FocusLog -Level ERROR -Event 'CompatibilityFocusLaunchFailed' -Data @{ Reason = $launch.Reason } -Now $Now -LogDirectory $LogDirectory
            return 11
        }

        if (-not (Ensure-DoNotDisturbOff)) {
            Write-FocusLog -Level ERROR -Event 'CompatibilityDoNotDisturbDisableFailed' -Data @{} -Now $Now -LogDirectory $LogDirectory
            return 12
        }

        Write-FocusLog -Level INFO -Event 'CompatibilityTestPassed' -Data @{
            ClockVersion = $compatibility.ClockVersion
            DndOff       = $true
            EndTime      = $endTime.ToString('o')
        } -Now $Now -LogDirectory $LogDirectory
        return 0
    }
    catch {
        try {
            Write-FocusLog -Level ERROR -Event 'CompatibilityTestFailed' -Data @{ Reason = $_.Exception.Message } -Now $Now -LogDirectory $LogDirectory
        }
        catch {
            Write-Error '兼容性测试失败，且无法写入日志。'
            return 20
        }
        return 11
    }
    finally {
        if ($lock -is [System.Threading.Mutex]) {
            $lock.ReleaseMutex()
            $lock.Dispose()
        }
        elseif ($lock -is [System.IDisposable]) {
            $lock.Dispose()
        }
    }
}

function Get-FocusAutomationStatus {
    [CmdletBinding()]
    param([string]$LogDirectory = $script:DefaultLogDirectory)

    $compatibility = Test-ClockCompatibility
    $taskStatus = @()
    foreach ($definition in @(Get-FocusTaskDefinitions)) {
        $task = Get-ScheduledTask -TaskPath $script:FocusTaskPath -TaskName $definition.TaskName -ErrorAction SilentlyContinue
        $info = $null
        if ($null -ne $task) {
            $info = Get-ScheduledTaskInfo -TaskPath $script:FocusTaskPath -TaskName $definition.TaskName -ErrorAction SilentlyContinue
        }
        $taskStatus += [pscustomobject]@{
            TaskName    = $definition.TaskName
            Installed   = ($null -ne $task)
            State       = if ($null -ne $task) { [string]$task.State } else { 'Missing' }
            NextRunTime = if ($null -ne $info) { $info.NextRunTime } else { $null }
        }
    }

    $registryPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings'
    $dndOff = $false
    try {
        $settings = Get-ItemProperty -LiteralPath $registryPath -Name 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' -ErrorAction Stop
        $dndOff = ([int]$settings.NOC_GLOBAL_SETTING_TOASTS_ENABLED -eq 1)
    }
    catch { }

    $lastCleanup = $null
    $recentLogs = @()
    if (Test-Path -LiteralPath $LogDirectory) {
        $marker = Join-Path $LogDirectory '.last-cleanup'
        if (Test-Path -LiteralPath $marker) {
            $lastCleanup = (Get-Content -LiteralPath $marker -Raw -ErrorAction SilentlyContinue).Trim()
        }
        $recentLogs = @(Get-ChildItem -LiteralPath $LogDirectory -Filter 'focus-*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 2 |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Tail 5 -ErrorAction SilentlyContinue })
    }

    [pscustomobject]@{
        WindowsVersion    = [Environment]::OSVersion.Version.ToString()
        ClockVersion      = $compatibility.ClockVersion
        FocusSupported    = $compatibility.Supported
        Compatibility     = $compatibility.Reason
        DoNotDisturbOff   = $dndOff
        LastLogCleanup    = $lastCleanup
        Tasks             = $taskStatus
        RecentLogLines    = $recentLogs
    }
}

function Show-FocusAutomationStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Status)

    Write-Host ('Windows 版本：{0}' -f $Status.WindowsVersion)
    Write-Host ('时钟版本：{0}' -f $Status.ClockVersion)
    Write-Host ('专注接口：{0}（{1}）' -f $(if ($Status.FocusSupported) { '支持' } else { '不支持' }), $Status.Compatibility)
    Write-Host ('勿扰状态：{0}' -f $(if ($Status.DoNotDisturbOff) { '关闭' } else { '未确认关闭' }))
    Write-Host ('上次日志清理：{0}' -f $(if ($Status.LastLogCleanup) { $Status.LastLogCleanup } else { '尚未执行' }))
    foreach ($task in $Status.Tasks) {
        $nextRun = if ($task.NextRunTime) { $task.NextRunTime } else { '无' }
        Write-Host ('计划任务：{0}；已安装={1}；状态={2}；下次运行={3}' -f $task.TaskName, $task.Installed, $task.State, $nextRun)
    }
    if ($Status.RecentLogLines.Count -gt 0) {
        Write-Host '最近日志：'
        $Status.RecentLogLines | ForEach-Object { Write-Host ('  {0}' -f $_) }
    }
}

function Invoke-WindowsFocusAutomation {
    [CmdletBinding()]
    param(
        [ValidateSet('Install', 'Run', 'Test', 'Status', 'Uninstall')]
        [string]$Mode,

        [ValidateSet('Afternoon', 'Evening')]
        [string]$Window,

        [switch]$WhatIf
    )

    switch ($Mode) {
        'Run' {
            if (-not $Window) {
                Write-Error 'Run 模式必须指定 -Window Afternoon 或 -Window Evening。'
                return 2
            }
            return Invoke-FocusRun -Window $Window -WhatIf:$WhatIf
        }
        'Test' {
            return Invoke-FocusCompatibilityTest -WhatIf:$WhatIf
        }
        'Install' {
            if ($WhatIf) {
                Invoke-FocusCompatibilityTest -WhatIf | Out-Null
                Register-FocusScheduledTasks -ScriptPath $PSCommandPath -WhatIf
                return 0
            }

            $testExitCode = Invoke-FocusCompatibilityTest
            if ($testExitCode -ne 0) {
                return $testExitCode
            }
            try {
                Register-FocusScheduledTasks -ScriptPath $PSCommandPath | Out-Null
                Write-Host '安装完成：两个自动专注任务已启用。'
                return 0
            }
            catch {
                Write-Error ('安装计划任务失败：{0}' -f $_.Exception.Message)
                return 30
            }
        }
        'Status' {
            Show-FocusAutomationStatus -Status (Get-FocusAutomationStatus)
            return 0
        }
        'Uninstall' {
            Unregister-FocusScheduledTasks -WhatIf:$WhatIf
            if ($WhatIf) {
                Write-Host ('预演：移除日志目录 {0}' -f $script:DefaultLogDirectory)
                return 0
            }
            if (Test-Path -LiteralPath $script:DefaultLogDirectory) {
                Remove-Item -LiteralPath $script:DefaultLogDirectory -Recurse -Force -ErrorAction Stop
            }
            Write-Host '卸载完成：计划任务和运行日志已移除；脚本与说明文件已保留。'
            return 0
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $dispatchParameters = @{
        Mode   = $Mode
        WhatIf = $WhatIf
    }
    if ($Window) {
        $dispatchParameters.Window = $Window
    }
    exit (Invoke-WindowsFocusAutomation @dispatchParameters)
}
