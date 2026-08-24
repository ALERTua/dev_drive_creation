# Pester 5 checks for dev_drive.ps1.
#
# These never touch storage and never need administrator rights. They cover the two things where a
# wrong answer would be silent: the layout of the structures passed to virtdisk.dll, and the rules
# that decide what a typed answer means. Everything that partitions or formats stays manual.
#
#   Invoke-Pester -Path .\dev_drive.Tests.ps1

#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    # The script itself runs under strict mode, and some of it behaves differently without it:
    # indexing past the end of an array is silent here and an exception there.
    Set-StrictMode -Version Latest

    $script:ScriptPath = Join-Path $PSScriptRoot 'dev_drive.ps1'

    # dev_drive.ps1 is a linear script that starts asking questions when it runs, so its functions
    # are lifted out of the syntax tree instead of dot-sourcing the file.
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) {
        throw "dev_drive.ps1 does not parse: $($parseErrors[0].Message)"
    }

    $functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    foreach ($function in $functions) {
        . ([scriptblock]::Create($function.Extent.Text))
    }

    Initialize-VirtDiskInterop

    # A machine without the BitLocker feature has no Get-BitLockerVolume for Mock to bind to.
    if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        function Get-BitLockerVolume {
            param([string]$MountPoint)
            throw "BitLocker is not available on this machine, so $MountPoint cannot be read."
        }
    }

    # Same for the ReFS deduplication module, which is not present on every Windows.
    if (-not (Get-Command Get-ReFSDedupSchedule -ErrorAction SilentlyContinue)) {
        function Get-ReFSDedupSchedule {
            param([string]$Volume)
            throw "ReFS deduplication is not available on this machine, so $Volume cannot be read."
        }
    }

    # Stands in for one entry of a BitLocker volume's KeyProtector list.
    function New-Protector {
        param([string]$Type, [string]$Id)
        return [PSCustomObject]@{ KeyProtectorType = $Type; KeyProtectorId = $Id }
    }
}

Describe 'The script itself' {
    It 'parses with no errors' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }

    # The suite lifts functions out of the syntax tree and never runs the linear part, so the only
    # thing that can guard a top-level statement is its presence in the file.
    It 'turns on strict mode' {
        Select-String -Path $script:ScriptPath -Pattern '^Set-StrictMode -Version Latest' |
            Should -Not -BeNullOrEmpty
    }

    It 'declares the Dev Drive minimum exactly once' {
        @(Select-String -Path $script:ScriptPath -Pattern '^\$DevDriveMinSizeGB\s*=').Count | Should -Be 1
    }

    It 'sets the minimum to Microsoft''s documented 50 GB' {
        $line = Select-String -Path $script:ScriptPath -Pattern '^\$DevDriveMinSizeGB\s*=\s*(\d+)'
        [int]$line.Matches[0].Groups[1].Value | Should -Be 50
    }

    It 'declares the shrink head-room exactly once' {
        @(Select-String -Path $script:ScriptPath -Pattern '^\$ShrinkSpareBytes\s*=').Count | Should -Be 1
    }

    It 'never lets an untyped 0 choose the overload of a Math comparison' {
        # A bare 0 is an Int32, so Max/Min bind their Int32 overload: the other argument is rounded,
        # and a byte count too big for an Int32 throws instead.
        Select-String -Path $script:ScriptPath -Pattern '\[math\]::(Max|Min)\(\s*0\s*,' |
            Should -BeNullOrEmpty
    }

    It 'prints the intro banner right after the administrator requirement and before the Windows build check' {
        # The admin requirement is a #Requires statement, enforced before any script statement
        # runs, so nothing can print ahead of it; this checks the banner is the very next thing.
        $content = Get-Content -Path $script:ScriptPath -Raw
        $adminCheckAt = $content.IndexOf('#Requires -RunAsAdministrator')
        $bannerCallAt = $content.LastIndexOf('Resolve-AutomationBanner')
        $buildCheckAt = $content.IndexOf('# Check Windows version')
        $adminCheckAt | Should -BeGreaterThan -1
        $bannerCallAt | Should -BeGreaterThan $adminCheckAt
        $buildCheckAt | Should -BeGreaterThan $bannerCallAt
    }

    It 'exits non-zero when the Windows build is too old' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $matched = $content -match '(?ms)Write-Error "Your Windows build.*?\r?\n\s*exit\s+(\d+)'
        $matched | Should -BeTrue
        [int]$Matches[1] | Should -Be 1
    }

    It 'does not claim the weekly scrub job runs at a time it never schedules' {
        Select-String -Path $script:ScriptPath -Pattern 'Scheduled weekly scrub job on .* at 12:00' |
            Should -BeNullOrEmpty
    }

    # A user who picked their own times was shown 11:00 and 17:00 in the plan, because the line was
    # a literal. Only the source can be checked: the plan is printed by the linear part.
    It 'asks the schedule question only inside the SkipDeduplication guard, then stores the answer' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $content | Should -Match ('(?ms)if \(-not \$SkipDeduplication\) \{\s*\r?\n\s*' +
            '\$dedupSchedule = Request-DedupSchedule .*?\r?\n\s*' +
            '\$DedupStartTimes = \$dedupSchedule\.DailyTimes\s*\r?\n\s*' +
            '\$ScrubDays = \$dedupSchedule\.WeeklyDay\s*\r?\n\s*' +
            '\$ScrubStart = \$dedupSchedule\.WeeklyStart\s*\r?\n\s*\}')
    }

    It 'builds the plan summary, schedules and reminds using the chosen values, not a literal or a stale default' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $content | Should -Not -Match '\* Schedule daily optimization jobs at 11:00 and 17:00'
        $content | Should -Match 'Format-DedupScheduleSummary -DailyTimes \$DedupStartTimes'
        $content | Should -Match 'foreach \(\$time in \$DedupStartTimes\)'
        $content | Should -Match 'Set-ReFSDedupScrubSchedule -Volume "\$devLetterColon" -Days \$ScrubDays -Start \$ScrubStart'
        $content | Should -Match ('(?ms)Resolve-DedupScheduleReminder -DailyTimes \$DedupStartTimes .*?' +
            '-WeeklyDay \$ScrubDays -WeeklyStart \$ScrubStart')
    }

    It 'configures the mains-power condition only after the weekly maintenance job it must cover' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $weeklyAt = $content.IndexOf('Set-ReFSDedupScrubSchedule -Volume "$devLetterColon"')
        $acPowerAt = $content.IndexOf('Configuring the ReFS optimization tasks to run only on AC power')
        $weeklyAt | Should -BeGreaterThan 0
        $acPowerAt | Should -BeGreaterThan $weeklyAt
    }

    It 'takes the fsutil devdrv trust exit code before any other command can overwrite it' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $content | Should -Match '(?ms)fsutil devdrv trust /f "\$devLetterColon" \| Out-Null(?:\s*\r?\n\s*#[^\r\n]*)*\s*\r?\n\s*\$trustExitCode = \$LASTEXITCODE'
    }

    It 'asks the volume for its trust state as well as reading the exit code' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $codeAt = $content.IndexOf('$trustExitCode = $LASTEXITCODE')
        $queryAt = $content.IndexOf('$trustQuery = (fsutil devdrv query')
        $reportAt = $content.IndexOf('$trustReport = Resolve-DevDriveTrustReport')
        $codeAt | Should -BeGreaterThan 0
        $queryAt | Should -BeGreaterThan $codeAt
        $reportAt | Should -BeGreaterThan $queryAt
    }

    It 'asks the volume what it stored after the daily schedules and before the weekly one' {
        # Reading before the scrub schedule is written is what lets the first entry answer for the
        # daily jobs; after it, a scrub entry could answer instead.
        $content = Get-Content -Path $script:ScriptPath -Raw
        $dailyAt = $content.IndexOf('Write-Host "Scheduled the daily jobs"')
        $readBackAt = $content.IndexOf('$dedupVerdict = Resolve-DedupReadBackVerdict')
        $scrubAt = $content.IndexOf('Set-ReFSDedupScrubSchedule -Volume "$devLetterColon"')
        $dailyAt | Should -BeGreaterThan 0
        $readBackAt | Should -BeGreaterThan $dailyAt
        $scrubAt | Should -BeGreaterThan $readBackAt
    }

    It 'compares the read-back against what the run asked for, not against literals' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $content | Should -Match '(?ms)Resolve-DedupReadBackVerdict -MountPoint \$devLetterColon -ExpectedMode \$DedupMode `\s*\r?\n\s*-ExpectedFormat \$CompressionFormat -ExpectedLevel \$CompressionLevel'
    }

    It 'colours the trust lines by the outcome, so only a real failure is printed as one' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $content | Should -Match "switch \(\`$trustReport\.Outcome\) \{ 'Trusted' \{ 'Green' \} 'Unconfirmed' \{ 'Gray' \} default \{ 'Yellow' \} \}"
        $content | Should -Match '(?ms)foreach \(\$line in \$trustReport\.Lines\) \{\s*\r?\n\s*Write-Host \$line -ForegroundColor \$trustColour'
    }

    It 'strips the error record before rendering the query output, so a stderr line stays one line' {
        Select-String -Path $script:ScriptPath -Pattern 'fsutil devdrv query "\$devLetterColon" 2>&1 \| ForEach-Object \{ "\$_" \} \| Out-String' |
            Should -Not -BeNullOrEmpty
    }

    It 'starts the compression level unset, so no message can print one nobody chose' {
        Select-String -Path $script:ScriptPath -Pattern '^\$CompressionLevel = \$null' |
            Should -Not -BeNullOrEmpty
        Select-String -Path $script:ScriptPath -Pattern '^\$CompressionLevel = \d' |
            Should -BeNullOrEmpty
    }

    It 'builds every message about the mode through the one helper that knows the modes' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        ([regex]::Matches($content, 'Format-DedupModeChoice -Mode \$DedupMode -Format \$CompressionFormat -Level \$CompressionLevel')).Count |
            Should -Be 3
        Select-String -Path $script:ScriptPath -Pattern 'Write-Host "[^"]*(?<!-Level )\$CompressionLevel' |
            Should -BeNullOrEmpty
    }

    It 'never asks what a mode supports by comparing the run''s own mode to a name' {
        # Separate re-derivations of "is this compressing" are how compress-only came to send the
        # parameters Windows refuses; one of them drifts from the rest and nothing notices.
        # Format-DedupModeChoice still names the three modes, which is wording rather than capability.
        $content = Get-Content -Path $script:ScriptPath -Raw
        ([regex]::Matches($content, "\`$DedupMode -\w+ '")).Count | Should -Be 0
        ([regex]::Matches($content, "\`$ExpectedMode -\w+ '")).Count | Should -Be 0
    }

    It 'puts every block deduplication parameter inside the branch that allows it' {
        # Measured on a live compression-only volume: CpuPercentage is refused outright, a scrub
        # schedule is refused outright, and Duration is accepted and silently dropped. A test that
        # only looked for a guard above each line would pass an inverted one, so this asks the
        # syntax tree which branch body each line actually sits in.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $guards = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.IfStatementAst] -and
                    $node.Clauses[0].Item1.Extent.Text -eq '$DedupCapability.UsesBlockDedup'
                }, $true))
        $guards.Count | Should -BeGreaterThan 0

        $bodies = @($guards | ForEach-Object { $_.Clauses[0].Item2.Extent })
        $content = Get-Content -Path $script:ScriptPath -Raw
        $needles = @(
            'CpuPercentage = $DedupDailyCpuPercent'
            'CpuPercentage = 60'
            'Set-ReFSDedupScrubSchedule -Volume'
            'Duration = New-TimeSpan -Hours $DedupDailyDurationHours'
            '(${DedupDailyDurationHours}h)'
        )
        foreach ($needle in $needles) {
            $at = $content.IndexOf($needle)
            $at | Should -BeGreaterThan 0
            @($bodies | Where-Object { $at -gt $_.StartOffset -and $at -lt $_.EndOffset }).Count |
                Should -BeGreaterThan 0
        }
    }

    It 'says the weekly job is being skipped rather than passing over it in silence' {
        # The guard that holds the scrub call must have an else, and the else must say something.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $scrubGuard = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.IfStatementAst] -and
                    $node.Clauses[0].Item1.Extent.Text -eq '$DedupCapability.UsesBlockDedup' -and
                    $node.Clauses[0].Item2.Extent.Text -match 'Set-ReFSDedupScrubSchedule'
                }, $true))
        $scrubGuard.Count | Should -Be 1
        $scrubGuard[0].ElseClause | Should -Not -BeNullOrEmpty
        $scrubGuard[0].ElseClause.Extent.Text | Should -Match 'No weekly scrub job'
    }

    It 'reaches the compression wording only through the mode helper' {
        # One call, inside Format-DedupModeChoice: no message may name a format without its mode.
        ([regex]::Matches((Get-Content -Path $script:ScriptPath -Raw), 'Format-CompressionChoice -Format')).Count |
            Should -Be 1
    }

    It 'takes the format and the level from one answer, so neither is set without the other' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $content | Should -Match '(?ms)\$compression = Request-Compression\s*\r?\n\s*\$CompressionFormat = \$compression\.Format\s*\r?\n\s*\$CompressionLevel = \$compression\.Level'
        $content | Should -Not -Match '\$CompressionFormat = Request-CompressionFormat'
        $content | Should -Not -Match "if \(\`$CompressionFormat -eq 'ZSTD'\) \{\s*\r?\n\s*\`$CompressionLevel = Request"
    }

    It 'leaves the level out of the calls to Windows when nobody chose one' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        ([regex]::Matches($content, 'if \(\$null -ne \$CompressionLevel\) \{')).Count | Should -Be 2
        $content | Should -Not -Match "if \(\`$CompressionFormat -eq 'ZSTD'\) \{\s*\r?\n\s*\`$\w+\.CompressionLevel"
    }

    It 'prints a plan summary line when BitLocker is skipped' {
        Select-String -Path $script:ScriptPath -Pattern '\* Skip BitLocker encryption' |
            Should -Not -BeNullOrEmpty
    }

    It 'creates the recovery key with Enable-BitLocker instead of a separate protector' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $content | Should -Match 'Enable-BitLocker -MountPoint \$devLetterColon -RecoveryPasswordProtector'
        $content | Should -Not -Match 'Add-BitLockerKeyProtector[^\r\n]*-RecoveryPasswordProtector'
    }

    It 'settles the BitLocker facts before it prints the plan for confirmation' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $planLine = $content.IndexOf('$bitLockerPlan = Resolve-BitLockerSetupPlan')
        $summaryLine = $content.IndexOf('* Enable BitLocker encryption for the Dev Drive')
        $planLine | Should -BeGreaterThan 0
        $summaryLine | Should -BeGreaterThan $planLine
    }

    It 'shows the recovery key before it touches the domain account protector' {
        # That protector is the call that fails on a machine with no domain, and a key the user
        # never saw must never be the thing they are told to keep.
        $content = Get-Content -Path $script:ScriptPath -Raw
        $enableAt = $content.IndexOf('Enable-BitLocker -MountPoint $devLetterColon')
        $bannerAt = $content.IndexOf('BITLOCKER RECOVERY KEY FOR')
        $adAt = $content.IndexOf('-AdAccountOrGroupProtector')
        $backupAt = $content.IndexOf('BackupToAAD-BitLockerKeyProtector -MountPoint')
        $enableAt | Should -BeGreaterThan 0
        $bannerAt | Should -BeGreaterThan $enableAt
        $adAt | Should -BeGreaterThan $bannerAt
        $backupAt | Should -BeGreaterThan $bannerAt
    }

    It 'formats the volume with the name that was asked for, never a hard-coded one' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $content | Should -Match 'Format-Volume[^\r\n]*-NewFileSystemLabel \$DevDriveLabel'
        # Either quote style would be a literal, and so would a bare word.
        $content | Should -Not -Match 'Format-Volume[^\r\n]*-NewFileSystemLabel [^$\r\n]'
    }

    It 'asks for the name before it prints the plan for confirmation' {
        # Nothing may be created before the plan is agreed, so the name has to be settled with the rest.
        $content = Get-Content -Path $script:ScriptPath -Raw
        $askedAt = $content.IndexOf('$DevDriveLabel = Request-DevDriveLabel')
        $planAt = $content.IndexOf('* Name the Dev Drive $DevDriveLabel')
        $formatAt = $content.IndexOf('Format-Volume -DriveLetter $devLetter')
        $askedAt | Should -BeGreaterThan 0
        $planAt | Should -BeGreaterThan $askedAt
        $formatAt | Should -BeGreaterThan $planAt
    }

    It 'reads the name back off the volume instead of reporting the one it sent' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $formatAt = $content.IndexOf('Format-Volume -DriveLetter $devLetter')
        $readAt = $content.IndexOf('$actualLabel = Get-VolumeLabel -DriveLetter $devLetter')
        $reportAt = $content.IndexOf('Resolve-DevDriveLabelReport -DriveLetter $devLetter')
        $readAt | Should -BeGreaterThan $formatAt
        $reportAt | Should -BeGreaterThan $readAt
    }

    It 'keeps the name length cap in one place rather than beside every use of it' {
        # A default written out as a literal drifts from the constant without anything noticing.
        $content = Get-Content -Path $script:ScriptPath -Raw
        ([regex]::Matches($content, '(?m)^\$DevDriveLabelMaxLength\s*=')).Count | Should -Be 1
        ([regex]::Matches($content, '(?m)^\$DevDriveDefaultLabel\s*=')).Count | Should -Be 1
        ([regex]::Matches($content, '\$MaxLength = \$script:DevDriveLabelMaxLength')).Count | Should -Be 2
        ([regex]::Matches($content, '\$MaxLength = \d')).Count | Should -Be 0
    }

    It 'reads the write-access setting before it asks about BitLocker, and whatever the answer' {
        # The four other machine facts are read only when BitLocker is chosen. This one decides
        # whether declining leaves an unusable drive, so it has to be read either way, and first.
        $content = Get-Content -Path $script:ScriptPath -Raw
        $readAt = $content.IndexOf('$WritePolicy = Get-FixedDriveWritePolicy')
        $askAt = $content.IndexOf('$enableBitLocker = Request-BitLockerChoice')
        $gateAt = $content.IndexOf('if ($enableBitLocker) {')
        $readAt | Should -BeGreaterThan 0
        $askAt | Should -BeGreaterThan $readAt
        $gateAt | Should -BeGreaterThan $readAt
        # Read unconditionally: a run that declines BitLocker needs this fact most of all.
        ([regex]::Matches($content, '(?m)^\$WritePolicy = Get-FixedDriveWritePolicy')).Count | Should -Be 1
        # And handed to the question, or the person answers without knowing it.
        $content | Should -Match '-Notes \(Resolve-WriteAccessPolicyAdvice -Policy \$WritePolicy\)'
    }

    It 'keeps the policy registry path in one place rather than beside every use of it' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        ([regex]::Matches($content, '(?m)^\$FixedDriveWritePolicyPath\s*=')).Count | Should -Be 1
        ([regex]::Matches($content, 'CurrentControlSet\\Policies\\Microsoft\\FVE')).Count | Should -Be 1
        ([regex]::Matches($content, '\$PolicyPath = \$script:FixedDriveWritePolicyPath')).Count | Should -Be 2
    }

    It 'states the setting in the plan when BitLocker is being skipped' {
        # Nothing exists yet at that point, so the run can still be declined over it.
        $content = Get-Content -Path $script:ScriptPath -Raw
        $skipAt = $content.IndexOf('* Skip BitLocker encryption')
        $adviceAt = $content.IndexOf('Resolve-WriteAccessPolicyAdvice -Policy $WritePolicy', $skipAt)
        $confirmAt = $content.IndexOf('Are you ready to proceed')
        $adviceAt | Should -BeGreaterThan $skipAt
        $confirmAt | Should -BeGreaterThan $adviceAt
    }

    It 'never tells the user to just try again' {
        Select-String -Path $script:ScriptPath -Pattern 'try again' | Should -BeNullOrEmpty
    }

    It 'catches a failed automatic unlock before it calls the BitLocker setup a success' {
        # A failure reaching the shared catch reads as the encryption collapsing, and offers a retry.
        $content = Get-Content -Path $script:ScriptPath -Raw
        $enableAt = $content.IndexOf('Enable-BitLockerAutoUnlock -MountPoint $devLetterColon -ErrorAction Stop')
        $catchAt = $content.IndexOf("`$autoUnlockOutcome = 'Failed'")
        $reportAt = $content.IndexOf('Resolve-BitLockerAutoUnlockReport -MountPoint $devLetterColon')
        $successAt = $content.IndexOf('$bitLockerSuccess = $true')
        $enableAt | Should -BeGreaterThan 0
        $catchAt | Should -BeGreaterThan $enableAt
        $reportAt | Should -BeGreaterThan $catchAt
        $successAt | Should -BeGreaterThan $reportAt
    }

    It 'reads the protection state off the volume before it reports on automatic unlocking' {
        # The auto-unlock lines are last on purpose, and they lean on that read rather than restating it.
        $content = Get-Content -Path $script:ScriptPath -Raw
        $finalStateAt = $content.IndexOf('$finalState = Get-BitLockerProtectionState -MountPoint $devLetterColon')
        $reportAt = $content.IndexOf('Resolve-BitLockerAutoUnlockReport -MountPoint $devLetterColon')
        $finalStateAt | Should -BeGreaterThan 0
        $reportAt | Should -BeGreaterThan $finalStateAt
    }

    It 'checks the target against the size Windows itself reports as the minimum, before it resizes' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $minBoundAt = $content.IndexOf('$minSize = $supportedSizes.SizeMin')
        $guardAt = $content.IndexOf('if ($targetSize -lt $minSize)')
        $resizeAt = $content.IndexOf('Resize-Partition -DiskNumber $diskNum')
        $minBoundAt | Should -BeGreaterThan 0
        $guardAt | Should -BeGreaterThan $minBoundAt
        $resizeAt | Should -BeGreaterThan $guardAt
    }

    It 'ends the run on a plain refusal, not a throw, when the target is below what Windows allows' {
        # The guard fires before Resize-Partition ever runs, so this must not fall into the catch
        # that would otherwise warn a shrink already happened.
        $content = Get-Content -Path $script:ScriptPath -Raw
        $guardAt = $content.IndexOf('if ($targetSize -lt $minSize)')
        $blockEnd = $content.IndexOf('Write-Host "Resizing Partition')
        $guardBlock = $content.Substring($guardAt, $blockEnd - $guardAt)
        $guardBlock | Should -Not -Match 'throw'
        $guardBlock | Should -Match 'exit 1'
    }

    It 'names both the target and the Windows minimum in that refusal with the rounding helpers' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $guardAt = $content.IndexOf('if ($targetSize -lt $minSize)')
        $blockEnd = $content.IndexOf('Write-Host "Resizing Partition')
        $guardBlock = $content.Substring($guardAt, $blockEnd - $guardAt)
        $guardBlock | Should -Match 'ConvertTo-FlooredGB -Bytes \$targetSize'
        $guardBlock | Should -Match 'ConvertTo-CeilingedGB -Bytes \$minSize'
    }

    It 'shows the resize target and its sizes with the rounding helpers, not a bare Math.Round' {
        # Scoped to the try block's resize section, not the earlier drive-selection prompt, which
        # has its own bare Round calls outside this change's reach.
        $content = Get-Content -Path $script:ScriptPath -Raw
        $blockStart = $content.IndexOf('# Use stored partition information to avoid redundant API calls')
        $blockEnd = $content.IndexOf('# Create Dev Drive from the freed space')
        $blockStart | Should -BeGreaterThan 0
        $blockEnd | Should -BeGreaterThan $blockStart
        $block = $content.Substring($blockStart, $blockEnd - $blockStart)
        $block | Should -Not -Match '\[math\]::Round\([^)]*/ 1GB, 2\)'
    }

    It 'records the shrunk drive letter right after the resize, before anything else can throw' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $resizeAt = $content.IndexOf('Resize-Partition -DiskNumber $diskNum -PartitionNumber $partitionInfo.PartitionNumber')
        $recordAt = $content.IndexOf('$ShrunkDriveLetter = $DriveLetter')
        $resizeAt | Should -BeGreaterThan 0
        $recordAt | Should -BeGreaterThan $resizeAt
    }

    It 'sets the shrunk-drive variable to a known value before the try block that might throw first' {
        Select-String -Path $script:ScriptPath -Pattern '^\$ShrunkDriveLetter = \$null' |
            Should -Not -BeNullOrEmpty
    }

    It 'forces the dismount when marking the drive trusted, so the designation lands during the run' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $content | Should -Match 'fsutil devdrv trust /f "\$devLetterColon"'
        $content | Should -Not -Match 'fsutil devdrv trust "\$devLetterColon"'
    }

    It 'offers the same force flag in the retry it prints when marking trust fails' {
        Select-String -Path $script:ScriptPath -Pattern 'Retry by hand with: fsutil devdrv trust /f' |
            Should -Not -BeNullOrEmpty
    }

    It 'gives the portability advice at the end of the run, whatever automatic mounting did' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $allDoneAt = $content.IndexOf('Write-Host "All done. Dev Drive')
        $adviceAt = $content.IndexOf('Resolve-VhdxPortabilityAdvice -VhdxPath $VhdxPath')
        $adviceAt | Should -BeGreaterThan $allDoneAt
        # The mount advice is skipped when Windows mounts the file itself; this one never is.
        $content.Substring($allDoneAt, $adviceAt - $allDoneAt) | Should -Match 'if \(\$mode -eq "Vhdx"\)'
    }

    It 'checks that the drive accepts writes after BitLocker and before deduplication' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $bitLockerAt = $content.IndexOf('Skipping BitLocker encryption as requested')
        $writeCheckAt = $content.IndexOf('$writeState = Get-VolumeWriteState')
        $dedupAt = $content.IndexOf('Enable-ReFSDedup -Volume')
        $bitLockerAt | Should -BeGreaterThan 0
        $writeCheckAt | Should -BeGreaterThan $bitLockerAt
        $dedupAt | Should -BeGreaterThan $writeCheckAt
    }

    It 'throws on a read-only drive rather than exiting, so the closing advice still runs' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $checkAt = $content.IndexOf('$writeState = Get-VolumeWriteState')
        $blockEnd = $content.IndexOf('# Enable Deduplication + Compression')
        $checkBlock = $content.Substring($checkAt, $blockEnd - $checkAt)
        $checkBlock | Should -Match 'throw'
        $checkBlock | Should -Not -Match 'exit 1'
    }
}

