$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$scriptPath = Join-Path $projectRoot 'WindowsFocusAutomation.ps1'

if (Test-Path -LiteralPath $scriptPath) {
    . $scriptPath
}

Describe 'Time window decisions' {
    It 'defines the afternoon and evening windows' {
        $afternoon = Get-FocusWindowDefinition -Window 'Afternoon'
        $evening = Get-FocusWindowDefinition -Window 'Evening'

        $afternoon.Name | Should Be 'Afternoon'
        $afternoon.Start | Should Be ([TimeSpan]::FromHours(14))
        $afternoon.End | Should Be ([TimeSpan]::FromMinutes(16 * 60 + 20))
        $evening.Start | Should Be ([TimeSpan]::FromHours(21))
        $evening.End | Should Be ([TimeSpan]::FromHours(23))
    }

    $afternoonCases = @(
        @{ At = '2026-09-29 13:59:00'; Action = 'Skip'; Minutes = 0; Reason = 'BeforeWindow' },
        @{ At = '2026-09-29 14:00:00'; Action = 'Start'; Minutes = 140; Reason = 'WithinWindow' },
        @{ At = '2026-09-29 14:35:00'; Action = 'Start'; Minutes = 105; Reason = 'WithinWindow' },
        @{ At = '2026-09-29 16:19:30'; Action = 'Start'; Minutes = 1; Reason = 'WithinWindow' },
        @{ At = '2026-09-29 16:20:00'; Action = 'Skip'; Minutes = 0; Reason = 'WindowEnded' },
        @{ At = '2026-09-29 17:00:00'; Action = 'Skip'; Minutes = 0; Reason = 'WindowEnded' }
    )

    foreach ($case in $afternoonCases) {
        It "handles afternoon boundary $($case.At)" {
            $definition = Get-FocusWindowDefinition -Window 'Afternoon'
            $result = Get-FocusRunDecision -Definition $definition -Now ([datetime]$case.At)

            $result.Action | Should Be $case.Action
            $result.DurationMinutes | Should Be $case.Minutes
            $result.Reason | Should Be $case.Reason
        }
    }

    $eveningCases = @(
        @{ At = '2026-09-29 20:59:00'; Action = 'Skip'; Minutes = 0; Reason = 'BeforeWindow' },
        @{ At = '2026-09-29 21:00:00'; Action = 'Start'; Minutes = 120; Reason = 'WithinWindow' },
        @{ At = '2026-09-29 21:40:00'; Action = 'Start'; Minutes = 80; Reason = 'WithinWindow' },
        @{ At = '2026-09-29 22:59:30'; Action = 'Start'; Minutes = 1; Reason = 'WithinWindow' },
        @{ At = '2026-09-29 23:00:00'; Action = 'Skip'; Minutes = 0; Reason = 'WindowEnded' },
        @{ At = '2026-09-29 23:10:00'; Action = 'Skip'; Minutes = 0; Reason = 'WindowEnded' }
    )

    foreach ($case in $eveningCases) {
        It "handles evening boundary $($case.At)" {
            $definition = Get-FocusWindowDefinition -Window 'Evening'
            $result = Get-FocusRunDecision -Definition $definition -Now ([datetime]$case.At)

            $result.Action | Should Be $case.Action
            $result.DurationMinutes | Should Be $case.Minutes
            $result.Reason | Should Be $case.Reason
        }
    }

    It 'rejects an unknown window name' {
        { Get-FocusWindowDefinition -Window 'Night' } | Should Throw
    }

    It 'uses the current local calendar date for the end time' {
        $now = [datetime]::SpecifyKind([datetime]'2026-03-29 14:35:00', [DateTimeKind]::Local)
        $definition = Get-FocusWindowDefinition -Window 'Afternoon'
        $result = Get-FocusRunDecision -Definition $definition -Now $now

        $result.EndTime.Date | Should Be $now.Date
        $result.EndTime.TimeOfDay | Should Be ([TimeSpan]::FromMinutes(16 * 60 + 20))
    }
}