Describe 'Layout of the structures passed to virtdisk.dll' {
    # The C union inside CREATE_VIRTUAL_DISK_PARAMETERS is 8-byte aligned, so its arm starts at
    # offset 8. Declaring the Guid straight after Version puts it at 4 and every field still adds
    # up to 128 bytes, which is why checking the total size alone proves nothing.

    It '<Field> sits at offset <Offset> in CREATE_VIRTUAL_DISK_PARAMETERS' -TestCases @(
        @{ Field = 'UniqueId';                  Offset = 8 }
        @{ Field = 'MaximumSize';               Offset = 24 }
        @{ Field = 'BlockSizeInBytes';          Offset = 32 }
        @{ Field = 'SectorSizeInBytes';         Offset = 36 }
        @{ Field = 'PhysicalSectorSizeInBytes'; Offset = 40 }
        @{ Field = 'ParentPath';                Offset = 48 }
        @{ Field = 'SourcePath';                Offset = 56 }
        @{ Field = 'OpenFlags';                 Offset = 64 }
        @{ Field = 'ParentVirtualStorageType';  Offset = 68 }
        @{ Field = 'SourceVirtualStorageType';  Offset = 88 }
        @{ Field = 'ResiliencyGuid';            Offset = 108 }
    ) {
        $type = [type]'DevDriveInterop.CREATE_VIRTUAL_DISK_PARAMETERS'
        [System.Runtime.InteropServices.Marshal]::OffsetOf($type, $Field).ToInt32() | Should -Be $Offset
    }

    # The ATTACH union holds ULONGLONGs, so it is 8-aligned and Version1.Reserved starts at 8.
    # The OPEN union is 4-aligned throughout, so Version1.RWDepth stays at 4.
    It 'Reserved sits at offset 8 in ATTACH_VIRTUAL_DISK_PARAMETERS' {
        $type = [type]'DevDriveInterop.ATTACH_VIRTUAL_DISK_PARAMETERS'
        [System.Runtime.InteropServices.Marshal]::OffsetOf($type, 'Reserved').ToInt32() | Should -Be 8
    }

    It 'RWDepth sits at offset 4 in OPEN_VIRTUAL_DISK_PARAMETERS' {
        $type = [type]'DevDriveInterop.OPEN_VIRTUAL_DISK_PARAMETERS'
        [System.Runtime.InteropServices.Marshal]::OffsetOf($type, 'RWDepth').ToInt32() | Should -Be 4
    }

    # Sizes are the header's, covering every union arm, so the buffer is never shorter than the
    # struct virtdisk expects to read.
    It '<Type> is <Size> bytes' -TestCases @(
        @{ Type = 'DevDriveInterop.CREATE_VIRTUAL_DISK_PARAMETERS'; Size = 128 }
        @{ Type = 'DevDriveInterop.VIRTUAL_STORAGE_TYPE';           Size = 20 }
        @{ Type = 'DevDriveInterop.OPEN_VIRTUAL_DISK_PARAMETERS';   Size = 44 }
        @{ Type = 'DevDriveInterop.ATTACH_VIRTUAL_DISK_PARAMETERS'; Size = 24 }
    ) {
        [System.Runtime.InteropServices.Marshal]::SizeOf([activator]::CreateInstance([type]$Type)) | Should -Be $Size
    }

    It 'VendorId sits after DeviceId in VIRTUAL_STORAGE_TYPE' {
        $type = [type]'DevDriveInterop.VIRTUAL_STORAGE_TYPE'
        [System.Runtime.InteropServices.Marshal]::OffsetOf($type, 'DeviceId').ToInt32() | Should -Be 0
        [System.Runtime.InteropServices.Marshal]::OffsetOf($type, 'VendorId').ToInt32() | Should -Be 4
    }
}

Describe 'Get-VhdxStorageType' {
    It 'puts the VHDX device id and the Microsoft vendor id into the struct' {
        $storageType = Get-VhdxStorageType
        $storageType.DeviceId | Should -Be 3
        $storageType.VendorId | Should -Be ([guid]'EC984AEC-A0F9-47E9-901F-71415A66345B')
    }
}

Describe 'Constants taken from virtdisk.h' {
    It '<Name> is <Value>' -TestCases @(
        @{ Name = 'VIRTUAL_STORAGE_TYPE_DEVICE_VHDX';                   Value = 3 }
        @{ Name = 'CREATE_VIRTUAL_DISK_VERSION_2';                      Value = 2 }
        @{ Name = 'OPEN_VIRTUAL_DISK_VERSION_1';                        Value = 1 }
        @{ Name = 'OPEN_VIRTUAL_DISK_RWDEPTH_DEFAULT';                  Value = 1 }
        @{ Name = 'ATTACH_VIRTUAL_DISK_VERSION_1';                      Value = 1 }
        @{ Name = 'VIRTUAL_DISK_ACCESS_NONE';                           Value = 0 }
        @{ Name = 'VIRTUAL_DISK_ACCESS_ALL';                            Value = 0x003F0000 }
        @{ Name = 'CREATE_VIRTUAL_DISK_FLAG_NONE';                      Value = 0 }
        @{ Name = 'CREATE_VIRTUAL_DISK_FLAG_FULL_PHYSICAL_ALLOCATION';  Value = 1 }
        @{ Name = 'ATTACH_VIRTUAL_DISK_FLAG_PERMANENT_LIFETIME';        Value = 4 }
        @{ Name = 'ATTACH_VIRTUAL_DISK_FLAG_AT_BOOT';                   Value = 0x400 }
        @{ Name = 'ERROR_NOT_SUPPORTED';                                Value = 50 }
        @{ Name = 'ERROR_INVALID_PARAMETER';                            Value = 87 }
    ) {
        [DevDriveInterop.VirtDisk]::$Name | Should -Be $Value
    }

    It 'uses the Microsoft vendor identifier' {
        [DevDriveInterop.VirtDisk]::VIRTUAL_STORAGE_TYPE_VENDOR_MICROSOFT |
            Should -Be ([guid]'EC984AEC-A0F9-47E9-901F-71415A66345B')
    }

    It 'combines the two attach flags into 0x404' {
        $combined = [DevDriveInterop.VirtDisk]::ATTACH_VIRTUAL_DISK_FLAG_PERMANENT_LIFETIME -bor
                    [DevDriveInterop.VirtDisk]::ATTACH_VIRTUAL_DISK_FLAG_AT_BOOT
        $combined | Should -Be 0x404
    }
}