Describe 'Native Clock focus launch' {
    It 'builds the Clock focus URI with the fixed UTC end time' {
        $endTime = [datetime]::SpecifyKind([datetime]'2026-09-29 16:20:00', [DateTimeKind]::Utc)

        $uri = New-FocusSessionUri -EndTime $endTime

        $uri | Should Be 'ms-clock://createfocustimer?skipBreaks=false&displayMode=aot&force=true&endTime=1790698800000'
    }

    It 'does not open Clock during WhatIf' {
        Mock Start-Process { throw 'Start-Process must not be called' }
        $endTime = [datetime]::SpecifyKind([datetime]'2026-09-29 16:20:00', [DateTimeKind]::Utc)

        $result = Start-NativeFocusSession -EndTime $endTime -WhatIf

        $result.Started | Should Be $false
        $result.Reason | Should Be 'WhatIf'
        Assert-MockCalled Start-Process -Times 0 -Scope It
    }

    It 'requests Clock exactly once with the generated URI' {
        Mock Start-Process { }
        Mock Test-FocusSessionActive { $false }
        $endTime = [datetime]::SpecifyKind([datetime]'2026-09-29 16:20:00', [DateTimeKind]::Utc)

        $result = Start-NativeFocusSession -EndTime $endTime

        $result.Started | Should Be $true
        $result.Reason | Should Be 'LaunchRequested'
        $result.Uri | Should Be 'ms-clock://createfocustimer?skipBreaks=false&displayMode=aot&force=true&endTime=1790698800000'
        Assert-MockCalled Start-Process -Times 1 -Scope It -ParameterFilter { $FilePath -eq $result.Uri }
    }

    It 'does not replace an already active Focus session' {
        Mock Test-FocusSessionActive { $true }
        Mock Start-Process { throw 'Clock must not be opened' }
        $endTime = [datetime]::SpecifyKind([datetime]'2026-09-29 16:20:00', [DateTimeKind]::Utc)

        $result = Start-NativeFocusSession -EndTime $endTime

        $result.Started | Should Be $false
        $result.Reason | Should Be 'FocusAlreadyActive'
        Assert-MockCalled Start-Process -Times 0 -Scope It
    }

    It 'finds the installed Windows Clock package' {
        $package = Get-ClockPackage

        $package.Name | Should Be 'Microsoft.WindowsAlarms'
        $package.Version.ToString() | Should Not BeNullOrEmpty
    }

    It 'detects the registered ms-clock protocol' {
        Test-MsClockProtocolRegistered | Should Be $true
    }

    It 'detects support for the public Focus state API' {
        Test-FocusApiSupported | Should Be $true
    }

    It 'reports the current system as compatible' {
        $result = Test-ClockCompatibility

        $result.Supported | Should Be $true
        $result.ClockVersion | Should Not BeNullOrEmpty
        $result.Reason | Should Be 'Supported'
    }

    It 'reports a missing Clock package' {
        Mock Get-ClockPackage { $null }

        $result = Test-ClockCompatibility

        $result.Supported | Should Be $false
        $result.Reason | Should Be 'ClockPackageMissing'
    }

    It 'reports a missing ms-clock protocol' {
        Mock Get-ClockPackage { [pscustomobject]@{ Version = [version]'11.2607.6.0' } }
        Mock Test-MsClockProtocolRegistered { $false }

        $result = Test-ClockCompatibility

        $result.Supported | Should Be $false
        $result.Reason | Should Be 'ClockProtocolMissing'
    }

    It 'reports an unsupported Focus state API' {
        Mock Get-ClockPackage { [pscustomobject]@{ Version = [version]'11.2607.6.0' } }
        Mock Test-MsClockProtocolRegistered { $true }
        Mock Test-FocusApiSupported { $false }

        $result = Test-ClockCompatibility

        $result.Supported | Should Be $false
        $result.Reason | Should Be 'FocusApiUnsupported'
    }

    It 'returns a Boolean Focus-active state' {
        (Test-FocusSessionActive).GetType().FullName | Should Be 'System.Boolean'
    }
}

Describe 'Do Not Disturb enforcement' {
    It 'sets and verifies the current-user notification switch as DWORD 1' {
        Mock New-Item { }
        Mock New-ItemProperty { }
        Mock Get-ItemProperty {
            [pscustomobject]@{ NOC_GLOBAL_SETTING_TOASTS_ENABLED = 1 }
        }

        $result = Set-DoNotDisturbOff

        $result | Should Be $true
        Assert-MockCalled New-ItemProperty -Times 1 -Scope It -ParameterFilter {
            $LiteralPath -eq 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings' -and
            $Name -eq 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' -and
            $Value -eq 1 -and
            $PropertyType -eq 'DWord'
        }
    }

    It 'returns false when the notification registry value cannot be written' {
        Mock New-Item { }
        Mock New-ItemProperty { throw 'access denied' }

        Set-DoNotDisturbOff | Should Be $false
    }

    It 'returns false when Windows does not retain the off value' {
        Mock New-Item { }
        Mock New-ItemProperty { }
        Mock Get-ItemProperty {
            [pscustomobject]@{ NOC_GLOBAL_SETTING_TOASTS_ENABLED = 0 }
        }

        Set-DoNotDisturbOff | Should Be $false
    }

    It 'retries until Do Not Disturb is confirmed off' {
        $script:dndAttempts = 0
        Mock Set-DoNotDisturbOff {
            $script:dndAttempts++
            return ($script:dndAttempts -ge 2)
        }
        Mock Start-Sleep { }

        $result = Ensure-DoNotDisturbOff -Timeout ([TimeSpan]::FromSeconds(1)) -PollInterval ([TimeSpan]::FromMilliseconds(10))

        $result | Should Be $true
        $script:dndAttempts | Should Be 2
    }
}

Describe 'Logging and seven-day cleanup' {
    It 'writes a readable daily log containing only supplied event data' {
        $logDirectory = Join-Path $TestDrive 'logs-write'
        $now = [datetime]'2026-09-29 14:00:00'

        Write-FocusLog -Level 'INFO' -Event 'FocusStarted' -Data @{ Window = 'Afternoon'; Minutes = 140 } -Now $now -LogDirectory $logDirectory

        $logPath = Join-Path $logDirectory 'focus-2026-09-29.log'
        Test-Path -LiteralPath $logPath | Should Be $true
        $line = Get-Content -LiteralPath $logPath -Raw
        $line | Should Match '\[INFO\] FocusStarted'
        $line | Should Match 'Minutes=140'
        $line | Should Match 'Window=Afternoon'
        $line | Should Not Match [regex]::Escape($env:USERNAME)
    }

    It 'does not create files during WhatIf logging' {
        $logDirectory = Join-Path $TestDrive 'logs-whatif'

        Write-FocusLog -Level 'INFO' -Event 'DryRun' -Data @{} -Now ([datetime]'2026-09-29') -LogDirectory $logDirectory -WhatIf

        Test-Path -LiteralPath $logDirectory | Should Be $false
    }

    It 'skips cleanup when the last cleanup was less than seven days ago' {
        $logDirectory = Join-Path $TestDrive 'logs-recent-marker'
        New-Item -ItemType Directory -Path $logDirectory | Out-Null
        ([datetime]'2026-09-23').ToUniversalTime().ToString('o') | Set-Content -LiteralPath (Join-Path $logDirectory '.last-cleanup')

        $result = Invoke-LogMaintenance -Now ([datetime]'2026-09-29') -LogDirectory $logDirectory

        $result.Ran | Should Be $false
        $result.Reason | Should Be 'NotDue'
    }

    It 'deletes only logs older than seven days when cleanup is due' {
        $logDirectory = Join-Path $TestDrive 'logs-cleanup-due'
        New-Item -ItemType Directory -Path $logDirectory | Out-Null
        ([datetime]'2026-09-22').ToUniversalTime().ToString('o') | Set-Content -LiteralPath (Join-Path $logDirectory '.last-cleanup')
        $oldLog = New-Item -ItemType File -Path (Join-Path $logDirectory 'focus-2026-09-20.log')
        $recentLog = New-Item -ItemType File -Path (Join-Path $logDirectory 'focus-2026-09-28.log')
        $oldLog.LastWriteTime = [datetime]'2026-09-20'
        $recentLog.LastWriteTime = [datetime]'2026-09-28'

        $result = Invoke-LogMaintenance -Now ([datetime]'2026-09-29') -LogDirectory $logDirectory

        $result.Ran | Should Be $true
        $result.DeletedCount | Should Be 1
        Test-Path -LiteralPath $oldLog.FullName | Should Be $false
        Test-Path -LiteralPath $recentLog.FullName | Should Be $true
    }

    It 'runs cleanup when no marker exists' {
        $logDirectory = Join-Path $TestDrive 'logs-no-marker'

        $result = Invoke-LogMaintenance -Now ([datetime]'2026-09-29') -LogDirectory $logDirectory

        $result.Ran | Should Be $true
        Test-Path -LiteralPath (Join-Path $logDirectory '.last-cleanup') | Should Be $true
    }
}