Describe 'Resolve-VhdxPathInput' {
    It 'rejects <Answer> as <Rejection>' -TestCases @(
        @{ Answer = '';                        Rejection = 'Empty' }
        @{ Answer = '   ';                     Rejection = 'Empty' }
        @{ Answer = 'devdrive.vhdx';           Rejection = 'NotALocalPath' }
        @{ Answer = 'D:devdrive.vhdx';         Rejection = 'NotALocalPath' }
        @{ Answer = '\\nas\share\d.vhdx';      Rejection = 'NotALocalPath' }
        @{ Answer = '/mnt/d/devdrive.vhdx';    Rejection = 'NotALocalPath' }
        @{ Answer = 'D:\devdrive.txt';         Rejection = 'WrongExtension' }
        @{ Answer = 'D:\devdrive';             Rejection = 'WrongExtension' }
        @{ Answer = 'D:\devdrive.vhd';         Rejection = 'WrongExtension' }
        @{ Answer = 'D:\devdrive.vhdx\';       Rejection = 'WrongExtension' }
    ) {
        (Resolve-VhdxPathInput -Answer $Answer).Rejection | Should -Be $Rejection
    }

    # Windows PowerShell throws from GetFullPath on these while PowerShell 7 passes them through,
    # so the answer must be the same rejection on either host, and never an exception.
    It 'rejects the character Windows forbids in <Answer>' -TestCases @(
        @{ Answer = 'D:\a|b.vhdx' }
        @{ Answer = 'D:\a<b.vhdx' }
        @{ Answer = 'D:\a>b.vhdx' }
        @{ Answer = 'D:\a"b.vhdx' }
        @{ Answer = 'D:\a?b.vhdx' }
        @{ Answer = 'D:\a*b.vhdx' }
        @{ Answer = 'D:\a:b.vhdx' }
    ) {
        { Resolve-VhdxPathInput -Answer $Answer } | Should -Not -Throw
        (Resolve-VhdxPathInput -Answer $Answer).Rejection | Should -Be 'InvalidPath'
    }

    It 'does not throw on a path longer than the classic limit' {
        { Resolve-VhdxPathInput -Answer ('D:\' + ('x' * 300) + '.vhdx') } | Should -Not -Throw
    }

    It 'accepts <Answer> and returns <Expected>' -TestCases @(
        @{ Answer = 'D:\devdrive.vhdx';        Expected = 'D:\devdrive.vhdx' }
        @{ Answer = 'd:\devdrive.vhdx';        Expected = 'D:\devdrive.vhdx' }
        @{ Answer = 'D:\dev\..\devdrive.vhdx'; Expected = 'D:\devdrive.vhdx' }
        @{ Answer = 'D:\dev\.\drive.VHDX';     Expected = 'D:\dev\drive.VHDX' }
        @{ Answer = 'D:/dev/drive.vhdx';       Expected = 'D:\dev\drive.vhdx' }
    ) {
        $verdict = Resolve-VhdxPathInput -Answer $Answer
        $verdict.Rejection | Should -BeNullOrEmpty
        $verdict.Path | Should -Be $Expected
    }

    It 'upper cases the drive letter so later messages read the same' {
        (Resolve-VhdxPathInput -Answer 'c:\x\y.vhdx').Path | Should -BeExactly 'C:\x\y.vhdx'
    }
}

Describe 'Resolve-DevDriveSizeInput' {
    It 'rejects <Answer> as <Rejection>' -TestCases @(
        @{ Answer = 'abc';   Rejection = 'NotANumber' }
        @{ Answer = '-5';    Rejection = 'NotANumber' }
        @{ Answer = '+60';   Rejection = 'NotANumber' }
        @{ Answer = ' 60 ';  Rejection = 'NotANumber' }
        @{ Answer = '1e3';   Rejection = 'NotANumber' }
        @{ Answer = '60,5';  Rejection = 'NotANumber' }
        @{ Answer = '';      Rejection = 'NotANumber' }
        @{ Answer = '0';     Rejection = 'BelowMinimum' }
        @{ Answer = '0.1';   Rejection = 'BelowMinimum' }
        @{ Answer = '49';    Rejection = 'BelowMinimum' }
        @{ Answer = '49.99'; Rejection = 'BelowMinimum' }
        @{ Answer = '201';   Rejection = 'AboveMaximum' }
        @{ Answer = '9999';  Rejection = 'AboveMaximum' }
        # Long enough to overflow the decimal cast, so it must be turned away before that.
        @{ Answer = '123456789012345678901234567890'; Rejection = 'NotANumber' }
    ) {
        (Resolve-DevDriveSizeInput -Answer $Answer -MinGB 50 -MaxGB 200).Rejection | Should -Be $Rejection
    }

    It 'does not throw on a number too large for the cast' {
        { Resolve-DevDriveSizeInput -Answer ('9' * 40) -MinGB 50 -MaxGB 200 } | Should -Not -Throw
    }

    It 'accepts <Answer> as <Expected> GB' -TestCases @(
        @{ Answer = '50';    Expected = 50 }
        @{ Answer = '50.5';  Expected = 50.5 }
        @{ Answer = '120';   Expected = 120 }
        @{ Answer = '200';   Expected = 200 }
        @{ Answer = '200.';  Expected = 200 }
    ) {
        $verdict = Resolve-DevDriveSizeInput -Answer $Answer -MinGB 50 -MaxGB 200
        $verdict.Rejection | Should -BeNullOrEmpty
        $verdict.SizeGB | Should -Be $Expected
    }

    It 'accepts a value that is both the minimum and the maximum' {
        $verdict = Resolve-DevDriveSizeInput -Answer '50' -MinGB 50 -MaxGB 50
        $verdict.Rejection | Should -BeNullOrEmpty
        $verdict.SizeGB | Should -Be 50
    }

    It 'honours a minimum other than the script default' {
        (Resolve-DevDriveSizeInput -Answer '60' -MinGB 100 -MaxGB 200).Rejection | Should -Be 'BelowMinimum'
    }

    Context 'when an empty answer means the maximum' {
        It 'returns the maximum for <Answer>' -TestCases @(
            @{ Answer = '' }
            @{ Answer = '   ' }
        ) {
            $verdict = Resolve-DevDriveSizeInput -Answer $Answer -MinGB 50 -MaxGB 200 -AllowEmpty
            $verdict.Rejection | Should -BeNullOrEmpty
            $verdict.SizeGB | Should -Be 200
        }

        It 'still rejects a non-number' {
            (Resolve-DevDriveSizeInput -Answer 'abc' -MinGB 50 -MaxGB 200 -AllowEmpty).Rejection |
                Should -Be 'NotANumber'
        }
    }

    Context 'when the maximum is only advisory' {
        It 'accepts a size above the maximum and flags it' {
            $verdict = Resolve-DevDriveSizeInput -Answer '500' -MinGB 50 -MaxGB 200 -MaxIsAdvisory
            $verdict.Rejection | Should -BeNullOrEmpty
            $verdict.SizeGB | Should -Be 500
            $verdict.ExceedsMax | Should -BeTrue
        }

        It 'does not flag a size within the maximum' {
            (Resolve-DevDriveSizeInput -Answer '120' -MinGB 50 -MaxGB 200 -MaxIsAdvisory).ExceedsMax |
                Should -BeFalse
        }

        It 'still enforces the minimum' {
            (Resolve-DevDriveSizeInput -Answer '10' -MinGB 50 -MaxGB 200 -MaxIsAdvisory).Rejection |
                Should -Be 'BelowMinimum'
        }
    }
}

Describe 'Resolve-DevDriveLabelInput' {
    It 'keeps the offered name when the answer is <Description>' -TestCases @(
        @{ Description = 'empty'; Answer = '' }
        @{ Description = 'spaces'; Answer = '   ' }
        @{ Description = 'a tab'; Answer = "`t" }
    ) {
        $verdict = Resolve-DevDriveLabelInput -Answer $Answer -Default 'DevDrive' -MaxLength 32
        $verdict.Rejection | Should -BeNullOrEmpty
        $verdict.Label | Should -Be 'DevDrive'
    }

    It 'takes a name the user typed' {
        $verdict = Resolve-DevDriveLabelInput -Answer 'Projects' -Default 'DevDrive' -MaxLength 32
        $verdict.Rejection | Should -BeNullOrEmpty
        $verdict.Label | Should -Be 'Projects'
    }

    It 'trims the answer rather than storing the spaces around it' {
        (Resolve-DevDriveLabelInput -Answer '  Work Drive  ' -Default 'DevDrive' -MaxLength 32).Label | Should -Be 'Work Drive'
    }

    It 'keeps the case the user typed' {
        (Resolve-DevDriveLabelInput -Answer 'devDRIVE' -Default 'DevDrive' -MaxLength 32).Label | Should -Be 'devDRIVE'
    }

    It 'takes a name of exactly the maximum length' {
        $name = 'a' * 32
        $verdict = Resolve-DevDriveLabelInput -Answer $name -Default 'DevDrive' -MaxLength 32
        $verdict.Rejection | Should -BeNullOrEmpty
        $verdict.Label | Should -Be $name
    }

    It 'refuses one character past the maximum' {
        # Caught here rather than by Format-Volume, which only runs once the partition exists.
        $verdict = Resolve-DevDriveLabelInput -Answer ('a' * 33) -Default 'DevDrive' -MaxLength 32
        $verdict.Rejection | Should -Be 'TooLong'
        $verdict.Label | Should -BeNullOrEmpty
    }

    It 'measures the length after trimming, not before' {
        $verdict = Resolve-DevDriveLabelInput -Answer ('  ' + ('a' * 32) + '  ') -Default 'DevDrive' -MaxLength 32
        $verdict.Rejection | Should -BeNullOrEmpty
    }

    It 'refuses <Character>, which Windows does not allow in a name' -TestCases @(
        @{ Character = '\' }
        @{ Character = '/' }
        @{ Character = ':' }
        @{ Character = '*' }
        @{ Character = '?' }
        @{ Character = '"' }
        @{ Character = '<' }
        @{ Character = '>' }
        @{ Character = '|' }
    ) {
        $verdict = Resolve-DevDriveLabelInput -Answer "Dev$($Character)Drive" -Default 'DevDrive' -MaxLength 32
        $verdict.Rejection | Should -Be 'BadCharacter'
        $verdict.RejectedCharacters | Should -Be $Character
    }

    It 'takes the forbidden list from Windows rather than from a list written here' {
        # Every character the platform rejects in a file name is rejected here, including any that
        # a hand-written list would have missed.
        foreach ($character in [System.IO.Path]::GetInvalidFileNameChars()) {
            (Resolve-DevDriveLabelInput -Answer "Dev$($character)Drive" -Default 'DevDrive' -MaxLength 32).Rejection |
                Should -Be 'BadCharacter'
        }
    }

    It 'names the characters it refused, once each' {
        $verdict = Resolve-DevDriveLabelInput -Answer 'a<b>c<d' -Default 'DevDrive' -MaxLength 32
        $verdict.RejectedCharacters | Should -Be '< >'
        $verdict.ControlCharacter | Should -BeFalse
    }

    It 'leaves a control character for the prompt to name rather than printing it' {
        # There is nothing to show on screen for one, and echoing it garbles the line.
        $verdict = Resolve-DevDriveLabelInput -Answer "Dev`0Drive" -Default 'DevDrive' -MaxLength 32
        $verdict.Rejection | Should -Be 'BadCharacter'
        $verdict.RejectedCharacters | Should -BeNullOrEmpty
        $verdict.ControlCharacter | Should -BeTrue
    }

    It 'reports both kinds at once when a name carries both' {
        # Otherwise removing the visible ones earns a second refusal naming something new.
        $verdict = Resolve-DevDriveLabelInput -Answer "Dev|`0Drive" -Default 'DevDrive' -MaxLength 32
        $verdict.RejectedCharacters | Should -Be '|'
        $verdict.ControlCharacter | Should -BeTrue
    }

    It 'allows the punctuation Windows does allow' {
        foreach ($name in 'Dev Drive', 'Dev-Drive', 'Dev_Drive', 'Dev.Drive', 'Dev(1)', "Dev's Drive") {
            (Resolve-DevDriveLabelInput -Answer $name -Default 'DevDrive' -MaxLength 32).Label | Should -Be $name
        }
    }
}

Describe 'Request-DevDriveLabel' {
    BeforeAll {
        Mock Write-Host { }
    }

    It 'takes the offered name on Enter' {
        Mock Read-Host { '' }
        Request-DevDriveLabel -Default 'DevDrive' -MaxLength 32 | Should -Be 'DevDrive'
    }

    It 'keeps asking until the answer is one the file system can take' {
        $script:answers = @('Dev:Drive', ('a' * 40), "bad`0name", 'Projects')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        Request-DevDriveLabel -Default 'DevDrive' -MaxLength 32 | Should -Be 'Projects'
        $script:index | Should -Be 4
    }

    It 'says which character it refused' {
        $script:answers = @('Dev|Drive', 'Projects')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        Request-DevDriveLabel -Default 'DevDrive' -MaxLength 32 | Out-Null
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'these characters: \|' }
    }

    It 'names a control character instead of echoing it' {
        $script:answers = @("Dev`0Drive", 'Projects')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        Request-DevDriveLabel -Default 'DevDrive' -MaxLength 32 | Out-Null
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'contains a control character' }
    }

    It 'names both kinds in one message when a name carries both' {
        $script:answers = @("Dev|`0Drive", 'Projects')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        Request-DevDriveLabel -Default 'DevDrive' -MaxLength 32 | Out-Null
        Should -Invoke Write-Host -ParameterFilter {
            $Object -match 'these characters: \|, and a control character'
        }
    }

    It 'says what the name is for before it asks for one' {
        Mock Read-Host { '' }
        Request-DevDriveLabel -Default 'DevDrive' -MaxLength 32 | Out-Null
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'what File Explorer shows beside its letter' }
    }

    It 'gives the real limit when the name is too long' {
        $script:answers = @(('a' * 40), 'Projects')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        Request-DevDriveLabel -Default 'DevDrive' -MaxLength 32 | Out-Null
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'at most 32 characters' }
    }

    It 'offers the name on the Enter key in the prompt itself' {
        Mock Read-Host { param($Prompt) $script:asked = $Prompt; return '' }
        Request-DevDriveLabel -Default 'MyDrive' -MaxLength 32 | Out-Null
        $script:asked | Should -Match 'press Enter for MyDrive'
    }
}

Describe 'Get-VolumeLabel' {
    It 'reports the name the volume answers with' {
        Mock Get-Volume { [PSCustomObject]@{ FileSystemLabel = 'Projects' } }
        Get-VolumeLabel -DriveLetter 'X' | Should -Be 'Projects'
    }

    It 'answers nothing rather than throwing when the volume cannot be found' {
        # Reading a property off an empty result throws under strict mode, which would abort the run
        # right after the drive was created - over a name.
        Mock Get-Volume { }
        { Get-VolumeLabel -DriveLetter 'X' } | Should -Not -Throw
        Get-VolumeLabel -DriveLetter 'X' | Should -BeNullOrEmpty
    }

    It 'answers nothing when the query itself fails' {
        Mock Get-Volume { throw 'The volume could not be read.' }
        Get-VolumeLabel -DriveLetter 'X' | Should -BeNullOrEmpty
    }

    It 'answers nothing when more than one volume comes back' {
        Mock Get-Volume { @([PSCustomObject]@{ FileSystemLabel = 'A' }, [PSCustomObject]@{ FileSystemLabel = 'B' }) }
        Get-VolumeLabel -DriveLetter 'X' | Should -BeNullOrEmpty
    }

    It 'passes an empty name through as empty rather than as no answer' {
        Mock Get-Volume { [PSCustomObject]@{ FileSystemLabel = '' } }
        Get-VolumeLabel -DriveLetter 'X' | Should -Be ''
    }
}