Describe 'Duplicate run protection' {
    It 'allows only one owner of a window lock at a time' {
        $first = Enter-FocusRunLock -Window 'Afternoon'
        try {
            $first | Should Not BeNullOrEmpty
            $second = Enter-FocusRunLock -Window 'Afternoon'
            $second | Should BeNullOrEmpty
        }
        finally {
            if ($null -ne $first) {
                $first.ReleaseMutex()
                $first.Dispose()
            }
        }

        $third = Enter-FocusRunLock -Window 'Afternoon'
        try {
            $third | Should Not BeNullOrEmpty
        }
        finally {
            if ($null -ne $third) {
                $third.ReleaseMutex()
                $third.Dispose()
            }
        }
    }
}

Describe 'Scheduled run orchestration' {
    It 'waits until Windows reports Focus active' {
        $script:focusChecks = 0
        Mock Test-FocusSessionActive {
            $script:focusChecks++
            return ($script:focusChecks -ge 2)
        }
        Mock Start-Sleep { }

        $result = Wait-FocusSessionActive -Timeout ([TimeSpan]::FromSeconds(1)) -PollInterval ([TimeSpan]::FromMilliseconds(10))

        $result | Should Be $true
        $script:focusChecks | Should Be 2
    }

    It 'returns false when Focus is not active by the deadline' {
        Mock Test-FocusSessionActive { $false }
        Mock Start-Sleep { }

        Wait-FocusSessionActive -Timeout ([TimeSpan]::Zero) | Should Be $false
    }

    It 'skips safely before the selected window without opening Clock' {
        Mock Invoke-LogMaintenance { [pscustomobject]@{ Ran = $false; DeletedCount = 0; Reason = 'NotDue' } }
        Mock Start-NativeFocusSession { throw 'Clock must not be opened' }
        Mock Write-FocusLog { }

        $exitCode = Invoke-FocusRun -Window 'Afternoon' -Now ([datetime]'2026-09-29 13:59:00')

        $exitCode | Should Be 0
        Assert-MockCalled Start-NativeFocusSession -Times 0 -Scope It
    }

    It 'starts Focus, verifies it, and turns Do Not Disturb off' {
        Mock Invoke-LogMaintenance { [pscustomobject]@{ Ran = $false; DeletedCount = 0; Reason = 'NotDue' } }
        Mock Start-NativeFocusSession {
            [pscustomobject]@{ Started = $true; Uri = 'ms-clock://test'; Reason = 'LaunchRequested' }
        }
        Mock Wait-FocusSessionActive { $true }
        Mock Ensure-DoNotDisturbOff { $true }
        Mock Write-FocusLog { }

        $exitCode = Invoke-FocusRun -Window 'Afternoon' -Now ([datetime]'2026-09-29 14:00:00')

        $exitCode | Should Be 0
        Assert-MockCalled Ensure-DoNotDisturbOff -Times 1 -Scope It
        Assert-MockCalled Write-FocusLog -Times 1 -Scope It -ParameterFilter { $Event -eq 'FocusStarted' }
    }

    It 'fails when Focus cannot be confirmed active' {
        Mock Invoke-LogMaintenance { [pscustomobject]@{ Ran = $false; DeletedCount = 0; Reason = 'NotDue' } }
        Mock Start-NativeFocusSession {
            [pscustomobject]@{ Started = $true; Uri = 'ms-clock://test'; Reason = 'LaunchRequested' }
        }
        Mock Wait-FocusSessionActive { $false }
        Mock Ensure-DoNotDisturbOff { throw 'DND must not be changed' }
        Mock Write-FocusLog { }

        Invoke-FocusRun -Window 'Afternoon' -Now ([datetime]'2026-09-29 14:00:00') | Should Be 11
    }

    It 'fails when Do Not Disturb cannot be turned off' {
        Mock Invoke-LogMaintenance { [pscustomobject]@{ Ran = $false; DeletedCount = 0; Reason = 'NotDue' } }
        Mock Start-NativeFocusSession {
            [pscustomobject]@{ Started = $true; Uri = 'ms-clock://test'; Reason = 'LaunchRequested' }
        }
        Mock Wait-FocusSessionActive { $true }
        Mock Ensure-DoNotDisturbOff { $false }
        Mock Write-FocusLog { }

        Invoke-FocusRun -Window 'Afternoon' -Now ([datetime]'2026-09-29 14:00:00') | Should Be 12
    }

    It 'treats an already active Focus session as a safe skip' {
        Mock Invoke-LogMaintenance { [pscustomobject]@{ Ran = $false; DeletedCount = 0; Reason = 'NotDue' } }
        Mock Start-NativeFocusSession {
            [pscustomobject]@{ Started = $false; Uri = 'ms-clock://test'; Reason = 'FocusAlreadyActive' }
        }
        Mock Write-FocusLog { }

        Invoke-FocusRun -Window 'Afternoon' -Now ([datetime]'2026-09-29 14:00:00') | Should Be 0
    }

    It 'does not create logs, locks, or Clock requests during WhatIf' {
        $logDirectory = Join-Path $TestDrive 'run-whatif'
        Mock Enter-FocusRunLock { throw 'A lock must not be created' }
        Mock Invoke-LogMaintenance { throw 'Logs must not be maintained' }
        Mock Start-NativeFocusSession { throw 'Clock must not be opened' }

        $exitCode = Invoke-FocusRun -Window 'Afternoon' -Now ([datetime]'2026-09-29 14:00:00') -LogDirectory $logDirectory -WhatIf

        $exitCode | Should Be 0
        Test-Path -LiteralPath $logDirectory | Should Be $false
    }
}

Describe 'Scheduled task lifecycle' {
    BeforeEach {
        Mock Get-ScheduledTask { $null }
        Mock Export-ScheduledTask { '<Task />' }
        Mock New-ScheduledTaskAction { New-Object Microsoft.Management.Infrastructure.CimInstance('MSFT_TaskAction', 'Root/Microsoft/Windows/TaskScheduler') }
        Mock New-ScheduledTaskTrigger { New-Object Microsoft.Management.Infrastructure.CimInstance('MSFT_TaskTrigger', 'Root/Microsoft/Windows/TaskScheduler') }
        Mock New-ScheduledTaskSettingsSet { New-Object Microsoft.Management.Infrastructure.CimInstance('MSFT_TaskSettings', 'Root/Microsoft/Windows/TaskScheduler') }
        Mock New-ScheduledTaskPrincipal { New-Object Microsoft.Management.Infrastructure.CimInstance('MSFT_TaskPrincipal', 'Root/Microsoft/Windows/TaskScheduler') }
        Mock Register-ScheduledTask { [pscustomobject]@{ TaskName = $TaskName } }
        Mock Unregister-ScheduledTask { }
    }

    It 'defines exactly two fixed daily tasks' {
        $definitions = @(Get-FocusTaskDefinitions)

        $definitions.Count | Should Be 2
        $definitions[0].TaskName | Should Be 'WindowsFocusAutomation-Afternoon'
        $definitions[0].Window | Should Be 'Afternoon'
        $definitions[0].At | Should Be ([TimeSpan]::FromHours(14))
        $definitions[1].TaskName | Should Be 'WindowsFocusAutomation-Evening'
        $definitions[1].Window | Should Be 'Evening'
        $definitions[1].At | Should Be ([TimeSpan]::FromHours(21))
    }

    It 'registers both tasks with native PowerShell and safe settings' {
        Register-FocusScheduledTasks -ScriptPath $scriptPath | Out-Null

        Assert-MockCalled Register-ScheduledTask -Times 2 -Scope It -ParameterFilter {
            $TaskPath -eq '\WindowsFocusAutomation\' -and $Force
        }
        Assert-MockCalled New-ScheduledTaskTrigger -Times 1 -Scope It -ParameterFilter {
            $Daily -and $At.TimeOfDay -eq ([TimeSpan]::FromHours(14))
        }
        Assert-MockCalled New-ScheduledTaskTrigger -Times 1 -Scope It -ParameterFilter {
            $Daily -and $At.TimeOfDay -eq ([TimeSpan]::FromHours(21))
        }
        Assert-MockCalled New-ScheduledTaskSettingsSet -Times 2 -Scope It -ParameterFilter {
            $StartWhenAvailable -and -not $WakeToRun -and $MultipleInstances -eq 'IgnoreNew'
        }
        Assert-MockCalled New-ScheduledTaskPrincipal -Times 2 -Scope It -ParameterFilter {
            $LogonType -eq 'Interactive' -and $RunLevel -eq 'Limited'
        }
        Assert-MockCalled New-ScheduledTaskAction -Times 1 -Scope It -ParameterFilter {
            $Execute -eq 'powershell.exe' -and
            $Argument -match '-Mode Run -Window Afternoon' -and
            $Argument -match [regex]::Escape($scriptPath)
        }
    }

    It 'removes a newly created first task when the second registration fails' {
        $script:registrationAttempt = 0
        Mock Register-ScheduledTask {
            $script:registrationAttempt++
            if ($script:registrationAttempt -eq 2) { throw 'second registration failed' }
        }

        { Register-FocusScheduledTasks -ScriptPath $scriptPath } | Should Throw

        Assert-MockCalled Unregister-ScheduledTask -Times 1 -Scope It -ParameterFilter {
            $TaskPath -eq '\WindowsFocusAutomation\' -and
            $TaskName -eq 'WindowsFocusAutomation-Afternoon'
        }
    }

    It 'does not inspect or change tasks during WhatIf' {
        Mock Get-ScheduledTask { throw 'Tasks must not be inspected' }
        Mock Register-ScheduledTask { throw 'Tasks must not be registered' }

        Register-FocusScheduledTasks -ScriptPath $scriptPath -WhatIf | Out-Null

        Assert-MockCalled Register-ScheduledTask -Times 0 -Scope It
    }

    It 'uninstalls only the two tool-owned task names' {
        Unregister-FocusScheduledTasks | Out-Null

        Assert-MockCalled Unregister-ScheduledTask -Times 2 -Scope It -ParameterFilter {
            $TaskPath -eq '\WindowsFocusAutomation\' -and
            $TaskName -in @('WindowsFocusAutomation-Afternoon', 'WindowsFocusAutomation-Evening')
        }
    }
}