Describe 'Resolve-DevDriveLabelReport' {
    It 'confirms the name from the volume, not from the call that set it' {
        $report = Resolve-DevDriveLabelReport -DriveLetter 'X' -Requested 'Projects' -Actual 'Projects'
        $report.Matches | Should -BeTrue
        @($report.Lines).Count | Should -Be 1
        $report.Lines[0] | Should -Be 'Dev Drive created at X:, named Projects.'
    }

    It 'names what the volume said when it is not what was asked for' {
        $report = Resolve-DevDriveLabelReport -DriveLetter 'X' -Requested 'Projects' -Actual 'PROJECTS'
        $report.Matches | Should -BeFalse
        ($report.Lines -join "`n") | Should -Match 'reports itself as PROJECTS rather than Projects'
        ($report.Lines -join "`n") | Should -Match "Set-Volume -DriveLetter X -NewFileSystemLabel 'Projects'"
    }

    It 'says a volume with no name has none rather than inventing one' {
        $report = Resolve-DevDriveLabelReport -DriveLetter 'X' -Requested 'Projects' -Actual ''
        $report.Matches | Should -BeFalse
        ($report.Lines -join "`n") | Should -Match 'reports no name at all'
    }

    It 'says a volume that could not be read was not read, rather than that it has no name' {
        # Two different facts. Claiming the second is asserting a reading that never happened.
        $report = Resolve-DevDriveLabelReport -DriveLetter 'X' -Requested 'Projects' -Actual $null
        $report.Matches | Should -BeFalse
        ($report.Lines -join "`n") | Should -Match 'could not be read back'
        ($report.Lines -join "`n") | Should -Not -Match 'no name at all'
    }

    It 'offers the rename command only where there is a name to correct' {
        # Nothing is known to be wrong on a volume that did not answer, so nothing is prescribed.
        ((Resolve-DevDriveLabelReport -DriveLetter 'X' -Requested 'Projects' -Actual $null).Lines -join "`n") |
            Should -Not -Match 'Set-Volume'
    }

    It 'does not confuse two names that differ only in case' {
        (Resolve-DevDriveLabelReport -DriveLetter 'X' -Requested 'devdrive' -Actual 'DevDrive').Matches |
            Should -BeFalse
    }

    It 'hands back a rename command that parses, for <Description>' -TestCases @(
        @{ Description = 'an ordinary name'; Name = 'Projects' }
        @{ Description = 'a name with an apostrophe'; Name = "Bob's Drive" }
        @{ Description = 'a name that is nothing but apostrophes'; Name = "'''" }
        @{ Description = 'a name with spaces and brackets'; Name = 'Dev Drive (2)' }
    ) {
        # The line is printed to be copied and run, so it has to be valid PowerShell. A name may
        # legally carry an apostrophe, which ends the quoted string it is embedded in.
        $lines = (Resolve-DevDriveLabelReport -DriveLetter 'X' -Requested $Name -Actual 'Something else').Lines
        $command = ($lines | Where-Object { $_ -match '^Set the name with: ' }) -replace '^Set the name with: ', ''
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($command, [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }

    It 'passes the name itself to Set-Volume, not the doubling that quoted it' {
        # Doubled apostrophes are the escape, so PowerShell hands the cmdlet the original name back.
        $lines = (Resolve-DevDriveLabelReport -DriveLetter 'X' -Requested "Bob's Drive" -Actual 'DevDrive').Lines
        $command = ($lines | Where-Object { $_ -match '^Set the name with: ' }) -replace '^Set the name with: ', ''
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($command, [ref]$null, [ref]$null)
        $literal = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
            Where-Object { $_.StringConstantType -eq 'SingleQuoted' }
        $literal.Value | Should -Be "Bob's Drive"
    }

    It 'still says the name the user asked for in plain words, undoubled' {
        ((Resolve-DevDriveLabelReport -DriveLetter 'X' -Requested "Bob's Drive" -Actual 'DevDrive').Lines[0]) |
            Should -Match "rather than Bob's Drive\."
    }
}

Describe 'Get-VhdxAlignedSize' {
    It 'leaves <Bytes> alone when it is already a whole number of megabytes' -TestCases @(
        @{ Bytes = 50GB }
        @{ Bytes = 1MB }
        @{ Bytes = 0 }
    ) {
        Get-VhdxAlignedSize -SizeBytes $Bytes | Should -Be $Bytes
    }

    It 'trims a fractional gigabyte down to a megabyte boundary' {
        # A megabyte boundary is stricter than the sector multiple virtdisk requires, so trimming
        # to it satisfies the API for any sector size it might report.
        $raw = [uint64][math]::Round(50.1 * 1GB)
        $aligned = Get-VhdxAlignedSize -SizeBytes $raw
        $aligned % 1MB | Should -Be 0
        $aligned | Should -BeLessOrEqual $raw
        $raw - $aligned | Should -BeLessThan 1MB
    }

    It 'never rounds up past what the caller asked for' {
        Get-VhdxAlignedSize -SizeBytes ([uint64](1MB + 1)) | Should -Be 1MB
    }
}

Describe 'ConvertTo-FlooredGB' {
    It 'floors <Bytes> to <Expected> rather than rounding up' -TestCases @(
        @{ Bytes = 50GB;                Expected = 50 }
        @{ Bytes = [uint64](49.996 * 1GB); Expected = 49.99 }
        @{ Bytes = [uint64](0.999 * 1GB);  Expected = 0.99 }
        @{ Bytes = 0;                   Expected = 0 }
    ) {
        ConvertTo-FlooredGB -Bytes $Bytes | Should -Be $Expected
    }

    It 'never reports more gigabytes than there are bytes' {
        $bytes = [uint64](49.996 * 1GB)
        (ConvertTo-FlooredGB -Bytes $bytes) * 1GB | Should -BeLessOrEqual $bytes
    }

    It 'reports <Bytes> bytes as 0 rather than as a negative size' -TestCases @(
        @{ Bytes = -1 }
        @{ Bytes = -5GB }
        @{ Bytes = 1GB - 5GB }
    ) {
        ConvertTo-FlooredGB -Bytes $Bytes | Should -Be 0
    }

    It 'answers for a byte count far above the Int32 range' {
        # 3.5 TB of free space less the shrink head-room: the size of a real disk, not of an Int32.
        ConvertTo-FlooredGB -Bytes (3.5TB - 5GB) | Should -Be 3579
    }
}

Describe 'ConvertTo-CeilingedGB' {
    It 'ceilings <Bytes> to <Expected> rather than rounding down' -TestCases @(
        @{ Bytes = 50GB;                   Expected = 50 }
        @{ Bytes = [uint64](49.001 * 1GB); Expected = 49.01 }
        @{ Bytes = [uint64](0.001 * 1GB);  Expected = 0.01 }
        @{ Bytes = 0;                      Expected = 0 }
    ) {
        ConvertTo-CeilingedGB -Bytes $Bytes | Should -Be $Expected
    }

    It 'never reports fewer gigabytes than there are bytes' {
        $bytes = [uint64](49.001 * 1GB)
        (ConvertTo-CeilingedGB -Bytes $bytes) * 1GB | Should -BeGreaterOrEqual $bytes
    }

    It 'reports <Bytes> bytes as 0 rather than as a negative size' -TestCases @(
        @{ Bytes = -1 }
        @{ Bytes = -5GB }
        @{ Bytes = 1GB - 5GB }
    ) {
        ConvertTo-CeilingedGB -Bytes $Bytes | Should -Be 0
    }
}

Describe 'Get-Win32ErrorText' {
    It 'includes the numeric code so it can be searched for' {
        Get-Win32ErrorText -Code 87 | Should -Match '\(error 87\)'
    }

    It 'includes the message Windows gives for the code' {
        Get-Win32ErrorText -Code 5 | Should -Match 'Access is denied'
    }
}

Describe 'Request-BitLockerChoice' {
    BeforeAll {
        Mock Write-Host { }
    }

    It 'returns <Expected> for answer <Answer>' -TestCases @(
        @{ Answer = '1'; Expected = $true }
        @{ Answer = '2'; Expected = $false }
    ) {
        Mock Read-Host { $Answer }
        Request-BitLockerChoice | Should -Be $Expected
    }

    It 'keeps asking until the answer is one of the two' {
        $script:answers = @('yes', '3', '2')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        Request-BitLockerChoice | Should -BeFalse
        $script:index | Should -Be 3
    }

    It 'prints what it was given about this machine before the menu' {
        # A machine where encryption is mandatory has to say so before the answer, not after.
        Mock Read-Host { '1' }
        Request-BitLockerChoice -Notes @('This machine denies write access to unprotected fixed drives.') | Out-Null
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'denies write access' }
    }

    It 'prints nothing extra when there is nothing to say' {
        Mock Read-Host { '1' }
        Request-BitLockerChoice | Out-Null
        Should -Not -Invoke Write-Host -ParameterFilter { $Object -match 'denies write access' }
    }
}

Describe 'Get-FixedDriveWritePolicy' {
    BeforeAll {
        $script:TestKeyRoot = 'HKCU:\Software\DevDriveTests'
        $script:FakeKey = "$script:TestKeyRoot\FVE"
    }

    AfterAll {
        # The whole branch, not just the leaf, so the suite leaves the user's hive as it found it.
        if (Test-Path -Path $script:TestKeyRoot) { Remove-Item -Path $script:TestKeyRoot -Recurse -Force }
    }

    BeforeEach {
        if (Test-Path -Path $script:FakeKey) { Remove-Item -Path $script:FakeKey -Recurse -Force }
    }

    It 'reads the setting as on when the value is 1' {
        New-Item -Path $script:FakeKey -Force | Out-Null
        New-ItemProperty -Path $script:FakeKey -Name 'FDVDenyWriteAccess' -Value 1 -PropertyType DWord -Force | Out-Null
        Get-FixedDriveWritePolicy -Path $script:FakeKey | Should -Be 'Deny'
    }

    It 'reads the setting as off when the value is 0' {
        New-Item -Path $script:FakeKey -Force | Out-Null
        New-ItemProperty -Path $script:FakeKey -Name 'FDVDenyWriteAccess' -Value 0 -PropertyType DWord -Force | Out-Null
        Get-FixedDriveWritePolicy -Path $script:FakeKey | Should -Be 'Allow'
    }

    It 'treats a key without the value as the setting not being set' {
        # The ordinary case on an unmanaged machine, and it must not read as "could not be read".
        New-Item -Path $script:FakeKey -Force | Out-Null
        Get-FixedDriveWritePolicy -Path $script:FakeKey | Should -Be 'Allow'
    }

    It 'treats a missing key the same way' {
        Get-FixedDriveWritePolicy -Path "$script:TestKeyRoot\NoSuchKey" | Should -Be 'Allow'
    }

    It 'answers Unknown for a value of a type it cannot read, rather than reading it as off' {
        # A string where a number belongs is an answer this cannot understand, not an absent setting.
        New-Item -Path $script:FakeKey -Force | Out-Null
        New-ItemProperty -Path $script:FakeKey -Name 'FDVDenyWriteAccess' -Value 'yes' -PropertyType String -Force | Out-Null
        Get-FixedDriveWritePolicy -Path $script:FakeKey | Should -Be 'Unknown'
    }

    It 'reads a number that is neither 0 nor 1 as the setting not denying writes' {
        New-Item -Path $script:FakeKey -Force | Out-Null
        New-ItemProperty -Path $script:FakeKey -Name 'FDVDenyWriteAccess' -Value 2 -PropertyType DWord -Force | Out-Null
        Get-FixedDriveWritePolicy -Path $script:FakeKey | Should -Be 'Allow'
    }

    It 'answers Unknown when the read itself fails' {
        Mock Get-ItemProperty { throw 'Requested registry access is not allowed.' }
        New-Item -Path $script:FakeKey -Force | Out-Null
        Get-FixedDriveWritePolicy -Path $script:FakeKey | Should -Be 'Unknown'
    }

    It 'answers Unknown when even the existence check fails, not "not set"' {
        # A key that is there but unreadable must never be reported as one that is not there.
        Mock Test-Path { throw 'Requested registry access is not allowed.' }
        Get-FixedDriveWritePolicy -Path $script:FakeKey | Should -Be 'Unknown'
    }
}

Describe 'Resolve-WriteAccessPolicyAdvice' {
    It 'says nothing at all on a machine that allows the writes' {
        @(Resolve-WriteAccessPolicyAdvice -Policy 'Allow' -PolicyPath 'HKLM:\X').Count | Should -Be 0
        @(Resolve-WriteAccessPolicyAdvice -Policy 'Allow' -PolicyPath 'HKLM:\X' -Skipping).Count | Should -Be 0
    }

    It 'states the consequence as a fact once the answer to skip is known' {
        $lines = (Resolve-WriteAccessPolicyAdvice -Policy 'Deny' -PolicyPath 'HKLM:\X' -Skipping) -join "`n"
        $lines | Should -Match 'FDVDenyWriteAccess is 1'
        $lines | Should -Match 'this Dev Drive will mount read-only'
        $lines | Should -Match 'stop at the write check'
    }

    It 'states it as a condition while the answer is still open' {
        # Printed before the menu, where nobody has decided to skip anything yet.
        $lines = (Resolve-WriteAccessPolicyAdvice -Policy 'Deny' -PolicyPath 'HKLM:\X') -join "`n"
        $lines | Should -Match 'would mount read-only'
        $lines | Should -Not -Match 'stop at the write check'
        $lines | Should -Not -Match 'will mount read-only'
    }

    It 'raises an unreadable setting either way, and says where to look' {
        foreach ($lines in (Resolve-WriteAccessPolicyAdvice -Policy 'Unknown' -PolicyPath 'HKLM:\Somewhere') -join "`n",
            (Resolve-WriteAccessPolicyAdvice -Policy 'Unknown' -PolicyPath 'HKLM:\Somewhere' -Skipping) -join "`n") {
            $lines | Should -Match 'could not be read'
            $lines | Should -Match "Get-ItemProperty 'HKLM:\\Somewhere' -Name FDVDenyWriteAccess"
        }
    }

    It 'refuses a policy that is not one of the three' {
        { Resolve-WriteAccessPolicyAdvice -Policy 'Maybe' -PolicyPath 'HKLM:\X' } | Should -Throw
    }
}

Describe 'Resolve-BitLockerSetupPlan' {
    It 'asks for a password only in virtual hard disk mode' -TestCases @(
        @{ Vhdx = $true;  Expected = $true }
        @{ Vhdx = $false; Expected = $false }
    ) {
        (Resolve-BitLockerSetupPlan -VhdxMode:$Vhdx).UsePasswordProtector | Should -Be $Expected
    }

    It 'warns about the read-only spell and Windows'' own prompt where the setting is on' {
        # The reporter answered that prompt, got "BitLocker encryption already enabled", and started over.
        $notes = (Resolve-BitLockerSetupPlan -WritePolicy 'Deny').Notes -join "`n"
        $notes | Should -Match 'read-only'
        $notes | Should -Match 'Windows may put up its own prompt'
        $notes | Should -Match 'Leave it alone'
    }

    It 'says neither where the setting is off' {
        $notes = (Resolve-BitLockerSetupPlan).Notes -join "`n"
        $notes | Should -Not -Match 'read-only'
        $notes | Should -Not -Match 'own prompt'
    }

    It 'puts that warning first, before the protector notes' {
        # It is about what happens during the run; the rest is about what the drive ends up with.
        $notes = @((Resolve-BitLockerSetupPlan -WritePolicy 'Deny').Notes)
        $notes[0] | Should -Match 'read-only'
    }

    It 'adds the domain account protector only on a domain-joined machine' -TestCases @(
        @{ Joined = $true;  Expected = $true }
        @{ Joined = $false; Expected = $false }
    ) {
        (Resolve-BitLockerSetupPlan -DomainJoined:$Joined).UseAdAccountProtector | Should -Be $Expected
    }

    It 'turns on automatic unlocking only when the operating system drive is protected' -TestCases @(
        @{ Protected = $true;  Expected = $true }
        @{ Protected = $false; Expected = $false }
    ) {
        (Resolve-BitLockerSetupPlan -OsDriveProtected:$Protected).UseAutoUnlock | Should -Be $Expected
    }

    It 'says why a machine outside a domain gets no domain protector, and that the drive is still safe' {
        $notes = (Resolve-BitLockerSetupPlan -DomainJoined:$false).Notes -join "`n"
        $notes | Should -Match 'not joined to an Active Directory domain'
        $notes | Should -Match 'still encrypted and still protected by its recovery key'
    }

    It 'says a domain protector is coming when the machine is joined' {
        $notes = (Resolve-BitLockerSetupPlan -DomainJoined:$true).Notes -join "`n"
        $notes | Should -Match 'joined to an Active Directory domain'
        $notes | Should -Not -Match 'not joined to an Active Directory domain'
    }

    It 'backs the key up to Azure AD only on a device joined to Entra ID' -TestCases @(
        @{ Entra = $true;  Expected = $true }
        @{ Entra = $false; Expected = $false }
    ) {
        (Resolve-BitLockerSetupPlan -EntraJoined:$Entra).UseAadBackup | Should -Be $Expected
    }

    It 'says the key goes to Azure AD when the device is joined to Entra ID' {
        $notes = (Resolve-BitLockerSetupPlan -EntraJoined:$true).Notes -join "`n"
        $notes | Should -Match 'joined to Entra ID'
        $notes | Should -Not -Match 'not joined to Entra ID'
    }

    It 'warns that nothing else holds the key when the device is outside Entra ID' {
        $notes = (Resolve-BitLockerSetupPlan -EntraJoined:$false).Notes -join "`n"
        $notes | Should -Match 'not joined to Entra ID'
        $notes | Should -Match 'nowhere but on the volume itself and on the paper'
    }

    It 'keeps the Azure AD lines as their own list so the run can repeat them where it skips the backup' -TestCases @(
        @{ Entra = $true;  Expected = 1 }
        @{ Entra = $false; Expected = 2 }
    ) {
        $plan = Resolve-BitLockerSetupPlan -EntraJoined:$Entra
        @($plan.AadNotes).Count | Should -Be $Expected
        foreach ($note in $plan.AadNotes) {
            $plan.Notes | Should -Contain $note
        }
    }

    It 'names the operating system drive as the reason automatic unlocking is skipped' {
        $notes = (Resolve-BitLockerSetupPlan -OsDriveProtected:$false).Notes -join "`n"
        $notes | Should -Match 'operating system drive'
        $notes | Should -Match 'unlocked by hand'
    }

    It 'says automatic unlocking is available when the operating system drive is protected' {
        $notes = (Resolve-BitLockerSetupPlan -OsDriveProtected:$true).Notes -join "`n"
        $notes | Should -Match 'unlock automatically'
        $notes | Should -Not -Match 'unlocked by hand'
    }

    It 'warns about the password prompt in virtual hard disk mode' {
        (Resolve-BitLockerSetupPlan -VhdxMode:$true).Notes -join "`n" | Should -Match 'password will be asked for'
    }

    It 'says no password is coming for a partition' {
        (Resolve-BitLockerSetupPlan -VhdxMode:$false).Notes -join "`n" | Should -Match 'No BitLocker password'
    }

    It 'explains every one of the four decisions whatever the machine looks like' -TestCases @(
        @{ Joined = $true;  Entra = $true;  Vhdx = $true;  Protected = $true }
        @{ Joined = $false; Entra = $false; Vhdx = $false; Protected = $false }
        @{ Joined = $true;  Entra = $false; Vhdx = $true;  Protected = $false }
        @{ Joined = $false; Entra = $true;  Vhdx = $false; Protected = $true }
    ) {
        $plan = Resolve-BitLockerSetupPlan -DomainJoined:$Joined -EntraJoined:$Entra `
            -VhdxMode:$Vhdx -OsDriveProtected:$Protected
        foreach ($decision in @('password', 'Active Directory domain', 'Entra ID', 'operating system drive|unlock automatically')) {
            @($plan.Notes | Where-Object { $_ -match $decision }).Count | Should -BeGreaterThan 0 -Because "the $decision decision needs a note"
        }
    }
}

Describe 'Resolve-BitLockerFailure' {
    It 'recognises <Description> as a rejected password' -TestCases @(
        @{ Description = 'a complexity complaint'
           Message = 'The password does not meet the password complexity requirements.' }
        @{ Description = 'a requirements complaint'; Message = 'Password requirements not met.' }
    ) {
        (Resolve-BitLockerFailure -Message $Message -RetryCount 1 -MaxRetries 10 -PasswordAsked).Kind |
            Should -Be 'Password'
    }

    It 'never blames the password on a run that never asks for one' {
        # In partition mode nothing is prompted, so a password retry would repeat the same call
        # ten times with nobody to change anything.
        $verdict = Resolve-BitLockerFailure -RetryCount 1 -MaxRetries 10 `
            -Message 'The password does not meet the password complexity requirements.'
        $verdict.Kind | Should -Be 'Other'
    }

    It 'counts the attempts left before giving up' {
        $verdict = Resolve-BitLockerFailure -Message 'password complexity' -RetryCount 3 -MaxRetries 10 -PasswordAsked
        $verdict.Exhausted | Should -BeFalse
        $verdict.CanRetry | Should -BeTrue
        ($verdict.Lines -join "`n") | Should -Match 'Attempt 3 of 10'
    }

    It 'gives up once the attempts are used up' {
        $verdict = Resolve-BitLockerFailure -Message 'password complexity' -RetryCount 10 -MaxRetries 10 -PasswordAsked
        $verdict.Exhausted | Should -BeTrue
        $verdict.CanRetry | Should -BeFalse
        ($verdict.Lines -join "`n") | Should -Match 'Maximum retry attempts reached'
    }

    It 'treats anything else as a failure the user has to decide about' {
        # 0x80090034 says nothing about a password, so it must not be sorted as one.
        $verdict = Resolve-BitLockerFailure -Message 'Encryption failed. (0x80090034)' `
            -RetryCount 1 -MaxRetries 10 -PasswordAsked
        $verdict.Kind | Should -Be 'Other'
        $verdict.Exhausted | Should -BeFalse
        $verdict.CanRetry | Should -BeTrue
    }

    It 'counts the attempts for a failure that is not about a password either' {
        $verdict = Resolve-BitLockerFailure -Message 'Encryption failed. (0x80090034)' -RetryCount 10 -MaxRetries 10
        $verdict.Kind | Should -Be 'Other'
        $verdict.Exhausted | Should -BeTrue
        $verdict.CanRetry | Should -BeFalse
    }

    It 'refuses a retry that would only repeat itself' {
        $verdict = Resolve-BitLockerFailure -Message 'carries 2 BitLocker recovery keys' `
            -RetryCount 1 -MaxRetries 10 -Unretryable
        $verdict.Exhausted | Should -BeFalse
        $verdict.CanRetry | Should -BeFalse
    }

    It 'refuses a password retry too once the error cannot change' {
        $verdict = Resolve-BitLockerFailure -Message 'password complexity' -RetryCount 1 -MaxRetries 10 `
            -Unretryable -PasswordAsked
        $verdict.Kind | Should -Be 'Password'
        $verdict.CanRetry | Should -BeFalse
        ($verdict.Lines -join "`n") | Should -Not -Match 'Attempt 1 of 10'
    }

    It 'repeats what Windows said and says the drive works without BitLocker while it is unencrypted' {
        $lines = (Resolve-BitLockerFailure -Message 'Encryption failed. (0x80090034)' `
            -RetryCount 1 -MaxRetries 10 -VolumeState 'Clear').Lines -join "`n"
        $lines | Should -Match '0x80090034'
        $lines | Should -Match 'works without BitLocker'
    }

    It 'does not claim the drive works without BitLocker once encryption has started' {
        $lines = (Resolve-BitLockerFailure -Message 'Encryption failed. (0x80090034)' `
            -RetryCount 1 -MaxRetries 10 -VolumeState 'Encrypted').Lines -join "`n"
        $lines | Should -Match 'already started encrypting'
        $lines | Should -Not -Match 'works without BitLocker'
    }

    It 'says the state could not be read rather than calling the volume unencrypted' {
        $lines = (Resolve-BitLockerFailure -Message 'Encryption failed. (0x80090034)' `
            -RetryCount 1 -MaxRetries 10 -VolumeState 'Unknown').Lines -join "`n"
        $lines | Should -Match 'could not be read'
        $lines | Should -Match 'Get-BitLockerVolume'
        $lines | Should -Not -Match 'works without BitLocker'
    }

    It 'assumes nothing about the volume when no state is passed' {
        $lines = (Resolve-BitLockerFailure -Message 'Encryption failed.' -RetryCount 1 -MaxRetries 10).Lines -join "`n"
        $lines | Should -Match 'could not be read'
    }

    It 'does not throw on an empty message' {
        { Resolve-BitLockerFailure -Message '' -RetryCount 1 -MaxRetries 10 } | Should -Not -Throw
        (Resolve-BitLockerFailure -Message '' -RetryCount 1 -MaxRetries 10).Kind | Should -Be 'Other'
    }

    It 'refuses a retry when group policy is what said no' {
        # 0x8031005E is "group policy will not allow this", and a second attempt meets it again.
        $verdict = Resolve-BitLockerFailure -Message 'Die Gruppenrichtlinien lassen das nicht zu. (0x8031005E)' `
            -RetryCount 1 -MaxRetries 10
        $verdict.Kind | Should -Be 'Other'
        $verdict.Exhausted | Should -BeFalse
        $verdict.CanRetry | Should -BeFalse
        ($verdict.Lines -join "`n") | Should -Match 'same refusal'
    }

    It 'recognises the policy refusal by its code, not by an English sentence' {
        # BitLocker takes its messages from a resource, so the words around the code are localized.
        (Resolve-BitLockerFailure -Message 'anything at all (0x8031005e)' -RetryCount 1 -MaxRetries 10).CanRetry |
            Should -BeFalse
    }

    It 'sorts a policy refusal as one even on a run that asks for a password' {
        # The password branch answers first, so a refusal wording that also mentions a password
        # would otherwise be retried into the same refusal.
        $verdict = Resolve-BitLockerFailure -Message 'password complexity (0x8031005E)' `
            -RetryCount 1 -MaxRetries 10 -PasswordAsked
        $verdict.Kind | Should -Be 'Other'
        $verdict.CanRetry | Should -BeFalse
    }

    It 'still counts the attempts when policy refused on the last one' {
        $verdict = Resolve-BitLockerFailure -Message 'refused (0x8031005E)' -RetryCount 10 -MaxRetries 10
        $verdict.Exhausted | Should -BeTrue
        $verdict.CanRetry | Should -BeFalse
    }

    It 'still allows a retry for a failure policy had nothing to do with' {
        $verdict = Resolve-BitLockerFailure -Message 'Encryption failed. (0x80090034)' -RetryCount 1 -MaxRetries 10
        $verdict.CanRetry | Should -BeTrue
        ($verdict.Lines -join "`n") | Should -Not -Match 'same refusal'
    }
}

Describe 'Resolve-BitLockerRecoveryProtector' {
    It 'reports no recovery key on a volume with <Description>' -TestCases @(
        @{ Description = 'no protectors at all'; Protectors = @() }
        @{ Description = 'only a password protector'
           Protectors = @([PSCustomObject]@{ KeyProtectorType = 'Password'; KeyProtectorId = '{PWD}' }) }
    ) {
        $verdict = Resolve-BitLockerRecoveryProtector -KeyProtector $Protectors -MountPoint 'X:'
        $verdict.Rejection | Should -Be 'None'
        $verdict.ProtectorId | Should -BeNullOrEmpty
        $verdict.Message | Should -Match 'X: carries no BitLocker recovery key'
    }

    It 'does not throw when the volume reports no protectors at all' {
        { Resolve-BitLockerRecoveryProtector -KeyProtector $null -MountPoint 'X:' } | Should -Not -Throw
        (Resolve-BitLockerRecoveryProtector -KeyProtector $null -MountPoint 'X:').Rejection | Should -Be 'None'
    }

    It 'returns the one recovery key it finds' {
        $protectors = @(
            New-Protector -Type 'Password' -Id '{PWD}'
            New-Protector -Type 'RecoveryPassword' -Id '{REC}'
            New-Protector -Type 'AdAccountOrGroup' -Id '{SID}'
        )
        $verdict = Resolve-BitLockerRecoveryProtector -KeyProtector $protectors -MountPoint 'X:'
        $verdict.Rejection | Should -BeNullOrEmpty
        $verdict.ProtectorId | Should -Be '{REC}'
    }

    It 'returns that id as one value, never as an array' {
        # An array here is the defect itself: BackupToAAD-BitLockerKeyProtector takes a single string.
        $protectors = @((New-Protector -Type 'RecoveryPassword' -Id '{REC}'))
        (Resolve-BitLockerRecoveryProtector -KeyProtector $protectors -MountPoint 'X:').ProtectorId |
            Should -BeOfType [string]
    }

    It 'refuses to choose between two recovery keys' {
        $protectors = @(
            New-Protector -Type 'RecoveryPassword' -Id '{FIRST}'
            New-Protector -Type 'RecoveryPassword' -Id '{SECOND}'
        )
        $verdict = Resolve-BitLockerRecoveryProtector -KeyProtector $protectors -MountPoint 'X:'
        $verdict.Rejection | Should -Be 'Multiple'
        $verdict.ProtectorId | Should -BeNullOrEmpty
        $verdict.ProtectorIds | Should -HaveCount 2
    }

    It 'names both keys and a way out in the refusal' {
        $protectors = @(
            New-Protector -Type 'RecoveryPassword' -Id '{FIRST}'
            New-Protector -Type 'RecoveryPassword' -Id '{SECOND}'
        )
        $message = (Resolve-BitLockerRecoveryProtector -KeyProtector $protectors -MountPoint 'X:').Message
        $message | Should -Match '\{FIRST\}'
        $message | Should -Match '\{SECOND\}'
        $message | Should -Match 'Remove-BitLockerKeyProtector'
    }
}

Describe 'Resolve-BitLockerProtectorPlan' {
    It 'adds both protectors to a freshly formatted volume' {
        $plan = Resolve-BitLockerProtectorPlan -KeyProtector @() -MountPoint 'X:'
        $plan.Rejection | Should -BeNullOrEmpty
        $plan.TypesToAdd | Should -Contain 'Password'
        $plan.TypesToAdd | Should -Contain 'RecoveryPassword'
        $plan.RecoveryProtectorId | Should -BeNullOrEmpty
    }

    It 'keeps a recovery key it did not create, and backs that one up' {
        $plan = Resolve-BitLockerProtectorPlan -MountPoint 'X:' `
            -KeyProtector @((New-Protector -Type 'RecoveryPassword' -Id '{REC}'))
        $plan.TypesToAdd | Should -Not -Contain 'RecoveryPassword'
        $plan.RecoveryProtectorId | Should -Be '{REC}'
        $plan.TypesToAdd | Should -Contain 'Password'
    }

    It 'does not add a second password protector' {
        $plan = Resolve-BitLockerProtectorPlan -MountPoint 'X:' `
            -KeyProtector @((New-Protector -Type 'Password' -Id '{PWD}'))
        $plan.TypesToAdd | Should -Not -Contain 'Password'
        $plan.TypesToAdd | Should -Contain 'RecoveryPassword'
    }

    It 'adds nothing to a volume that already carries both' {
        $protectors = @(
            New-Protector -Type 'Password' -Id '{PWD}'
            New-Protector -Type 'RecoveryPassword' -Id '{REC}'
        )
        $plan = Resolve-BitLockerProtectorPlan -KeyProtector $protectors -MountPoint 'X:'
        $plan.TypesToAdd | Should -Not -Contain 'Password'
        $plan.TypesToAdd | Should -Not -Contain 'RecoveryPassword'
    }

    It 'ignores protector types this script never adds' {
        $protectors = @(
            New-Protector -Type 'Tpm' -Id '{TPM}'
            New-Protector -Type 'AdAccountOrGroup' -Id '{SID}'
        )
        $plan = Resolve-BitLockerProtectorPlan -KeyProtector $protectors -MountPoint 'X:'
        $plan.TypesToAdd | Should -Contain 'Password'
        $plan.TypesToAdd | Should -Contain 'RecoveryPassword'
    }

    It 'stops the run when the volume already carries two recovery keys' {
        $protectors = @(
            New-Protector -Type 'RecoveryPassword' -Id '{FIRST}'
            New-Protector -Type 'RecoveryPassword' -Id '{SECOND}'
        )
        $plan = Resolve-BitLockerProtectorPlan -KeyProtector $protectors -MountPoint 'X:'
        $plan.Rejection | Should -Be 'Multiple'
        $plan.Message | Should -Match 'will not guess'
        $plan.TypesToAdd | Should -Not -Contain 'RecoveryPassword'
    }
}

Describe 'Resolve-AutomationBanner' {
    It 'returns the agreed warning about what the script assumes of the person running it' {
        $lines = Resolve-AutomationBanner
        $lines | Should -Be @(
            "This script AUTOMATES work you are expected to be able to do by hand."
            ""
            "It assumes you understand what it touches - partitions, ReFS, BitLocker and scheduled"
            "tasks - and that you can carry out every step it takes, and reverse it, yourself. It"
            "does not resume after a failure, and it undoes nothing for you."
            ""
            "This is not a tool for learning any of that."
        )
    }

    It 'returns plain lines rather than an object to unwrap' {
        Resolve-AutomationBanner | Should -BeOfType [string]
    }
}

Describe 'Resolve-EntraJoinState' {
    It 'reads the joined state out of the line dsregcmd prints' {
        $status = @('', '+----------------------------------+', 'AzureAdJoined : YES', 'EnterpriseJoined : NO', 'DomainJoined : NO')
        Resolve-EntraJoinState -StatusLines $status | Should -BeTrue
    }

    It 'accepts the indentation dsregcmd uses' {
        Resolve-EntraJoinState -StatusLines @('             AzureAdJoined :  YES  ') | Should -BeTrue
    }

    It 'says no for <Description>' -TestCases @(
        @{ Description = 'a device that is not joined'; Lines = @('AzureAdJoined : NO') }
        @{ Description = 'output without the line at all'; Lines = @('DomainJoined : NO') }
        @{ Description = 'no output, as when the tool is missing'; Lines = @() }
        @{ Description = 'nothing at all'; Lines = $null }
        @{ Description = 'a line that only mentions the word'; Lines = @('AzureAdJoined is not YES here') }
    ) {
        Resolve-EntraJoinState -StatusLines $Lines | Should -BeFalse
    }
}

Describe 'Resolve-BitLockerVolumeState' {
    It 'calls a protected volume covered' {
        $state = Resolve-BitLockerVolumeState -ProtectionStatus 'On' -VolumeStatus 'FullyEncrypted'
        $state.Known | Should -BeTrue
        $state.Protected | Should -BeTrue
        $state.Covered | Should -BeTrue
        $state.Label | Should -Be 'Encrypted'
    }

    It 'counts <VolumeStatus> as covered even while protection reports off' -TestCases @(
        @{ VolumeStatus = 'EncryptionInProgress' }
        @{ VolumeStatus = 'EncryptionSuspended' }
        @{ VolumeStatus = 'DecryptionInProgress' }
        @{ VolumeStatus = 'DecryptionSuspended' }
    ) {
        # Every one of these leaves ciphertext on the volume, whatever the direction of travel.
        $state = Resolve-BitLockerVolumeState -ProtectionStatus 'Off' -VolumeStatus $VolumeStatus
        $state.Protected | Should -BeFalse
        $state.HasCiphertext | Should -BeTrue
        $state.Covered | Should -BeTrue
        $state.Label | Should -Be 'Encrypted'
    }

    It 'calls a decrypted volume neither protected nor covered' {
        $state = Resolve-BitLockerVolumeState -ProtectionStatus 'Off' -VolumeStatus 'FullyDecrypted'
        $state.Protected | Should -BeFalse
        $state.HasCiphertext | Should -BeFalse
        $state.Covered | Should -BeFalse
        $state.Label | Should -Be 'Clear'
    }

    It 'treats a volume that reported nothing as unprotected' {
        $state = Resolve-BitLockerVolumeState -ProtectionStatus '' -VolumeStatus ''
        $state.Covered | Should -BeFalse
        $state.Label | Should -Be 'Clear'
    }

    It 'has its own answer for a volume that could not be read' {
        $state = Resolve-BitLockerVolumeState -Unknown
        $state.Known | Should -BeFalse
        $state.Covered | Should -BeFalse
        $state.Label | Should -Be 'Unknown'
    }
}

Describe 'Get-BitLockerProtectionState' {
    It 'reports what the volume answers' {
        Mock Get-BitLockerVolume { [PSCustomObject]@{ ProtectionStatus = 'On'; VolumeStatus = 'FullyEncrypted' } }
        $state = Get-BitLockerProtectionState -MountPoint 'X:'
        $state.Known | Should -BeTrue
        $state.Covered | Should -BeTrue
        $state.Label | Should -Be 'Encrypted'
    }

    It 'passes an unencrypted volume through as clear' {
        Mock Get-BitLockerVolume { [PSCustomObject]@{ ProtectionStatus = 'Off'; VolumeStatus = 'FullyDecrypted' } }
        (Get-BitLockerProtectionState -MountPoint 'X:').Label | Should -Be 'Clear'
    }

    It 'says it could not tell rather than saying the volume is unencrypted' {
        # A volume that cannot be read may well be encrypting, and calling that "not encrypted"
        # is the one wrong answer here that can cost a user their data.
        Mock Get-BitLockerVolume { throw 'BitLocker is not available on this machine.' }
        $state = Get-BitLockerProtectionState -MountPoint 'X:'
        $state.Known | Should -BeFalse
        $state.Covered | Should -BeFalse
        $state.Label | Should -Be 'Unknown'
    }
}

Describe 'Resolve-BitLockerAbandonedAdvice' {
    It 'says the drive is usable as it is when nothing was encrypted' {
        $lines = (Resolve-BitLockerAbandonedAdvice -MountPoint 'X:' -VolumeState 'Clear') -join "`n"
        $lines | Should -Match 'X: is not encrypted'
        $lines | Should -Not -Match 'recovery key'
    }

    It 'never claims an encrypted drive works without BitLocker' {
        $lines = (Resolve-BitLockerAbandonedAdvice -MountPoint 'X:' -VolumeState 'Encrypted') -join "`n"
        $lines | Should -Match 'X: is already encrypted'
        $lines | Should -Match 'recovery key is the only way back'
        $lines | Should -Not -Match 'not encrypted'
    }

    It 'tells the user how to read the key again' {
        $lines = (Resolve-BitLockerAbandonedAdvice -MountPoint 'X:' -VolumeState 'Encrypted') -join "`n"
        $lines | Should -Match 'Get-BitLockerVolume -MountPoint X:'
    }

    It 'says an abandoned encrypted drive needs unlocking by hand after every restart' {
        # This advice is reached before the automatic-unlock step, so that step never ran.
        (Resolve-BitLockerAbandonedAdvice -MountPoint 'X:' -VolumeState 'Encrypted') -join "`n" |
            Should -Match 'drive X: has to be unlocked by hand after every restart'
    }

    It 'does not raise unlocking on a drive that was never encrypted' {
        (Resolve-BitLockerAbandonedAdvice -MountPoint 'X:' -VolumeState 'Clear') -join "`n" |
            Should -Not -Match 'unlocked by hand'
    }

    It 'refuses to call an unreadable volume unencrypted' {
        $lines = (Resolve-BitLockerAbandonedAdvice -MountPoint 'X:' -VolumeState 'Unknown') -join "`n"
        $lines | Should -Match 'could not be read'
        $lines | Should -Match 'do not assume it is unencrypted'
    }

    It 'assumes nothing when no state is passed' {
        (Resolve-BitLockerAbandonedAdvice -MountPoint 'X:') -join "`n" | Should -Match 'could not be read'
    }

    It 'returns plain lines rather than an object to unwrap' {
        Resolve-BitLockerAbandonedAdvice -MountPoint 'X:' -VolumeState 'Clear' | Should -BeOfType [string]
    }
}

Describe 'Resolve-BitLockerAdProtectorNeed' {
    It 'adds the protector when the plan wants one and the volume has none' {
        Resolve-BitLockerAdProtectorNeed -ExistingTypes @('Password', 'RecoveryPassword') -Wanted |
            Should -BeTrue
    }

    It 'adds nothing when the volume already carries one' {
        Resolve-BitLockerAdProtectorNeed -ExistingTypes @('RecoveryPassword', 'AdAccountOrGroup') -Wanted |
            Should -BeFalse
    }

    It 'adds nothing when the plan does not want one' -TestCases @(
        @{ Types = @('RecoveryPassword') }
        @{ Types = @('AdAccountOrGroup') }
    ) {
        Resolve-BitLockerAdProtectorNeed -ExistingTypes $Types | Should -BeFalse
    }

    It 'does not throw on a volume that reports no protectors' {
        { Resolve-BitLockerAdProtectorNeed -ExistingTypes $null -Wanted } | Should -Not -Throw
        Resolve-BitLockerAdProtectorNeed -ExistingTypes $null -Wanted | Should -BeTrue
        Resolve-BitLockerAdProtectorNeed -ExistingTypes @() -Wanted | Should -BeTrue
    }
}

Describe 'Resolve-BitLockerUnlockAction' {
    It 'leaves an unlocked volume alone' -TestCases @(
        @{ LockStatus = 'Unlocked' }
        @{ LockStatus = '' }
    ) {
        $action = Resolve-BitLockerUnlockAction -MountPoint 'X:' -LockStatus $LockStatus -HasPassword
        $action.Action | Should -Be 'None'
        $action.DeferAutoUnlock | Should -BeFalse
        $action.Lines | Should -BeNullOrEmpty
    }

    It 'unlocks a locked volume when the run holds its password' {
        $action = Resolve-BitLockerUnlockAction -MountPoint 'X:' -LockStatus 'Locked' -HasPassword
        $action.Action | Should -Be 'Unlock'
        $action.DeferAutoUnlock | Should -BeFalse
    }

    It 'explains a locked volume it has no password for, and defers automatic unlocking' {
        $action = Resolve-BitLockerUnlockAction -MountPoint 'X:' -LockStatus 'Locked'
        $action.Action | Should -Be 'Explain'
        $action.DeferAutoUnlock | Should -BeTrue
        ($action.Lines -join "`n") | Should -Match 'manage-bde -unlock X:'
    }
}

Describe 'Get-BitLockerAutoUnlockState' {
    It 'reports what the volume answers' {
        Mock Get-BitLockerVolume { [PSCustomObject]@{ AutoUnlockEnabled = $true } }
        Get-BitLockerAutoUnlockState -MountPoint 'X:' | Should -Be 'Enabled'
    }

    It 'passes a volume that does not unlock itself through as disabled' {
        Mock Get-BitLockerVolume { [PSCustomObject]@{ AutoUnlockEnabled = $false } }
        Get-BitLockerAutoUnlockState -MountPoint 'X:' | Should -Be 'Disabled'
    }

    It 'says it could not tell rather than answering for the volume' {
        # "Unknown" and "Disabled" are different facts, and only the volume may say which it is.
        Mock Get-BitLockerVolume { throw 'BitLocker is not available on this machine.' }
        Get-BitLockerAutoUnlockState -MountPoint 'X:' | Should -Be 'Unknown'
    }
}

Describe 'Resolve-BitLockerAutoUnlockReport' {
    It 'credits the volume, not the call, for a working automatic unlock' {
        (Resolve-BitLockerAutoUnlockReport -MountPoint 'X:' -Outcome 'Enabled') -join "`n" |
            Should -Match 'the volume confirms it'
    }

    It 'reports a failed automatic unlock without calling the BitLocker setup failed' {
        $lines = (Resolve-BitLockerAutoUnlockReport -MountPoint 'X:' -Outcome 'Failed' `
                -Message 'Die Gruppenrichtlinien lassen das nicht zu. (0x8031005E)') -join "`n"
        $lines | Should -Match 'Automatic unlocking could not be set up'
        $lines | Should -Not -Match 'did not finish'
    }

    It 'claims nothing about the encryption, which only the volume can be asked about' {
        # The line printed just above this one reads the protection state off the volume; asserting
        # it here from an outcome name would contradict that read whenever it came back negative.
        $lines = (Resolve-BitLockerAutoUnlockReport -MountPoint 'X:' -Outcome 'Failed' -Message 'x') -join "`n"
        $lines | Should -Not -Match 'encrypted'
        $lines | Should -Not -Match 'protected'
    }

    It 'repeats the reason in the words Windows used for it' {
        # The run this came from was a German machine: only the message itself carries the reason.
        $lines = (Resolve-BitLockerAutoUnlockReport -MountPoint 'X:' -Outcome 'Failed' `
                -Message 'Die Gruppenrichtlinien lassen das nicht zu. (0x8031005E)') -join "`n"
        $lines | Should -Match '0x8031005E'
        $lines | Should -Match 'Gruppenrichtlinien'
    }

    It 'blames no cause it did not establish' {
        # Every failure arrives as one outcome, so a standing refusal must not be asserted for what
        # may have been a one-off.
        (Resolve-BitLockerAutoUnlockReport -MountPoint 'X:' -Outcome 'Failed' -Message 'x') -join "`n" |
            Should -Not -Match 'policy|never allow|ever allows'
    }

    It 'does not throw when Windows said nothing it could quote' {
        { Resolve-BitLockerAutoUnlockReport -MountPoint 'X:' -Outcome 'Failed' -Message '' } | Should -Not -Throw
    }

    It 'names the manual unlock after every restart on <Outcome>, in one wording' -TestCases @(
        @{ Outcome = 'Failed' }
        @{ Outcome = 'Unconfirmed' }
        @{ Outcome = 'Deferred' }
        @{ Outcome = 'NotOffered' }
    ) {
        # The consequence a person actually lives with, and the one the run never used to mention.
        (Resolve-BitLockerAutoUnlockReport -MountPoint 'X:' -Outcome $Outcome -Message 'x') -join "`n" |
            Should -Match 'drive X: has to be unlocked by hand after every restart'
    }

    It 'does not warn about unlocking by hand when nothing has to be' {
        (Resolve-BitLockerAutoUnlockReport -MountPoint 'X:' -Outcome 'Enabled') -join "`n" |
            Should -Not -Match 'by hand'
    }

    It 'points a deferred setup at the command that finishes it' {
        (Resolve-BitLockerAutoUnlockReport -MountPoint 'X:' -Outcome 'Deferred') -join "`n" |
            Should -Match 'Enable-BitLockerAutoUnlock -MountPoint X:'
    }

    It 'sends an unconfirmed setup to the volume for the answer' {
        (Resolve-BitLockerAutoUnlockReport -MountPoint 'X:' -Outcome 'Unconfirmed') -join "`n" |
            Should -Match 'AutoUnlockEnabled'
    }

    It 'gives the reason automatic unlocking was never offered, not a claim about the machine' {
        # It is the operating system drive being unprotected, which the person can change.
        (Resolve-BitLockerAutoUnlockReport -MountPoint 'X:' -Outcome 'NotOffered') -join "`n" |
            Should -Match 'operating system drive is not BitLocker-protected'
    }

    It 'has wording for every outcome it accepts' {
        # The switch and the ValidateSet are two lists that would otherwise drift apart in silence.
        $set = (Get-Command Resolve-BitLockerAutoUnlockReport).Parameters['Outcome'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        @($set.ValidValues).Count | Should -Be 5
        foreach ($outcome in $set.ValidValues) {
            @(Resolve-BitLockerAutoUnlockReport -MountPoint 'X:' -Outcome $outcome -Message 'x').Count |
                Should -BeGreaterThan 0
        }
    }

    It 'refuses an outcome that is not one of the five' {
        { Resolve-BitLockerAutoUnlockReport -MountPoint 'X:' -Outcome 'Whatever' } | Should -Throw
    }
}

Describe 'Resolve-DevDriveTrustReport' {
    BeforeAll {
        $script:TrustedOutput = @'
This is a trusted developer volume.

Developer volumes are protected by antivirus filter.

Filters currently attached to this developer volume:
    WdFilter
'@
    }

    It 'confirms trust only when the volume itself says it is trusted' {
        $report = Resolve-DevDriveTrustReport -MountPoint 'X:' -TrustExitCode 0 -QueryOutput $script:TrustedOutput
        $report.Outcome | Should -Be 'Trusted'
        ($report.Lines -join "`n") | Should -Match 'X: reports itself trusted'
    }

    It 'says nothing beyond the one line when the volume is trusted' {
        (Resolve-DevDriveTrustReport -MountPoint 'X:' -TrustExitCode 0 -QueryOutput $script:TrustedOutput).Lines.Count |
            Should -Be 1
    }

    It 'calls it a failure only when the command itself failed, whatever the query says' {
        $report = Resolve-DevDriveTrustReport -MountPoint 'X:' -TrustExitCode 1 -QueryOutput $script:TrustedOutput
        $report.Outcome | Should -Be 'Failed'
        $lines = $report.Lines -join "`n"
        $lines | Should -Match 'exited with code 1'
        $lines | Should -Match 'will still work'
        $lines | Should -Match 'Retry by hand with: fsutil devdrv trust /f X:'
    }

    It 'reports an answer it cannot read as unconfirmed, not as a failure' -TestCases @(
        @{ Answer = 'Dies ist ein vertrauenswuerdiges Entwicklervolume.' }
        @{ Answer = 'This is not a developer volume.' }
        @{ Answer = 'This is not a trusted developer volume.' }
    ) {
        $report = Resolve-DevDriveTrustReport -MountPoint 'X:' -TrustExitCode 0 -QueryOutput $Answer
        $report.Outcome | Should -Be 'Unconfirmed'
        $lines = $report.Lines -join "`n"
        $lines | Should -Match 'answers in this machine.s language'
        $lines | Should -Match 'It should say the volume is trusted\.'
    }

    It 'raises no alarm on a run where only the language stopped it reading the answer' {
        $lines = (Resolve-DevDriveTrustReport -MountPoint 'X:' -TrustExitCode 0 -QueryOutput 'Dies ist ein vertrauenswuerdiges Entwicklervolume.').Lines -join "`n"
        $lines | Should -Not -Match 'could not'
        $lines | Should -Not -Match 'will still work'
        $lines | Should -Not -Match 'Retry by hand'
    }

    It 'quotes what the query actually said, so the user judges it themselves' -TestCases @(
        @{ Code = 0 }
        @{ Code = 1 }
    ) {
        $lines = (Resolve-DevDriveTrustReport -MountPoint 'X:' -TrustExitCode $Code -QueryOutput 'This is not a developer volume.').Lines -join "`n"
        $lines | Should -Match 'This is not a developer volume\.'
    }

    It 'says so plainly when the query answered nothing at all' -TestCases @(
        @{ Code = 0; Expected = '\(nothing\)' }
        @{ Code = 1; Expected = 'said nothing' }
    ) {
        $lines = (Resolve-DevDriveTrustReport -MountPoint 'X:' -TrustExitCode $Code -QueryOutput '').Lines -join "`n"
        $lines | Should -Match $Expected
    }

    It 'returns plain lines rather than an object to unwrap' {
        (Resolve-DevDriveTrustReport -MountPoint 'X:' -TrustExitCode 0 -QueryOutput $script:TrustedOutput).Lines |
            Should -BeOfType [string]
    }
}

Describe 'Test-RecoveryKeyAcknowledged' {
    It 'accepts <Description>' -TestCases @(
        @{ Description = 'the word itself'; Answer = 'YES' }
        @{ Description = 'the word in any case'; Answer = 'yes' }
        @{ Description = 'the word with spaces around it'; Answer = '  YES  ' }
    ) {
        Test-RecoveryKeyAcknowledged -Answer $Answer -Word 'YES' | Should -BeTrue
    }

    It 'refuses <Description>' -TestCases @(
        @{ Description = 'an empty answer, as a bare Enter gives'; Answer = '' }
        @{ Description = 'no answer at all'; Answer = $null }
        @{ Description = 'whitespace'; Answer = '   ' }
        @{ Description = 'another word'; Answer = 'no' }
        @{ Description = 'the word inside a sentence'; Answer = 'yes I did' }
    ) {
        Test-RecoveryKeyAcknowledged -Answer $Answer -Word 'YES' | Should -BeFalse
    }
}

Describe 'Request-BitLockerFailureChoice' {
    BeforeAll {
        # The menu text is not under test here, only which answer maps to which decision.
        Mock Write-Host { }
    }

    It 'maps answer <Answer> to <Expected> when a retry is on offer' -TestCases @(
        @{ Answer = '1'; Expected = 'Retry' }
        @{ Answer = '2'; Expected = 'Continue' }
        @{ Answer = '3'; Expected = 'Stop' }
    ) {
        Mock Read-Host { $Answer }
        Request-BitLockerFailureChoice -AllowRetry | Should -Be $Expected
    }

    It 'maps answer <Answer> to <Expected> when a retry would be pointless' -TestCases @(
        @{ Answer = '1'; Expected = 'Continue' }
        @{ Answer = '2'; Expected = 'Stop' }
    ) {
        Mock Read-Host { $Answer }
        Request-BitLockerFailureChoice | Should -Be $Expected
    }

    It 'rejects the third answer when only two choices are on offer' {
        $script:answers = @('3', '1')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        Request-BitLockerFailureChoice | Should -Be 'Continue'
        $script:index | Should -Be 2
    }

    It 'keeps asking until the answer is one of the choices' {
        $script:answers = @('', 'yes', '4', '2')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        Request-BitLockerFailureChoice -AllowRetry | Should -Be 'Continue'
        $script:index | Should -Be 4
    }
}

Describe 'Resolve-VhdxMountAdvice' {
    It 'says nothing about mounting by hand when Windows does it' {
        $lines = (Resolve-VhdxMountAdvice -VhdxPath 'D:\dev.vhdx' -AutoAttachRequested -AutoAttachGranted) -join "`n"
        $lines | Should -Match 'automatically on every startup'
        $lines | Should -Not -Match 'Mount-DiskImage'
    }

    It 'gives the command when the user declined automatic mounting' {
        $lines = (Resolve-VhdxMountAdvice -VhdxPath 'D:\dev.vhdx') -join "`n"
        $lines | Should -Match 'You chose to mount this Dev Drive yourself'
        $lines | Should -Match ([regex]::Escape("Mount-DiskImage -ImagePath 'D:\dev.vhdx' -StorageType VHDX -Access ReadWrite"))
    }

    It 'gives the command when Windows refused the request' {
        $lines = (Resolve-VhdxMountAdvice -VhdxPath 'D:\dev.vhdx' -AutoAttachRequested) -join "`n"
        $lines | Should -Match 'Automatic mounting was NOT enabled'
        $lines | Should -Match 'Mount-DiskImage -ImagePath'
    }

    It 'names the administrator requirement whenever it gives the command' -TestCases @(
        @{ Requested = $true }
        @{ Requested = $false }
    ) {
        $lines = (Resolve-VhdxMountAdvice -VhdxPath 'D:\dev.vhdx' -AutoAttachRequested:$Requested) -join "`n"
        $lines | Should -Match 'started as administrator'
    }

    It 'returns plain lines rather than an object to unwrap' {
        Resolve-VhdxMountAdvice -VhdxPath 'D:\dev.vhdx' | Should -BeOfType [string]
    }
}

Describe 'Resolve-VhdxPortabilityAdvice' {
    It 'names the file and says the trusted status does not travel with it' {
        $lines = (Resolve-VhdxPortabilityAdvice -VhdxPath 'D:\dev.vhdx') -join "`n"
        $lines | Should -Match ([regex]::Escape('D:\dev.vhdx'))
        $lines | Should -Match 'does not travel with the file'
    }

    It 'says Microsoft advises against the move before saying how to survive it' {
        $lines = Resolve-VhdxPortabilityAdvice -VhdxPath 'D:\dev.vhdx'
        $adviceAt = ($lines | Select-String -Pattern 'does not recommend').LineNumber
        $commandAt = ($lines | Select-String -Pattern 'fsutil devdrv trust /f').LineNumber
        $adviceAt | Should -Not -BeNullOrEmpty
        $commandAt | Should -BeGreaterThan $adviceAt
    }

    It 'says nothing about this run, only about the file elsewhere' {
        $lines = (Resolve-VhdxPortabilityAdvice -VhdxPath 'D:\dev.vhdx') -join "`n"
        $lines | Should -Not -Match 'Mount-DiskImage'
        $lines | Should -Not -Match 'startup'
    }

    It 'returns plain lines rather than an object to unwrap' {
        Resolve-VhdxPortabilityAdvice -VhdxPath 'D:\dev.vhdx' | Should -BeOfType [string]
    }
}

Describe 'Resolve-RerunAdvice' {
    It 'says the run does not resume, and never says to just try again' {
        $lines = (Resolve-RerunAdvice -ShrunkDriveLetter $null) -join "`n"
        $lines | Should -Match 'does not resume'
        $lines | Should -Not -Match 'try again'
    }

    It 'says nothing about a shrunk drive when nothing was shrunk' -TestCases @(
        @{ ShrunkDriveLetter = $null }
        @{ ShrunkDriveLetter = '' }
    ) {
        $lines = (Resolve-RerunAdvice -ShrunkDriveLetter $ShrunkDriveLetter) -join "`n"
        $lines | Should -Not -Match 'shrunk'
    }

    It 'names the shrunk drive and warns a second run takes the same amount off it again' {
        $lines = (Resolve-RerunAdvice -ShrunkDriveLetter 'C') -join ' '
        $lines | Should -Match 'Drive C: has already been shrunk'
        $lines | Should -Match 'off it a second time'
    }

    It 'returns plain lines rather than an object to unwrap' {
        Resolve-RerunAdvice -ShrunkDriveLetter $null | Should -BeOfType [string]
    }
}

Describe 'Resolve-DedupTimeInput' {
    It 'rejects <Answer> as <Rejection>' -TestCases @(
        @{ Answer = '';       Rejection = 'Empty' }
        @{ Answer = '   ';    Rejection = 'Empty' }
        @{ Answer = 'abc';    Rejection = 'InvalidTime' }
        @{ Answer = '24:00';  Rejection = 'InvalidTime' }
        @{ Answer = '25:00';  Rejection = 'InvalidTime' }
        @{ Answer = '12:60';  Rejection = 'InvalidTime' }
        @{ Answer = '12:5';   Rejection = 'InvalidTime' }
        @{ Answer = '011:00'; Rejection = 'InvalidTime' }
        @{ Answer = '1200';   Rejection = 'InvalidTime' }
        @{ Answer = '12.30';  Rejection = 'InvalidTime' }
        @{ Answer = '-1:00';  Rejection = 'InvalidTime' }
        @{ Answer = '8:15pm'; Rejection = 'InvalidTime' }
    ) {
        (Resolve-DedupTimeInput -Answer $Answer).Rejection | Should -Be $Rejection
    }

    It 'accepts <Answer> as <Expected>' -TestCases @(
        @{ Answer = '00:00';   Expected = '00:00' }
        @{ Answer = '0:00';    Expected = '00:00' }
        @{ Answer = '8:15';    Expected = '08:15' }
        @{ Answer = '08:15';   Expected = '08:15' }
        @{ Answer = '9:05';    Expected = '09:05' }
        @{ Answer = '13:00';   Expected = '13:00' }
        @{ Answer = '23:59';   Expected = '23:59' }
        @{ Answer = ' 8:15 ';  Expected = '08:15' }
    ) {
        $verdict = Resolve-DedupTimeInput -Answer $Answer
        $verdict.Rejection | Should -BeNullOrEmpty
        $verdict.Time | Should -Be $Expected
    }

    Context 'when an empty answer means keeping the current time' {
        It 'returns the current time for <Answer>' -TestCases @(
            @{ Answer = '' }
            @{ Answer = '   ' }
        ) {
            $verdict = Resolve-DedupTimeInput -Answer $Answer -CurrentTime '17:30' -AllowEmpty
            $verdict.Rejection | Should -BeNullOrEmpty
            $verdict.Time | Should -Be '17:30'
        }

        It 'still rejects a time that is not a time' {
            (Resolve-DedupTimeInput -Answer '99:99' -CurrentTime '17:30' -AllowEmpty).Rejection |
                Should -Be 'InvalidTime'
        }

        It 'rejects an empty answer when there is no current time to fall back to' {
            (Resolve-DedupTimeInput -Answer '' -AllowEmpty).Rejection | Should -Be 'Empty'
        }
    }
}

Describe 'Resolve-DedupTimeListInput' {
    It 'rejects <Answer> as <Rejection>' -TestCases @(
        @{ Answer = '';               Rejection = 'Empty' }
        @{ Answer = '   ';            Rejection = 'Empty' }
        @{ Answer = ',';              Rejection = 'Empty' }
        @{ Answer = ' , ';            Rejection = 'Empty' }
        @{ Answer = 'abc';            Rejection = 'InvalidTime' }
        @{ Answer = '11:00,25:00';    Rejection = 'InvalidTime' }
        @{ Answer = '11:00,,17:00';   Rejection = 'InvalidTime' }
        @{ Answer = '11:00,17:00,';   Rejection = 'InvalidTime' }
        @{ Answer = '11:00,,,,17:00'; Rejection = 'InvalidTime' }
        @{ Answer = '11:00,11:00';    Rejection = 'DuplicateTime' }
        @{ Answer = '8:15,08:15';     Rejection = 'DuplicateTime' }
        @{ Answer = '1:00,2:00,3:00,4:00,5:00'; Rejection = 'TooMany' }
    ) {
        (Resolve-DedupTimeListInput -Answer $Answer).Rejection | Should -Be $Rejection
    }

    It 'accepts a single time' {
        $verdict = Resolve-DedupTimeListInput -Answer '9:00'
        $verdict.Rejection | Should -BeNullOrEmpty
        @($verdict.Times) | Should -Be @('09:00')
    }

    It 'accepts the maximum of four times' {
        $verdict = Resolve-DedupTimeListInput -Answer '1:00,2:00,3:00,4:00'
        $verdict.Rejection | Should -BeNullOrEmpty
        @($verdict.Times).Count | Should -Be 4
    }

    It 'trims the spaces around each entry' {
        (Resolve-DedupTimeListInput -Answer ' 8:15 , 13:00 ').Times | Should -Be @('08:15', '13:00')
    }

    It 'returns the times in ascending order whatever order they were typed in' {
        (Resolve-DedupTimeListInput -Answer '17:00,8:15,13:00').Times |
            Should -Be @('08:15', '13:00', '17:00')
    }

    Context 'when an empty answer means keeping the current times' {
        It 'returns the current times for <Answer>' -TestCases @(
            @{ Answer = '' }
            @{ Answer = '   ' }
        ) {
            $verdict = Resolve-DedupTimeListInput -Answer $Answer -CurrentTimes @('11:00', '17:00') -AllowEmpty
            $verdict.Rejection | Should -BeNullOrEmpty
            $verdict.Times | Should -Be @('11:00', '17:00')
        }

        It 'still rejects a list of nothing but separators' {
            (Resolve-DedupTimeListInput -Answer ',,' -CurrentTimes @('11:00') -AllowEmpty).Rejection |
                Should -Be 'Empty'
        }
    }
}

Describe 'Resolve-DedupDayInput' {
    It 'rejects <Answer> as <Rejection>' -TestCases @(
        @{ Answer = '';         Rejection = 'Empty' }
        @{ Answer = '   ';      Rejection = 'Empty' }
        @{ Answer = 'Funday';   Rejection = 'InvalidDay' }
        @{ Answer = 'Mo';       Rejection = 'InvalidDay' }
        @{ Answer = 'Mondays';  Rejection = 'InvalidDay' }
        @{ Answer = 'Thurs';    Rejection = 'InvalidDay' }
        @{ Answer = '1';        Rejection = 'InvalidDay' }
    ) {
        (Resolve-DedupDayInput -Answer $Answer).Rejection | Should -Be $Rejection
    }

    It 'accepts <Answer> as <Expected>' -TestCases @(
        @{ Answer = 'Monday';    Expected = 'Monday' }
        @{ Answer = 'monday';    Expected = 'Monday' }
        @{ Answer = 'MONDAY';    Expected = 'Monday' }
        @{ Answer = 'Mon';       Expected = 'Monday' }
        @{ Answer = 'tue';       Expected = 'Tuesday' }
        @{ Answer = 'WED';       Expected = 'Wednesday' }
        @{ Answer = 'thursday';  Expected = 'Thursday' }
        @{ Answer = ' fri ';     Expected = 'Friday' }
        @{ Answer = 'Sat';       Expected = 'Saturday' }
        @{ Answer = 'sunday';    Expected = 'Sunday' }
    ) {
        $verdict = Resolve-DedupDayInput -Answer $Answer
        $verdict.Rejection | Should -BeNullOrEmpty
        $verdict.Day | Should -BeExactly $Expected
    }

    Context 'when an empty answer means keeping the current day' {
        It 'returns the current day for <Answer>' -TestCases @(
            @{ Answer = '' }
            @{ Answer = '   ' }
        ) {
            $verdict = Resolve-DedupDayInput -Answer $Answer -CurrentDay 'Monday' -AllowEmpty
            $verdict.Rejection | Should -BeNullOrEmpty
            $verdict.Day | Should -Be 'Monday'
        }

        It 'still rejects a word that is not a day' {
            (Resolve-DedupDayInput -Answer 'someday' -CurrentDay 'Monday' -AllowEmpty).Rejection |
                Should -Be 'InvalidDay'
        }
    }
}

Describe 'Request-DeduplicationChoice' {
    BeforeEach {
        Mock Write-Host {}
    }

    It 'returns <Expected> for answer <Answer>' -TestCases @(
        @{ Answer = '1'; Expected = 'Dedup' }
        @{ Answer = '2'; Expected = 'DedupAndCompress' }
        @{ Answer = '3'; Expected = 'Compress' }
        @{ Answer = '4'; Expected = 'None' }
    ) {
        Mock Read-Host { $Answer }
        Request-DeduplicationChoice | Should -Be $Expected
    }

    It 'offers compression without deduplication, the third mode the cmdlet accepts' {
        Mock Read-Host { '1' }
        Request-DeduplicationChoice | Out-Null
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'Compress only, without looking for duplicates' }
    }

    It 'keeps asking until the answer is one of the four' {
        $script:answers = @('0', '5', 'yes', '3')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        Request-DeduplicationChoice | Should -Be 'Compress'
        $script:index | Should -Be 4
    }
}

Describe 'Format-DedupModeChoice' {
    It 'says what each mode does, and names compression only where there is some' -TestCases @(
        @{ Mode = 'Dedup'; Format = $null; Level = $null; Expected = 'deduplication only, without compression' }
        @{ Mode = 'DedupAndCompress'; Format = 'ZSTD'; Level = 7; Expected = 'deduplication and ZSTD compression, level 7' }
        @{ Mode = 'DedupAndCompress'; Format = 'LZ4'; Level = $null; Expected = 'deduplication and LZ4 compression' }
        @{ Mode = 'Compress'; Format = 'LZ4'; Level = 12; Expected = 'LZ4 compression, level 12, without deduplication' }
        @{ Mode = 'Compress'; Format = 'ZSTD'; Level = $null; Expected = 'ZSTD compression, without deduplication' }
    ) {
        Format-DedupModeChoice -Mode $Mode -Format $Format -Level $Level | Should -Be $Expected
    }

    It 'never claims deduplication for the mode that does none' {
        $text = Format-DedupModeChoice -Mode 'Compress' -Format 'ZSTD' -Level 3
        $text | Should -Match 'without deduplication'
        $text | Should -Not -Match 'deduplication and'
    }

    It 'ignores the format entirely when the mode does not compress' {
        Format-DedupModeChoice -Mode 'Dedup' -Format 'ZSTD' -Level 9 |
            Should -Be 'deduplication only, without compression'
    }

    It 'refuses a mode it does not know' {
        { Format-DedupModeChoice -Mode 'Disabled' -Format 'LZ4' -Level 1 } | Should -Throw
    }
}

Describe 'Request-Compression' {
    BeforeEach {
        Mock Write-Host {}
    }

    It 'takes <Expected> with no level for answer <Answer>' -TestCases @(
        @{ Answer = '1'; Expected = 'LZ4' }
        @{ Answer = '2'; Expected = 'ZSTD' }
    ) {
        Mock Read-Host { $Answer }
        $chosen = Request-Compression
        $chosen.Format | Should -Be $Expected
        $chosen.Level | Should -BeNullOrEmpty
    }

    It 'asks nothing further for the two shortcut answers' {
        Mock Read-Host { '1' }
        Request-Compression | Out-Null
        Should -Invoke Read-Host -Times 1 -Exactly
    }

    It 'asks for the format and then the level when the user picks them' {
        $script:answers = @('3', '2', '15')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        $chosen = Request-Compression
        $chosen.Format | Should -Be 'ZSTD'
        $chosen.Level | Should -Be 15
    }

    It 'lets the level be left to Windows even on the path that offers to set it' {
        $script:answers = @('3', '1', '')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        $chosen = Request-Compression
        $chosen.Format | Should -Be 'LZ4'
        $chosen.Level | Should -BeNullOrEmpty
    }

    It 'keeps asking until the answer is one of the three' {
        $script:answers = @('0', '4', 'fast', '2')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        (Request-Compression).Format | Should -Be 'ZSTD'
        $script:index | Should -Be 4
    }

    It 'names what each shortcut does, and that Windows picks the level' {
        Mock Read-Host { '1' }
        Request-Compression | Out-Null
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'Fast - LZ4, at the level Windows picks' }
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'Balanced - ZSTD, at the level Windows picks' }
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'Pick the format and level yourself' }
    }

    It 'returns one object rather than leaving a format without its level' {
        Mock Read-Host { '2' }
        $chosen = Request-Compression
        $chosen.PSObject.Properties.Name | Should -Contain 'Format'
        $chosen.PSObject.Properties.Name | Should -Contain 'Level'
    }
}

Describe 'Get-DedupVolumeReport' {
    It 'reports what the volume answered, still typed rather than rendered' {
        Mock Get-ReFSDedupSchedule {
            [PSCustomObject]@{ Type = 'DedupAndCompress'; CompressionFormat = 'ZSTD'; CompressionLevel = [uint16]7 }
        }
        $report = Get-DedupVolumeReport -MountPoint 'X:'
        $report.Known | Should -BeTrue
        $report.Mode | Should -Be 'DedupAndCompress'
        $report.Format | Should -Be 'ZSTD'
        $report.Level | Should -Be 7
    }

    It 'takes the first schedule when the volume has several, since they share these settings' {
        Mock Get-ReFSDedupSchedule {
            @(
                [PSCustomObject]@{ Type = 'Compress'; CompressionFormat = 'LZ4'; CompressionLevel = [uint16]12 }
                [PSCustomObject]@{ Type = 'Dedup'; CompressionFormat = 'ZSTD'; CompressionLevel = [uint16]7 }
            )
        }
        $report = Get-DedupVolumeReport -MountPoint 'X:'
        $report.Level | Should -Be 12
        $report.Mode | Should -Be 'Compress'
    }

    It 'says it could not be asked rather than inventing an answer, and why' {
        Mock Get-ReFSDedupSchedule { throw 'Access is denied.' }
        $report = Get-DedupVolumeReport -MountPoint 'X:'
        $report.Known | Should -BeFalse
        $report.Reason | Should -Match 'Windows said: Access is denied\.'
    }

    It 'calls an empty answer no schedule, not a volume that would not answer' {
        Mock Get-ReFSDedupSchedule { @() }
        $report = Get-DedupVolumeReport -MountPoint 'X:'
        $report.Known | Should -BeFalse
        $report.Reason | Should -Match 'reports no schedule at all'
        $report.Reason | Should -Not -Match 'Windows said'
    }
}

Describe 'Resolve-DedupReadBackVerdict' {
    BeforeAll {
        function New-Report {
            param([string]$Mode, [string]$Format, [int]$Level, [bool]$Known = $true, [string]$Reason = '')
            return [PSCustomObject]@{ Known = $Known; Reason = $Reason; Mode = $Mode; Format = $Format; Level = $Level }
        }
    }

    It 'agrees when the volume reports what was asked for' {
        $verdict = Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'DedupAndCompress' `
            -ExpectedFormat 'ZSTD' -ExpectedLevel 7 -Actual (New-Report -Mode 'DedupAndCompress' -Format 'ZSTD' -Level 7)
        $verdict.Agrees | Should -BeTrue
        $verdict.Lines -join "`n" | Should -Match 'X: confirms it: deduplication and ZSTD compression, level 7\.'
    }

    It 'treats a reported level of 0 as the default, which is what asking for no level means' {
        $verdict = Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'Compress' `
            -ExpectedFormat 'LZ4' -ExpectedLevel $null -Actual (New-Report -Mode 'Compress' -Format 'LZ4' -Level 0)
        $verdict.Agrees | Should -BeTrue
        $lines = $verdict.Lines -join "`n"
        $lines | Should -Match 'The compression level is the one Windows picks\.'
        $lines | Should -Not -Match 'level 0'
    }

    It 'accepts any level when none was asked for' {
        $verdict = Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'DedupAndCompress' `
            -ExpectedFormat 'ZSTD' -ExpectedLevel $null -Actual (New-Report -Mode 'DedupAndCompress' -Format 'ZSTD' -Level 3)
        $verdict.Agrees | Should -BeTrue
        $verdict.Lines -join "`n" | Should -Match 'level 3'
    }

    It 'names every setting that came back different' -TestCases @(
        @{ Mode = 'Compress'; Format = 'ZSTD'; Level = 7; Expect = 'mode: asked for DedupAndCompress, the volume reports Compress' }
        @{ Mode = 'DedupAndCompress'; Format = 'LZ4'; Level = 7; Expect = 'compression format: asked for ZSTD, the volume reports LZ4' }
        @{ Mode = 'DedupAndCompress'; Format = 'ZSTD'; Level = 3; Expect = 'compression level: asked for level 7, the volume reports level 3' }
    ) {
        $verdict = Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'DedupAndCompress' `
            -ExpectedFormat 'ZSTD' -ExpectedLevel 7 -Actual (New-Report -Mode $Mode -Format $Format -Level $Level)
        $verdict.Agrees | Should -BeFalse
        $verdict.Lines -join "`n" | Should -Match ([regex]::Escape($Expect))
    }

    It 'calls a level asked for and answered with the default a difference, and names it as the default' {
        $verdict = Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'DedupAndCompress' `
            -ExpectedFormat 'ZSTD' -ExpectedLevel 7 -Actual (New-Report -Mode 'DedupAndCompress' -Format 'ZSTD' -Level 0)
        $verdict.Agrees | Should -BeFalse
        $verdict.Lines -join "`n" | Should -Match 'the volume reports the default'
    }

    It 'ignores the compression settings for the mode that does not compress' {
        $verdict = Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'Dedup' `
            -ExpectedFormat 'ZSTD' -ExpectedLevel 9 -Actual (New-Report -Mode 'Dedup' -Format 'LZ4' -Level 0)
        $verdict.Agrees | Should -BeTrue
        $verdict.Lines -join "`n" | Should -Be 'X: confirms it: deduplication only, without compression.'
    }

    It 'says the drive still works when the settings disagree' {
        $verdict = Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'Dedup' `
            -ExpectedFormat '' -ExpectedLevel $null -Actual (New-Report -Mode 'Disabled' -Format 'LZ4' -Level 0)
        $verdict.Agrees | Should -BeFalse
        $verdict.Lines -join "`n" | Should -Match 'created and usable'
    }

    It 'asks the user to look for themselves when the volume could not be read' {
        $verdict = Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'Dedup' `
            -ExpectedFormat '' -ExpectedLevel $null -Actual (New-Report -Known $false -Mode '' -Format '' -Level 0)
        $verdict.Agrees | Should -BeFalse
        $lines = $verdict.Lines -join "`n"
        $lines | Should -Match 'Could not confirm the deduplication settings on X:'
        $lines | Should -Match 'Get-ReFSDedupSchedule -Volume X:'
    }

    It 'passes on the reason the volume gave, when there is one' {
        $verdict = Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'Dedup' -ExpectedFormat '' `
            -ExpectedLevel $null -Actual (New-Report -Known $false -Mode '' -Format '' -Level 0 -Reason 'Windows said: Access is denied.')
        $verdict.Lines -join "`n" | Should -Match 'Windows said: Access is denied\.'
    }

    It 'refuses a mode it does not know' {
        { Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'Disabled' -ExpectedFormat '' `
                -ExpectedLevel $null -Actual (New-Report -Mode 'Disabled' -Format '' -Level 0) } | Should -Throw
    }
}

Describe 'Get-CompressionLevelRange' {
    It 'gives LZ4 level 1 and 3 to 12, skipping 2' {
        $range = Get-CompressionLevelRange -Format 'LZ4'
        $range.Allowed | Should -Contain 1
        $range.Allowed | Should -Not -Contain 2
        $range.Allowed | Should -Contain 3
        $range.Allowed | Should -Contain 12
        $range.Allowed | Should -Not -Contain 13
    }

    It 'gives ZSTD the whole 1 to 22, not the 1 to 9 the script used to offer' {
        $range = Get-CompressionLevelRange -Format 'ZSTD'
        $range.Allowed | Should -Contain 1
        $range.Allowed | Should -Contain 10
        $range.Allowed | Should -Contain 22
        $range.Allowed | Should -Not -Contain 0
        $range.Allowed | Should -Not -Contain 23
    }

    It 'labels the range in the words the prompt prints' {
        (Get-CompressionLevelRange -Format 'LZ4').Label | Should -Be 'level 1, or 3 to 12'
        (Get-CompressionLevelRange -Format 'ZSTD').Label | Should -Be 'levels 1 to 22'
    }

    It 'refuses a format it does not know' {
        { Get-CompressionLevelRange -Format 'GZIP' } | Should -Throw
    }
}

Describe 'Resolve-CompressionLevelInput' {
    It 'reads an empty answer as no level at all, not as a number' -TestCases @(
        @{ Answer = '' }
        @{ Answer = '   ' }
        @{ Answer = $null }
        @{ Answer = '0' }
    ) {
        $parsed = Resolve-CompressionLevelInput -Format 'ZSTD' -Answer $Answer
        $parsed.Rejection | Should -BeNullOrEmpty
        $parsed.Level | Should -BeNullOrEmpty
    }

    It 'takes a level the format accepts' -TestCases @(
        @{ Format = 'LZ4';  Answer = '1';  Expected = 1 }
        @{ Format = 'LZ4';  Answer = '12'; Expected = 12 }
        @{ Format = 'ZSTD'; Answer = '22'; Expected = 22 }
        @{ Format = 'ZSTD'; Answer = ' 7 '; Expected = 7 }
    ) {
        $parsed = Resolve-CompressionLevelInput -Format $Format -Answer $Answer
        $parsed.Rejection | Should -BeNullOrEmpty
        $parsed.Level | Should -Be $Expected
    }

    It 'refuses a level the format does not accept' -TestCases @(
        @{ Format = 'LZ4';  Answer = '2';  Why = 'LZ4 skips 2' }
        @{ Format = 'LZ4';  Answer = '13'; Why = 'LZ4 stops at 12' }
        @{ Format = 'LZ4';  Answer = '22'; Why = 'that is a ZSTD level' }
        @{ Format = 'ZSTD'; Answer = '23'; Why = 'ZSTD stops at 22' }
    ) {
        (Resolve-CompressionLevelInput -Format $Format -Answer $Answer).Rejection | Should -Be 'OutOfRange'
    }

    It 'refuses an answer that is not a number' -TestCases @(
        @{ Answer = 'five' }
        @{ Answer = '3.5' }
        @{ Answer = '-3' }
        @{ Answer = '1 2' }
    ) {
        (Resolve-CompressionLevelInput -Format 'ZSTD' -Answer $Answer).Rejection | Should -Be 'NotANumber'
    }

    It 'refuses an answer that would throw on the way to a number' -TestCases @(
        @{ Answer = '99999999999999999999'; Why = 'twenty digits overflow the cast' }
        @{ Answer = '000'; Why = 'longer than any level, so the cap catches it before the cast' }
        @{ Answer = "$([char]0xFF13)"; Why = 'a fullwidth digit matches \d but does not parse' }
    ) {
        (Resolve-CompressionLevelInput -Format 'ZSTD' -Answer $Answer).Rejection | Should -Be 'NotANumber'
    }

    It 'refuses a format it does not know' {
        { Resolve-CompressionLevelInput -Format 'GZIP' -Answer '1' } | Should -Throw
    }
}

Describe 'Request-CompressionLevel' {
    BeforeEach {
        Mock Write-Host {}
    }

    It 'returns nothing at all when the user just presses Enter' {
        Mock Read-Host { '' }
        Request-CompressionLevel -Format 'ZSTD' | Should -BeNullOrEmpty
    }

    It 'returns the level the user typed' {
        Mock Read-Host { '15' }
        Request-CompressionLevel -Format 'ZSTD' | Should -Be 15
    }

    It 'keeps asking until the answer is one the format accepts' {
        $script:answers = @('2', '99999999999999999999', 'nine', '9')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        Request-CompressionLevel -Format 'LZ4' | Should -Be 9
        $script:index | Should -Be 4
    }

    It 'says which kind of answer was wrong, rather than one message for both' {
        $script:answers = @('nine', '')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        Request-CompressionLevel -Format 'ZSTD' | Out-Null
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'That is not a level' }

        $script:answers = @('99', '')
        $script:index = 0
        Request-CompressionLevel -Format 'ZSTD' | Out-Null
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'ZSTD accepts levels 1 to 22\. Enter one of those' }
    }

    It 'names the range of the format it is asking about, and offers the empty answer' -TestCases @(
        @{ Format = 'LZ4';  Range = 'level 1, or 3 to 12' }
        @{ Format = 'ZSTD'; Range = 'levels 1 to 22' }
    ) {
        Mock Read-Host { '' }
        Request-CompressionLevel -Format $Format | Out-Null
        Should -Invoke Write-Host -ParameterFilter { $Object -match [regex]::Escape($Range) }
        Should -Invoke Read-Host -ParameterFilter { $Prompt -match 'press Enter for the level Windows picks' }
    }

    It 'warns about what the higher levels of each format cost' {
        Mock Read-Host { '' }
        Request-CompressionLevel -Format 'LZ4' | Out-Null
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'LZ4HC' }
        Request-CompressionLevel -Format 'ZSTD' | Out-Null
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'more memory' }
    }
}

Describe 'Format-CompressionChoice' {
    It 'names the level whichever format has it, since both do' -TestCases @(
        @{ Format = 'LZ4';  Level = 12; Expected = 'LZ4 compression, level 12' }
        @{ Format = 'ZSTD'; Level = 7;  Expected = 'ZSTD compression, level 7' }
    ) {
        Format-CompressionChoice -Format $Format -Level $Level | Should -Be $Expected
    }

    It 'invents no level when none was chosen' -TestCases @(
        @{ Format = 'LZ4' }
        @{ Format = 'ZSTD' }
    ) {
        Format-CompressionChoice -Format $Format -Level $null | Should -Be "$Format compression"
        Format-CompressionChoice -Format $Format | Should -Be "$Format compression"
    }

    It 'refuses a format it does not know' {
        { Format-CompressionChoice -Format 'GZIP' -Level 1 } | Should -Throw
    }
}

Describe 'Format-DedupTimeList' {
    It 'reads <Times> as <Expected>' -TestCases @(
        @{ Times = @('11:00');                   Expected = '11:00' }
        @{ Times = @('11:00', '17:00');          Expected = '11:00 and 17:00' }
        @{ Times = @('08:15', '11:00', '17:00'); Expected = '08:15, 11:00 and 17:00' }
    ) {
        Format-DedupTimeList -Times $Times | Should -Be $Expected
    }

    It 'throws for an empty array' {
        { Format-DedupTimeList -Times @() } | Should -Throw
    }
}

Describe 'Resolve-DedupModeCapability' {
    It 'says <Mode> compresses: <Compresses>, and deduplicates blocks: <Blocks>' -TestCases @(
        @{ Mode = 'Dedup'; Compresses = $false; Blocks = $true }
        @{ Mode = 'DedupAndCompress'; Compresses = $true; Blocks = $true }
        @{ Mode = 'Compress'; Compresses = $true; Blocks = $false }
    ) {
        $capability = Resolve-DedupModeCapability -Mode $Mode
        $capability.UsesCompression | Should -Be $Compresses
        $capability.UsesBlockDedup | Should -Be $Blocks
    }

    It 'refuses a mode that is not one of the three' {
        { Resolve-DedupModeCapability -Mode 'Everything' } | Should -Throw
    }
}

Describe 'Format-DedupDailyJobNote' {
    It 'names the duration and the CPU share where both apply' {
        Format-DedupDailyJobNote -DurationHours 3 -CpuPercent 45 -BlockDedup |
            Should -Be 'The daily job runs on mains power only, for up to 3 hours, using at most 45% of the CPU.'
    }

    It 'promises neither where Windows takes neither' {
        # Measured on a compression-only volume: the CPU share is refused and the duration is
        # accepted and dropped, so naming either of them would be a promise the run cannot keep.
        $line = Format-DedupDailyJobNote -DurationHours 3 -CpuPercent 45
        $line | Should -Match 'no time limit and no CPU share'
        $line | Should -Not -Match '3 hours'
        $line | Should -Not -Match '45'
    }

    It 'keeps the mains power condition either way' {
        # That one is set through Task Scheduler afterwards, so it holds whatever the mode is.
        foreach ($line in (Format-DedupDailyJobNote -DurationHours 2 -CpuPercent 60 -BlockDedup),
            (Format-DedupDailyJobNote -DurationHours 2 -CpuPercent 60)) {
            $line | Should -Match 'mains power only'
        }
    }
}

Describe 'Format-DedupScheduleSummary' {
    It 'names the days, the daily times, the weekly day and its start' {
        $lines = Format-DedupScheduleSummary -DailyTimes @('11:00', '17:00') -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -WeeklyJob
        $lines.Count | Should -Be 2
        $lines[0] | Should -Be '  Daily optimization : Monday-Friday at 11:00 and 17:00'
        $lines[1] | Should -Be '  Weekly maintenance : Monday at 17:30, every 1 week'
    }

    It 'shows the times the user chose rather than the defaults' {
        $lines = Format-DedupScheduleSummary -DailyTimes @('08:15', '13:00') -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Saturday' -WeeklyStart '09:00' -WeeksInterval 1 -WeeklyJob
        $lines[0] | Should -Match '08:15 and 13:00'
        $lines[1] | Should -Match 'Saturday at 09:00'
    }

    It 'says weeks in the plural for an interval above one' {
        $lines = Format-DedupScheduleSummary -DailyTimes @('11:00') -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 2 -WeeklyJob
        $lines[1] | Should -Match 'every 2 weeks'
    }

    It 'promises no weekly maintenance where Windows will schedule none' {
        # @(): one line comes back as a bare string, and strict mode refuses .Count on one of those.
        $lines = @(Format-DedupScheduleSummary -DailyTimes @('11:00', '17:00') -DailyDaysLabel 'Monday-Friday' `
                -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1)
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be '  Daily optimization : Monday-Friday at 11:00 and 17:00'
    }

    It 'needs no weekly day at all when there is no weekly job' {
        { Format-DedupScheduleSummary -DailyTimes @('11:00') -DailyDaysLabel 'Monday-Friday' } |
            Should -Not -Throw
    }
}

Describe 'Resolve-DedupScheduleReminder' {
    BeforeAll {
        $script:TreePath = 'Task Scheduler Library > Microsoft > Windows > ReFsDedupSvc'
    }

    It 'names the times just chosen so the right task can be found by its Triggers column' {
        $lines = (Resolve-DedupScheduleReminder -DailyTimes @('08:15', '13:00') -WeeklyDay 'Monday' `
                -WeeklyStart '17:30' -TaskTreePath $script:TreePath -WeeklyJob) -join "`n"
        $lines | Should -Match '08:15 and 13:00 daily'
        $lines | Should -Match 'Monday at 17:30 weekly'
    }

    It 'names no weekly time where no weekly task was created' {
        # Naming one sends the user hunting through Task Scheduler for a task that is not there.
        $lines = (Resolve-DedupScheduleReminder -DailyTimes @('08:15', '13:00') -WeeklyDay 'Monday' `
                -WeeklyStart '17:30' -TaskTreePath $script:TreePath) -join "`n"
        $lines | Should -Match '08:15 and 13:00 daily\.'
        $lines | Should -Not -Match 'weekly'
        $lines | Should -Not -Match '17:30'
    }

    It 'gives the folder location, the admin steps and the Actions tab warning' {
        $lines = (Resolve-DedupScheduleReminder -DailyTimes @('11:00', '17:00') -WeeklyDay 'Monday' `
                -WeeklyStart '17:30' -TaskTreePath $script:TreePath) -join "`n"
        $lines | Should -Match ([regex]::Escape($script:TreePath))
        $lines | Should -Match 'taskschd\.msc'
        $lines | Should -Match 'Ctrl\+Shift\+Enter'
        $lines | Should -Match 'Triggers tab'
        $lines | Should -Match 'Leave the Actions tab alone'
        $lines | Should -Match 'may belong to Windows or to earlier runs'
    }

    It 'returns plain lines rather than an object to unwrap' {
        Resolve-DedupScheduleReminder -DailyTimes @('11:00') -WeeklyDay 'Monday' -WeeklyStart '17:30' `
            -TaskTreePath $script:TreePath | Should -BeOfType [string]
    }
}

Describe 'Request-DedupSchedule' {
    BeforeAll {
        # The menu text is not under test here, only what the answers do to the three fields.
        Mock Write-Host { }
    }

    It 'keeps the offered times when the user takes them' {
        Mock Read-Host { '1' }
        $chosen = Request-DedupSchedule -DailyTimes @('11:00', '17:00') -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -DailyDurationHours 2 -DailyCpuPercent 60 -BlockDedup
        $chosen.DailyTimes | Should -Be @('11:00', '17:00')
        $chosen.WeeklyDay | Should -Be 'Monday'
        $chosen.WeeklyStart | Should -Be '17:30'
    }

    It 'takes the three answers when the user picks the times' {
        $script:answers = @('2', '08:15,13:00', 'sat', '9:00')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        $chosen = Request-DedupSchedule -DailyTimes @('11:00', '17:00') -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -DailyDurationHours 2 -DailyCpuPercent 60 -BlockDedup
        $chosen.DailyTimes | Should -Be @('08:15', '13:00')
        $chosen.WeeklyDay | Should -Be 'Saturday'
        $chosen.WeeklyStart | Should -Be '09:00'
    }

    It 'keeps each current value when the answer is empty' {
        $script:answers = @('2', '', '', '')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        $chosen = Request-DedupSchedule -DailyTimes @('11:00', '17:00') -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -DailyDurationHours 2 -DailyCpuPercent 60 -BlockDedup
        $chosen.DailyTimes | Should -Be @('11:00', '17:00')
        $chosen.WeeklyDay | Should -Be 'Monday'
        $chosen.WeeklyStart | Should -Be '17:30'
    }

    It 'keeps asking until each answer is one it can use' {
        $script:answers = @('9', '2', '11:00,11:00', 'noon', '08:15', 'someday', 'Tue', '99:99', '7:30')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        $chosen = Request-DedupSchedule -DailyTimes @('11:00', '17:00') -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -DailyDurationHours 2 -DailyCpuPercent 60 -BlockDedup
        $chosen.DailyTimes | Should -Be @('08:15')
        $chosen.WeeklyDay | Should -Be 'Tuesday'
        $chosen.WeeklyStart | Should -Be '07:30'
        $script:index | Should -Be 9
    }

    It 'rejects too many daily times and asks again' {
        $script:answers = @('2', '1:00,2:00,3:00,4:00,5:00', '08:15', 'Tue', '07:30')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        $chosen = Request-DedupSchedule -DailyTimes @('11:00', '17:00') -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -DailyDurationHours 2 -DailyCpuPercent 60 -BlockDedup
        $chosen.DailyTimes | Should -Be @('08:15')
    }

    It 'gives the real reason for the daily-time cap, not a claim about overlap' {
        $script:answers = @('2', '1:00,2:00,3:00,4:00,5:00', '08:15', 'Tue', '07:30')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        Request-DedupSchedule -DailyTimes @('11:00', '17:00') -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -DailyDurationHours 2 -DailyCpuPercent 60 -BlockDedup |
            Out-Null
        Should -Invoke Write-Host -ParameterFilter {
            $Object -match 'own scheduled task' -and $Object -notmatch 'Overlap'
        }
    }

    It 'says the daily job, not both jobs, run on mains power for a duration and CPU cap it names' {
        Mock Read-Host { '1' }
        Request-DedupSchedule -DailyTimes @('11:00', '17:00') -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -DailyDurationHours 3 -DailyCpuPercent 45 `
            -BlockDedup | Out-Null
        Should -Invoke Write-Host -ParameterFilter {
            $Object -match 'The daily job runs on mains power only, for up to 3 hours, using at most 45% of the CPU\.'
        }
    }

    It 'asks nothing about a weekly job that cannot exist' {
        # Compression only: the user picks the daily times and is never asked for a day or a time
        # for maintenance Windows will refuse to schedule.
        $script:answers = @('2', '08:15,13:00')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        $chosen = Request-DedupSchedule -DailyTimes @('11:00', '17:00') -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -DailyDurationHours 2 -DailyCpuPercent 60
        $chosen.DailyTimes | Should -Be @('08:15', '13:00')
        $script:index | Should -Be 2
    }

    It 'hands back the weekly values it was given when it asked about none' {
        Mock Read-Host { '1' }
        $chosen = Request-DedupSchedule -DailyTimes @('11:00') -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -DailyDurationHours 2 -DailyCpuPercent 60
        $chosen.WeeklyDay | Should -Be 'Monday'
        $chosen.WeeklyStart | Should -Be '17:30'
    }

    It 'promises no time limit and no CPU share where neither applies' {
        Mock Read-Host { '1' }
        Request-DedupSchedule -DailyTimes @('11:00') -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -DailyDurationHours 3 -DailyCpuPercent 45 |
            Out-Null
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'no time limit and no CPU share' }
        Should -Not -Invoke Write-Host -ParameterFilter { $Object -match 'using at most 45%' }
    }
}

Describe 'Resolve-WriteProtectionAdvice' {
    It 'names the drive and says nothing can be written to it' {
        (Resolve-WriteProtectionAdvice -MountPoint 'X:' -VolumeState 'Clear' -PolicyPath 'HKLM:\FVE') -join "`n" |
            Should -Match 'Drive X:.*nothing can be written'
    }

    It 'names the setting as the likely cause once the run has actually read it' {
        # The run reads FDVDenyWriteAccess before the plan now, so this no longer lists suspects.
        $lines = (Resolve-WriteProtectionAdvice -MountPoint 'X:' -VolumeState 'Clear' -WritePolicy 'Deny' -PolicyPath 'HKLM:\FVE') -join "`n"
        $lines | Should -Match 'almost certainly the cause'
        $lines | Should -Not -Match 'may be set to deny'
    }

    It 'tells someone how to encrypt the volume that exists, not to create it again' {
        # The Dev Drive is already there by this point, so a rerun would repeat the creation.
        $lines = (Resolve-WriteProtectionAdvice -MountPoint 'X:' -VolumeState 'Clear' -WritePolicy 'Deny' -PolicyPath 'HKLM:\FVE') -join "`n"
        $lines | Should -Match 'Enable-BitLocker -MountPoint X:'
        $lines | Should -Not -Match 'Run the script again'
    }

    It 'rules the setting out no harder than it read it' {
        # One key was read. That is enough to stop blaming the setting, not enough to acquit it.
        $lines = (Resolve-WriteProtectionAdvice -MountPoint 'X:' -VolumeState 'Clear' -WritePolicy 'Allow' -PolicyPath 'HKLM:\FVE') -join "`n"
        $lines | Should -Match 'does not report that setting as on'
        $lines | Should -Match 'does not look like the cause'
        $lines | Should -Not -Match 'almost certainly'
    }

    It 'keeps the blame conditional only where the setting could not be read' {
        $lines = (Resolve-WriteProtectionAdvice -MountPoint 'X:' -VolumeState 'Clear' -WritePolicy 'Unknown' -PolicyPath 'HKLM:\FVE') -join "`n"
        $lines | Should -Match 'may be set to deny'
        $lines | Should -Match 'If that setting is on'
        $lines | Should -Not -Match 'almost certainly'
    }

    It 'sends an unread setting to the path it was given, and never to PolicyManager' {
        # PolicyManager was empty on the machine that reported this; the effective path had the value.
        $lines = (Resolve-WriteProtectionAdvice -MountPoint 'X:' -VolumeState 'Clear' -WritePolicy 'Unknown' -PolicyPath 'HKLM:\Somewhere') -join "`n"
        $lines | Should -Match "Get-ItemProperty 'HKLM:\\Somewhere' -Name FDVDenyWriteAccess"
        $lines | Should -Not -Match 'PolicyManager'
    }

    It 'assumes the setting was not read when none is passed' {
        (Resolve-WriteProtectionAdvice -MountPoint 'X:' -VolumeState 'Clear' -PolicyPath 'HKLM:\FVE') -join "`n" |
            Should -Match 'may be set to deny'
    }

    It 'rules that setting out when the drive is encrypted, whatever the setting says' {
        foreach ($policy in 'Deny', 'Allow', 'Unknown') {
            $lines = (Resolve-WriteProtectionAdvice -MountPoint 'X:' -VolumeState 'Encrypted' -WritePolicy $policy -PolicyPath 'HKLM:\FVE') -join "`n"
            $lines | Should -Match 'does not explain this'
            $lines | Should -Not -Match 'That is the cause'
        }
    }

    It 'narrows nothing down when the encryption state could not be read' {
        $lines = (Resolve-WriteProtectionAdvice -MountPoint 'X:' -VolumeState 'Unknown' -PolicyPath 'HKLM:\FVE') -join "`n"
        $lines | Should -Match 'could not be read'
        $lines | Should -Not -Match 'deny write access'
    }

    It 'assumes nothing when no state is passed' {
        (Resolve-WriteProtectionAdvice -MountPoint 'X:' -PolicyPath 'HKLM:\FVE') -join "`n" | Should -Match 'could not be read'
    }

    It 'quotes what Windows said when there is a message, and stays silent when there is not' {
        (Resolve-WriteProtectionAdvice -MountPoint 'X:' -VolumeState 'Clear' -Reason 'Media is write-protected' -PolicyPath 'HKLM:\FVE') -join "`n" |
            Should -Match 'Windows said: Media is write-protected'
        (Resolve-WriteProtectionAdvice -MountPoint 'X:' -VolumeState 'Clear' -PolicyPath 'HKLM:\FVE') -join "`n" |
            Should -Not -Match 'Windows said'
    }

    It 'offers the partition read-only check whatever BitLocker is doing' {
        foreach ($state in @('Clear', 'Encrypted', 'Unknown')) {
            (Resolve-WriteProtectionAdvice -MountPoint 'X:' -VolumeState $state -PolicyPath 'HKLM:\FVE') -join "`n" |
                Should -Match 'Get-Partition -DriveLetter X \|'
        }
    }

    It 'says the drive stays and nothing more can be set up, whatever the state' {
        foreach ($state in @('Clear', 'Encrypted', 'Unknown')) {
            $lines = (Resolve-WriteProtectionAdvice -MountPoint 'X:' -VolumeState $state -PolicyPath 'HKLM:\FVE') -join "`n"
            $lines | Should -Match 'Drive X: stays as it is'
            $lines | Should -Match 'Nothing more can be set up'
        }
    }

    It 'returns plain lines rather than an object to unwrap' {
        Resolve-WriteProtectionAdvice -MountPoint 'X:' -VolumeState 'Clear' -PolicyPath 'HKLM:\FVE' |
            Should -BeOfType [string]
    }
}

Describe 'Get-VolumeWriteState' {
    It 'reports a writable location as writable and leaves nothing behind' {
        $result = Get-VolumeWriteState -MountPoint $TestDrive
        $result.Writable | Should -BeTrue
        $result.Reason | Should -BeNullOrEmpty
        Get-ChildItem -LiteralPath $TestDrive -Force | Should -BeNullOrEmpty
    }

    It 'reports a location it cannot write to' {
        (Get-VolumeWriteState -MountPoint (Join-Path $TestDrive 'no-such-folder')).Writable | Should -BeFalse
    }

    It 'gives what Windows said, not the .NET wrapper around it' {
        $reason = (Get-VolumeWriteState -MountPoint (Join-Path $TestDrive 'no-such-folder')).Reason
        $reason | Should -Not -BeNullOrEmpty
        $reason | Should -Not -Match 'Exception calling'
    }
}