Describe 'Command modes' {
    It 'passes a one-minute live compatibility test' {
        Mock Test-ClockCompatibility { [pscustomobject]@{ Supported = $true; Reason = 'Supported'; ClockVersion = '11.0' } }
        Mock Enter-FocusRunLock { [pscustomobject]@{} }
        Mock Start-NativeFocusSession { [pscustomobject]@{ Started = $true; Uri = 'ms-clock://test'; Reason = 'LaunchRequested' } }
        Mock Wait-FocusSessionActive { $true }
        Mock Ensure-DoNotDisturbOff { $true }
        Mock Invoke-LogMaintenance { }
        Mock Write-FocusLog { }

        Invoke-FocusCompatibilityTest -Now ([datetime]'2026-09-29 12:00:00') | Should Be 0

        Assert-MockCalled Start-NativeFocusSession -Times 1 -Scope It -ParameterFilter {
            $EndTime -eq ([datetime]'2026-09-29 12:01:00')
        }
        Assert-MockCalled Ensure-DoNotDisturbOff -Times 1 -Scope It
    }

    It 'does not perform a live test during WhatIf' {
        Mock Test-ClockCompatibility { throw 'Compatibility must not be queried' }
        Mock Start-NativeFocusSession { throw 'Clock must not be opened' }

        Invoke-FocusCompatibilityTest -WhatIf | Should Be 0

        Assert-MockCalled Start-NativeFocusSession -Times 0 -Scope It
    }
}
