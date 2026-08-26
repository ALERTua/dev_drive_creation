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
    # Kept for the tests that ask the tree questions, so none of them parses the file again.
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) {
        throw "dev_drive.ps1 does not parse: $($parseErrors[0].Message)"
    }
    $ast = $script:Ast

    $functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    foreach ($function in $functions) {
        . ([scriptblock]::Create($function.Extent.Text))
    }

    Initialize-VirtDiskInterop

    # Where the body prints what the plan function decided; several source-order tests anchor on it.
    $script:PlanPrintLoop = 'foreach ($planLine in (Format-CreationPlan'

    $script:ScriptText = Get-Content -Path $script:ScriptPath -Raw

    function Get-ScriptConstant {
        <# The value the body assigns to one top-level constant, so no test carries a copy of it.
           Pattern is the capture for the value; a constant that has moved or gone throws here. #>
        param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Pattern)

        $found = [regex]::Match($script:ScriptText, "(?m)^\`$$Name\s*=\s*$Pattern")
        if (-not $found.Success) { throw "cannot find `$$Name in dev_drive.ps1" }
        return $found.Groups[1].Value
    }

    # Lifted functions do not bring the body's constants, and a literal here would let the two drift.
    $script:FixedDriveWritePolicyPath = Get-ScriptConstant -Name 'FixedDriveWritePolicyPath' -Pattern "'([^']+)'"
    $script:PasswordFloor = [int](Get-ScriptConstant -Name 'PasswordMinLength' -Pattern '(\d+)')
    $script:PasswordCeiling = [int](Get-ScriptConstant -Name 'PasswordMaxLength' -Pattern '(\d+)')

    function Get-ScriptFunction {
        <# One named function of dev_drive.ps1 as a syntax-tree node, so a test can ask about the
           text of that function alone. A whole-file match prints the whole file when it fails. #>
        param([Parameter(Mandatory)][string]$Name)

        $found = @($script:Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $Name
                }, $false))
        if ($found.Count -ne 1) { throw "dev_drive.ps1 defines $($found.Count) functions named $Name" }
        return $found[0]
    }

    function New-PlanAnswerSet {
        <# A complete, valid answer table for one mode, so a test can change the single field it is
           about. Mirrors what the body assembles: a key exists only where its question was asked. #>
        param([Parameter(Mandatory)][ValidateSet('FreeSpace', 'ShrinkDrive', 'Vhdx')][string]$Mode)

        $answers = @{
            Mode                = $Mode
            SizeGB              = 250
            DevDriveLabel       = 'Projects'
            SkipBitLocker       = $false
            WritePolicy         = 'Allow'
            SkipDeduplication   = $false
            BitLockerNotes      = @('a note about BitLocker')
            DedupMode           = 'DedupAndCompress'
            CompressionFormat   = 'ZSTD'
            CompressionLevel    = 2
            DedupStartTime      = '17:00'
            DedupDailyDaysLabel = 'Monday-Friday'
            ScrubDays           = 'Monday'
            ScrubStart          = '17:30'
            ScrubWeeksInterval  = 1
            DedupWeeklyJob      = $true
        }
        if ($Mode -eq 'Vhdx') {
            $answers.VhdxPath = 'D:\dev.vhdx'
            $answers.VhdxDiskType = 'Dynamic'
            $answers.VhdxAutoAttach = $true
            # Deliberately not the script's own default, so a hardcoded GPT cannot pass for this.
            $answers.PartitionStyle = 'MBR'
        } else {
            $answers.DiskNumber = 1
            $answers.DiskName = 'CT4000P3PSSD8'
        }
        if ($Mode -eq 'ShrinkDrive') {
            $answers.DriveLetter = 'D'
            $answers.DriveLabel = 'ALERT'
            $answers.ShrinkGB = 200
            $answers.ShrinkAdjoiningGB = 50
        }
        return $answers
    }

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

    It 'declares each password length bound exactly once, at <Name>' -TestCases @(
        @{ Name = 'the floor'; Variable = 'PasswordMinLength'; Value = 8 }
        # BitLocker refuses past 256 with 0x803100AA, so the ceiling is its number, not a choice.
        @{ Name = 'the ceiling'; Variable = 'PasswordMaxLength'; Value = 256 }
    ) {
        $line = Select-String -Path $script:ScriptPath -Pattern "^\`$$Variable\s*=\s*(\d+)"
        @($line).Count | Should -Be 1
        [int]$line.Matches[0].Groups[1].Value | Should -Be $Value
    }

    It 'writes the password prompt with the bounds interpolated, never with numbers of its own' {
        $reader = Get-ScriptFunction -Name 'Request-StrongPassword'
        # Positive, not a negative against today's wording: a reworded prompt carrying a fresh digit
        # would slip past "does not say 8", and so would a parameter default.
        $reader.Extent.Text | Should -Match '\$MinimumLength-\$MaximumLength printable ASCII chars'
        $reader.Extent.Text | Should -Not -Match '\$M(in|ax)imumLength\s*=\s*\d'
    }

    It 'has one password caller, and it passes the constants rather than numbers' {
        # The tree the file-level BeforeAll already parsed, rather than a fourth parse of the file.
        $ast = $script:Ast
        $calls = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Request-StrongPassword'
                }, $true))
        $calls.Count | Should -Be 1
        # The arguments themselves, so a second caller under any variable name cannot pass a literal.
        $passed = @{}
        for ($i = 1; $i -lt $calls[0].CommandElements.Count - 1; $i++) {
            $element = $calls[0].CommandElements[$i]
            if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                $passed[$element.ParameterName] = $calls[0].CommandElements[$i + 1]
            }
        }
        foreach ($pair in @{ MinimumLength = 'PasswordMinLength'; MaximumLength = 'PasswordMaxLength' }.GetEnumerator()) {
            $passed[$pair.Key] | Should -BeOfType [System.Management.Automation.Language.VariableExpressionAst]
            $passed[$pair.Key].VariablePath.UserPath | Should -Be $pair.Value
        }
    }

    It 'frees the unmanaged password copy in a finally, so a throw cannot leave it behind' {
        # A ZeroFreeBSTR call sitting after the checks instead of in a finally leaks the plaintext
        # on every path that throws in between, which is exactly the defect this replaced.
        # The tree the file-level BeforeAll already parsed, rather than a fourth parse of the file.
        $ast = $script:Ast
        $tries = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.TryStatementAst] -and
                    $node.Finally -and
                    $node.Finally.Extent.Text -match 'ZeroFreeBSTR'
                }, $true))
        $tries.Count | Should -Be 1
        # The conversion must sit in the guarded body, not before the try where nothing frees it.
        $tries[0].Body.Extent.Text | Should -Match '::PtrToStringBSTR\('
        # And the pointer must be taken outside it: a throw from that call with it inside would hand
        # the finally the previous pass's pointer, freeing it twice.
        $tries[0].Body.Extent.Text | Should -Not -Match '::SecureStringToBSTR\('
        # The managed copy is released in the same place, so neither survives the loop.
        $tries[0].Finally.Extent.Text | Should -Match '\$plain\s*=\s*\$null'
        # The call form, and only within the function: the Auto variant reads to the first null
        # instead of taking the BSTR length prefix, and a whole-file match would print the file.
        $reader = Get-ScriptFunction -Name 'Request-StrongPassword'
        $reader.Extent.Text | Should -Not -Match '::PtrToStringAuto\('
        # The rule function tests none of its patterns with an operator: -match and -notmatch are
        # case-insensitive, which is the original defect, and they copy what matched into $Matches -
        # for the ASCII pattern that copy is the whole password.
        $rule = Get-ScriptFunction -Name 'Resolve-UnmetPasswordRequirement'
        # One per pattern rule: printable ASCII, uppercase, lowercase, digit, special.
        @([regex]::Matches($rule.Extent.Text, '\[regex\]::IsMatch\(')).Count | Should -Be 5
        # The operators by node, not by text: the comment above them names the ones being avoided.
        @($rule.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.BinaryExpressionAst] -and
                    $node.Operator.ToString() -match '^(I|C)not?match$'
                }, $true)).Count | Should -Be 0
    }

    It 'disposes the refused attempt inside the loop, after the accepted one has left' {
        # By position in the loop body, not by text offset: an IndexOf that finds nothing answers
        # -1, and -1 is less than any real offset, so a reworded return would pass this silently.
        $loop = @((Get-ScriptFunction -Name 'Request-StrongPassword').FindAll({
                    param($node) $node -is [System.Management.Automation.Language.WhileStatementAst]
                }, $true))
        $loop.Count | Should -Be 1
        $statements = @($loop[0].Body.Statements)
        $disposeAt = [array]::FindIndex($statements, [Predicate[object]] { $args[0].Extent.Text -match '\$secure\.Dispose\(\)' })
        $returnAt = [array]::FindIndex($statements, [Predicate[object]] { $args[0].Extent.Text -match 'return \$secure' })
        $disposeAt | Should -BeGreaterThan 0
        $returnAt | Should -BeGreaterThan 0
        $disposeAt | Should -BeGreaterThan $returnAt
    }

    It 'disposes the attempt BitLocker refused before the retry asks for another' {
        # The prompt loop is not the whole story: the BitLocker loop comes back to the same line and
        # would otherwise leave one SecureString per attempt alive for the rest of the run.
        $calls = @($script:Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Request-StrongPassword'
                }, $true))
        $calls.Count | Should -Be 1
        $before = $script:ScriptText.Substring(0, $calls[0].Extent.StartOffset)
        $before.LastIndexOf('$SecurePassword.Dispose()') |
            Should -BeGreaterThan $before.LastIndexOf('$SecurePassword = $null')
    }

    It 'wraps the requirement check so an empty answer cannot throw under strict mode' {
        # Measured: return @() arrives as $null and return @('one') as a bare string, so .Count on
        # the bare result throws here. The @() around the call is what makes the count safe.
        # The tree the file-level BeforeAll already parsed, rather than a fourth parse of the file.
        $ast = $script:Ast
        $calls = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Resolve-UnmetPasswordRequirement'
                }, $true))
        $calls.Count | Should -Be 1
        # The exact chain, not any ancestor: a call nested inside some other array expression
        # somewhere up the tree is not the wrap that makes this .Count safe.
        $calls[0].Parent | Should -BeOfType [System.Management.Automation.Language.PipelineAst]
        $calls[0].Parent.Parent | Should -BeOfType [System.Management.Automation.Language.StatementBlockAst]
        $calls[0].Parent.Parent.Parent | Should -BeOfType [System.Management.Automation.Language.ArrayExpressionAst]
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
            '\$DedupStartTime = \$dedupSchedule\.DailyTime\s*\r?\n\s*' +
            '\$ScrubDays = \$dedupSchedule\.WeeklyDay\s*\r?\n\s*' +
            '\$ScrubStart = \$dedupSchedule\.WeeklyStart\s*\r?\n\s*\}')
    }

    It 'builds the plan summary, schedules and reminds using the chosen values, not a literal or a stale default' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $content | Should -Not -Match '\* Schedule daily optimization jobs at 11:00 and 17:00'
        $content | Should -Match 'Format-DedupScheduleSummary -DailyTime \$Answers\.DedupStartTime'
        $content | Should -Match 'Set-ReFSDedupScrubSchedule -Volume "\$devLetterColon" -Days \$ScrubDays -Start \$ScrubStart'
        $content | Should -Match ('(?ms)Resolve-DedupScheduleReminder -DailyTime \$DedupStartTime .*?' +
            '-WeeklyDay \$ScrubDays -WeeklyStart \$ScrubStart .*?' +
            '-TaskNames \$ownTaskNames -VolumeTaskName \$devTaskName')
    }

    # Measured on a scratch disk laid out as A(15) | gap 15 GB | C(5) | tail 25 GB: -UseMaximumSize
    # put the partition in the tail and left the freed 15 GB untouched. So the shrink branch must
    # place its partition itself, and only the .vhdx branch - one disk, one free run, made moments
    # earlier - may still ask for the maximum.
    It 'places the shrink partition itself, and asks for the maximum only inside the vhdx branch' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$null, [ref]$null)

        $calls = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'New-Partition'
                }, $true))
        $calls.Count | Should -BeGreaterThan 1

        foreach ($call in $calls) {
            $parameters = @($call.CommandElements |
                    Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                    ForEach-Object { $_.ParameterName })
            if ($parameters -contains 'UseMaximumSize') {
                # The one allowed use names the virtual disk's own number, nothing else.
                $call.Extent.Text | Should -Match '\$vhdxDiskNumber' -Because 'only the vhdx branch may take the maximum'
            }
            else {
                $parameters | Should -Contain 'Size' -Because 'every other partition is given an explicit size'
            }
        }

        $shrinkCall = @($calls | Where-Object { $_.Extent.Text -match '\$freedOffset' })
        $shrinkCall.Count | Should -Be 1
        @($shrinkCall[0].CommandElements |
                Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                ForEach-Object { $_.ParameterName }) | Should -Contain 'Offset'
    }

    # A text search would pass the moment the loop were spelled differently, so ask the syntax tree.
    # Both shapes count: a loop statement, and the script block ForEach-Object would be handed.
    It 'writes the daily schedule with a single call, from no loop of any shape' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$null, [ref]$null)

        $calls = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Set-ReFSDedupSchedule'
                }, $true))
        $calls.Count | Should -Be 1 -Because 'one volume holds one daily schedule'

        $repeated = $null
        for ($node = $calls[0].Parent; $null -ne $node; $node = $node.Parent) {
            if ($node -is [System.Management.Automation.Language.LoopStatementAst] -or
                $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                $repeated = $node.GetType().Name
                break
            }
        }
        $repeated | Should -BeNullOrEmpty -Because 'a second call would silently discard the first time'
    }

    It 'configures the mains-power condition only after the weekly maintenance job it must cover' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $weeklyAt = $content.IndexOf('Set-ReFSDedupScrubSchedule -Volume "$devLetterColon"')
        $acPowerAt = $content.IndexOf('Configuring the ReFS optimization tasks to run only on mains power')
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

    It 'asks the volume what it stored after the daily schedule and before the weekly one' {
        # After the daily call so there is something to confirm, and before the scrub call: the read
        # takes the first schedule it is given, and a scrub entry in that list would answer instead.
        $content = Get-Content -Path $script:ScriptPath -Raw
        $dailyAt = $content.IndexOf('Set-ReFSDedupSchedule @scheduleParams -ErrorAction Stop')
        $readBackAt = $content.IndexOf('$dedupVerdict = Resolve-DedupReadBackVerdict')
        $scrubAt = $content.IndexOf('Set-ReFSDedupScrubSchedule -Volume "$devLetterColon"')
        $dailyAt | Should -BeGreaterThan 0
        $readBackAt | Should -BeGreaterThan $dailyAt
        $scrubAt | Should -BeGreaterThan $readBackAt
    }

    It 'compares the read-back against what the run asked for, not against literals' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $content | Should -Match ('(?ms)Resolve-DedupReadBackVerdict -MountPoint \$devLetterColon -ExpectedMode \$DedupMode `\s*\r?\n\s*' +
            '-ExpectedFormat \$CompressionFormat -ExpectedLevel \$CompressionLevel -ExpectedStart \$DedupStartTime')
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
        # By call rather than by exact text: the plan now reads its values off the answers table, so
        # a literal match would count two of the three and pass while the third drifted.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$null, [ref]$null)
        $calls = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Format-DedupModeChoice'
                }, $true))
        # Four: the plan, the echo after the question, the initial job, and the read-back verdict.
        $calls.Count | Should -Be 4

        foreach ($call in $calls) {
            $parameters = @($call.CommandElements |
                    Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                    ForEach-Object { $_.ParameterName })
            $parameters | Should -Contain 'Mode'
            $parameters | Should -Contain 'Format'
            $parameters | Should -Contain 'Level'

            # Names alone would let a literal through, which is the stale-default failure. The
            # read-back verdict is the one that legitimately passes the volume's own answer.
            if ($call.Extent.Text -notmatch '\$Actual\.') {
                $call.Extent.Text | Should -Match '(\$DedupMode|\$Answers\.DedupMode)'
                $call.Extent.Text | Should -Match '(\$CompressionFormat|\$Answers\.CompressionFormat)'
                $call.Extent.Text | Should -Match '(\$CompressionLevel|\$Answers\.CompressionLevel)'
            }
        }

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

    It 'asks Task Scheduler for one folder rather than for every task on the machine' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $calls = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Get-ScheduledTask'
                }, $true))
        $calls.Count | Should -Be 1
        $calls[0].Extent.Text | Should -Match '-TaskPath \$DedupTaskPath'
    }

    It 'does not tell its own tasks apart by an English display name' {
        # The excluded task is registered by Windows, and nothing promises that name in one language.
        $content = Get-Content -Path $script:ScriptPath -Raw
        $content | Should -Not -Match '\$_\.TaskName -(ne|eq) "Initialization"'
        $content | Should -Not -Match '\$_\.TaskName -ne'
    }

    It 'changes only the tasks named after the drive it just created' {
        # The folder holds every drive's tasks and the leftovers of volumes that no longer exist, so
        # the set to change has to be narrowed before anything is written.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $picked = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left.Extent.Text -eq '$dedupTasks'
                }, $true))
        $picked.Count | Should -Be 1
        $picked[0].Right.Extent.Text | Should -Match 'Resolve-OwnDedupTask -VolumeTaskName \$devTaskName'

        $owned = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Resolve-OwnDedupTask'
                }, $true))
        $owned.Count | Should -Be 1
    }

    It 'refuses a disk it cannot use from inside the prompt loop, so the answer can be retyped' {
        # The refusal has to sit inside the loop: a `continue` outside one is a runtime error, and
        # ending the run would throw away the mode answer for a disk that was never created.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $guard = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.IfStatementAst] -and
                    $node.Clauses[0].Item1.Extent.Text -match 'Test-DiskStyleSupported -Style \$selectedStyle'
                }, $true))
        $guard.Count | Should -Be 1
        $guardBody = $guard[0].Clauses[0].Item2

        $loops = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.WhileStatementAst] -and
                    $node.Body.Extent.Text -match 'Read-Host "Disk number"'
                }, $true))
        $loops.Count | Should -Be 1
        $guard[0].Extent.StartOffset | Should -BeGreaterThan $loops[0].Extent.StartOffset
        $guard[0].Extent.EndOffset | Should -BeLessThan $loops[0].Extent.EndOffset

        # The reason is printed, and it is the one this change wrote: without this, replacing the
        # message with any other line list leaves every test green over a function nobody calls.
        @($guardBody.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -eq 'Resolve-UnusableDiskAdvice'
                }, $true)).Count | Should -Be 1
        $guardBody.Extent.Text | Should -Match 'Write-Host \$line'
        # The keyword itself, not the word inside SilentlyContinue.
        @($guardBody.FindAll({ param($n) $n -is [System.Management.Automation.Language.ContinueStatementAst] }, $true)).Count |
            Should -Be 1
        @($guardBody.FindAll({ param($n) $n -is [System.Management.Automation.Language.BreakStatementAst] }, $true)).Count |
            Should -Be 0
        $guardBody.Extent.Text | Should -Not -Match '\bexit\b'
    }

    It 'says how to leave, before the first question and again wherever a refusal lands' {
        # A single-disk machine whose one disk is refused has no answer that ends the run, so the way
        # out has to be named rather than assumed. No special answer to type: Ctrl+C already works,
        # and a typed one would need parsing at every prompt to be worth offering at any.
        $content = Get-Content -Path $script:ScriptPath -Raw
        $bannerAt = $content.IndexOf('Press Ctrl+C at any of these questions to leave without changing anything.')
        $bannerAt | Should -BeGreaterThan 0
        # The disk prompt, its invalid-input line, and the refusal the prompt loops back from.
        ([regex]::Matches($content, 'Ctrl\+C to leave')).Count | Should -BeGreaterOrEqual 3
        # Nothing is left promising an answer that no longer exists.
        $content | Should -Not -Match 'X to exit'
    }

    It 'hands the disk list the supported styles, so a live run does not stop asking for them' {
        # Every test passes the parameter explicitly, so only the call site itself can pin this.
        # Dropped, the run halts mid-flight on "Supply values for the following parameters".
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $calls = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Show-DriveSelection'
                }, $true))
        $calls.Count | Should -Be 1
        $calls[0].Extent.Text | Should -Match '-SupportedStyles \$SupportedPartitionStyles'
    }

    It 'judges the disk before accepting it, and long before anything is asked about it' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $checkAt = $content.IndexOf('Test-DiskStyleSupported -Style $selectedStyle')
        $acceptAt = $content.IndexOf('$DiskNumber = $selectedDiskNumber')
        # The first mode-specific question, anchored on code rather than on a comment that may be renamed.
        $firstQuestionAt = $content.IndexOf('if ($mode -eq "FreeSpace") {')
        $checkAt | Should -BeGreaterThan 0
        $acceptAt | Should -BeGreaterThan $checkAt
        $firstQuestionAt | Should -BeGreaterThan $acceptAt
    }

    It 'declares the supported partition styles once, and never repeats the set as a check or a sentence' {
        # The ValidateSet on the initialize style is a different set - what Initialize-Disk accepts -
        # and is deliberately not counted here.
        $content = Get-Content -Path $script:ScriptPath -Raw
        ([regex]::Matches($content, "\`$SupportedPartitionStyles = @\('GPT', 'MBR'\)")).Count | Should -Be 1
        $content | Should -Not -Match "works with GPT and MBR disks only"
        $content | Should -Not -Match "\`$Style -in @\('GPT', 'MBR'\)"
    }

    It 'promises the one initialization it performs, in the plan of the mode that performs it' {
        # The physical modes refuse an uninitialized disk; the .vhdx mode initializes the disk it
        # just created. Asked of the plan itself, rather than of where the branch sits.
        $vhdx = (Format-CreationPlan -Answers (New-PlanAnswerSet -Mode 'Vhdx')).Text -join "`n"
        $vhdx | Should -Match '\* Initialize the new virtual disk with a \w+ partition table'

        foreach ($mode in 'FreeSpace', 'ShrinkDrive') {
            $physical = (Format-CreationPlan -Answers (New-PlanAnswerSet -Mode $mode)).Text -join "`n"
            $physical | Should -Not -Match 'Initialize' -Because "$mode never initializes a disk"
        }

        $content = Get-Content -Path $script:ScriptPath -Raw
        # Promised before it happens, which is the whole point of the plan. Guarded: an IndexOf that
        # finds nothing answers -1, and everything is greater than that.
        $printedAt = $content.IndexOf($script:PlanPrintLoop)
        $printedAt | Should -BeGreaterThan 0
        $content.IndexOf('Initialize-Disk -Number $vhdxDiskNumber') | Should -BeGreaterThan $printedAt
    }

    It 'keeps the partition style in one place rather than beside every use of it' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        ([regex]::Matches($content, "\`$DiskPartitionStyle = 'GPT'")).Count | Should -Be 1
        $content | Should -Not -Match 'Initialize-Disk -Number \$vhdxDiskNumber -PartitionStyle GPT'
    }

    It 'asks a disk for its partitions without treating "it has none" as a fault' {
        # A disk with no partitions makes Get-Partition raise an error record, which lands in the
        # middle of the disk list. It happens on a wiped disk too, not only an uninitialized one.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $lister = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Show-DriveSelection'
                }, $true))
        $lister.Count | Should -Be 1

        $queries = @($lister[0].FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Get-Partition'
                }, $true))
        $queries.Count | Should -BeGreaterThan 0
        foreach ($query in $queries) {
            $query.Extent.Text | Should -Match '-ErrorAction SilentlyContinue'
        }
    }

    It 'refuses to touch any task when the volume would not say which are its own' {
        # Changing tasks that cannot be shown to be this drive's is worse than changing none.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $guard = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.IfStatementAst] -and
                    $node.Clauses[0].Item1.Extent.Text -match '\$devTaskName' -and
                    $node.Clauses[0].Item2.Extent.Text -match 'throw'
                }, $true))
        $guard.Count | Should -Be 1
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
        $printedAt = $content.IndexOf($script:PlanPrintLoop)
        $planLine | Should -BeGreaterThan 0
        $printedAt | Should -BeGreaterThan $planLine
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
        $planAt = $content.IndexOf($script:PlanPrintLoop)
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

    It 'states the setting in the plan when BitLocker is being skipped, for <Policy>' -TestCases @(
        @{ Policy = 'Deny' }
        @{ Policy = 'Unknown' }
    ) {
        # The highest-stakes line on the consent screen: it says the drive will mount read-only and
        # the run will stop. Nothing exists yet at that point, so it can still be declined over.
        $answers = New-PlanAnswerSet -Mode 'FreeSpace'
        $answers.SkipBitLocker = $true
        $answers.Remove('BitLockerNotes')
        $answers.WritePolicy = $Policy

        $expected = @(Resolve-WriteAccessPolicyAdvice -Policy $Policy -Skipping)
        $expected.Count | Should -BeGreaterThan 0 -Because "$Policy has something to warn about"

        $lines = @(Format-CreationPlan -Answers $answers)
        foreach ($advice in $expected) {
            $carried = @($lines | Where-Object { $_.Text -eq "  - $advice" })
            $carried.Count | Should -Be 1 -Because 'every line of the advice reaches the plan'
            $carried[0].Colour | Should -Be 'Yellow'
        }
    }

    It 'says nothing about write access where the setting allows it' {
        $answers = New-PlanAnswerSet -Mode 'FreeSpace'
        $answers.SkipBitLocker = $true
        $answers.Remove('BitLockerNotes')
        (Format-CreationPlan -Answers $answers).Text -join "`n" | Should -Not -Match 'read-only'
    }

    It 'never names a cause for a refused password that it did not establish' {
        # Three of the four refusals are not about complexity. The verdict function is covered by
        # its own tests; this pins the one line they cannot see - the last thing printed before the
        # run exits, which lives at the call site. Scoped to the throw so that rewording the
        # password prompt, which may legitimately discuss complexity, does not trip it.
        $throws = @(Select-String -Path $script:ScriptPath -Pattern '^\s*throw "' | ForEach-Object { $_.Line })
        @($throws | Where-Object { $_ -match 'complexity' }) | Should -BeNullOrEmpty
        @($throws | Where-Object { $_ -match 'did not accept the password' }).Count | Should -Be 1
    }

    It 'never works out free space by summing the partitions it likes the look of' {
        # Counting only Basic-or-lettered partitions reported 2.22 GB free on a disk that had none.
        ([regex]::Matches((Get-Content -Path $script:ScriptPath -Raw), '\$allocatedSize')).Count |
            Should -Be 0
    }

    It 'lets no free-space figure come from anywhere but the disk itself' {
        # Three copies of the arithmetic are how they came to disagree with the disk. Not a count of
        # call sites - a rule about where every one of these two variables may get its value.
        $lines = @(Select-String -Path $script:ScriptPath -Pattern '^\s*\$freeSpace(GB)?\s*=' |
                ForEach-Object { $_.Line.Trim() })
        $lines.Count | Should -Be 5
        @($lines | Where-Object { $_ -match '^\$freeSpace\s*=' -and $_ -notmatch 'Get-DiskLargestFreeExtent' }) |
            Should -BeNullOrEmpty
        @($lines | Where-Object { $_ -match '^\$freeSpaceGB\s*=' -and $_ -notmatch 'ConvertTo-FlooredGB' }) |
            Should -BeNullOrEmpty
        ([regex]::Matches((Get-Content -Path $script:ScriptPath -Raw), '(?m)^function Get-DiskLargestFreeExtent')).Count |
            Should -Be 1
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

    It 'decides the resize with the sizes Windows reported for that very partition' {
        # Without this the function could be tested to perfection and still be handed the wrong
        # arguments - a literal minimum, or the current size passed as the maximum.
        $content = Get-Content -Path $script:ScriptPath -Raw
        $content | Should -Match ('(?ms)\$shrinkPlan = Resolve-ShrinkPlan -CurrentSize \$partitionInfo\.Size -MaxSize \$maxSize `\s*\r?\n\s*' +
            '-MinSize \$minSize -ShrinkBytes \(ConvertTo-ByteCount -GB \$ShrinkGB\)')
        $minBoundAt = $content.IndexOf('$minSize = $supportedSizes.SizeMin')
        $guardAt = $content.IndexOf('if ($shrinkPlan.Rejection) {', $minBoundAt)
        $resizeAt = $content.IndexOf('Resize-Partition -DiskNumber $diskNum')
        $minBoundAt | Should -BeGreaterThan 0
        $guardAt | Should -BeGreaterThan $minBoundAt
        $resizeAt | Should -BeGreaterThan $guardAt
    }

    It 'ends the run on a plain refusal, not a throw, when the numbers do not allow the shrink' {
        # The guard fires before Resize-Partition ever runs, so this must not fall into the catch
        # that would otherwise warn a shrink already happened.
        $content = Get-Content -Path $script:ScriptPath -Raw
        $minBoundAt = $content.IndexOf('$minSize = $supportedSizes.SizeMin')
        $guardAt = $content.IndexOf('if ($shrinkPlan.Rejection) {', $minBoundAt)
        $blockEnd = $content.IndexOf('Write-Host "Resizing Partition')
        $guardAt | Should -BeGreaterThan 0
        $guardBlock = $content.Substring($guardAt, $blockEnd - $guardAt)
        $guardBlock | Should -Not -Match 'throw'
        $guardBlock | Should -Match 'exit 1'
    }

    It 'hands that refusal the Windows minimum, rounded the safe way, and never a rejection name' {
        # Ceilinged, not floored: a floored minimum would name a size Windows still refuses.
        $content = Get-Content -Path $script:ScriptPath -Raw
        $minBoundAt = $content.IndexOf('$minSize = $supportedSizes.SizeMin')
        $guardAt = $content.IndexOf('if ($shrinkPlan.Rejection) {', $minBoundAt)
        $blockEnd = $content.IndexOf('Write-Host "Resizing Partition')
        $guardBlock = $content.Substring($guardAt, $blockEnd - $guardAt)
        $guardBlock | Should -Match 'Format-ShrinkRefusal -DriveLetter \$DriveLetter -ShrinkGB \$ShrinkGB -Rejection \$shrinkPlan\.Rejection'
        $guardBlock | Should -Match 'ConvertTo-CeilingedGB -Bytes \$minSize'
        $guardBlock | Should -Not -Match '\$\(\$shrinkPlan\.Rejection\)'
    }

    It 'shows the resize target and its sizes with the rounding helpers, not a bare Math.Round' {
        # Scoped to the try block's resize section, not the earlier drive-selection prompt, which
        # has its own bare Round calls outside this change's reach. Ends at the creation call so the
        # size printed just above it stays inside the region this guards.
        $content = Get-Content -Path $script:ScriptPath -Raw
        $blockStart = $content.IndexOf('# Use stored partition information to avoid redundant API calls')
        $blockEnd = $content.IndexOf('$newPart = New-Partition -DiskNumber $diskNum -Offset')
        $blockStart | Should -BeGreaterThan 0
        $blockEnd | Should -BeGreaterThan $blockStart
        $block = $content.Substring($blockStart, $blockEnd - $blockStart)
        $block | Should -Not -Match '\[math\]::Round\([^)]*/ 1GB, 2\)'
    }

    It 'derives where and how big the new partition is from the read-back, not from the prediction' {
        # Alignment can leave the partition a little off the target, and the offset written to disk
        # has to be where the partition actually ends.
        $content = Get-Content -Path $script:ScriptPath -Raw
        $content | Should -Match '\$shrunkPart = Get-Partition -DiskNumber \$diskNum -PartitionNumber \$partitionInfo\.PartitionNumber'
        $content | Should -Match ('(?ms)Resolve-AlignedPlacement -Offset \(\$shrunkPart\.Offset \+ \$shrunkPart\.Size\) `\s*\r?\n\s*' +
            '-Size \(\$maxSize - \$shrunkPart\.Size\)')
        $content | Should -Not -Match 'Resolve-AlignedPlacement -Offset .*\$shrinkPlan\.'
    }

    It 'aligns the start before New-Partition, because an offset off a megabyte is refused outright' {
        # Measured: five non-round shrink amounts produced five unaligned offsets, and every one was
        # refused - after the volume had already been shrunk.
        $content = Get-Content -Path $script:ScriptPath -Raw
        $guardAt = $content.IndexOf('if ($shrunkPart.Size -gt $maxSize) {')
        $alignAt = $content.IndexOf('$placement = Resolve-AlignedPlacement -Offset')
        $offsetAt = $content.IndexOf('$freedOffset = $placement.Offset')
        $createAt = $content.IndexOf('$newPart = New-Partition -DiskNumber $diskNum -Offset')
        $guardAt | Should -BeGreaterThan 0
        $alignAt | Should -BeGreaterThan $guardAt
        $offsetAt | Should -BeGreaterThan $alignAt
        $createAt | Should -BeGreaterThan $offsetAt
    }

    It 'names the adjoining space after the refusal and before the question, never before both' {
        # Before the refusal it would promise a drive the very next line turns down; after the
        # question it would come too late to inform the number.
        $content = Get-Content -Path $script:ScriptPath -Raw
        $refuseAt = $content.IndexOf('below the $DevDriveMinSizeGB GB minimum required for a Dev Drive')
        $measureAt = $content.IndexOf('$ShrinkAdjoiningGB = ConvertTo-FlooredGB -Bytes ($supportedSizes.SizeMax - $partitionInfo.Size)')
        $noteAt = $content.IndexOf('Format-ShrinkAdjoiningNote -DriveLetter $DriveLetter')
        $askAt = $content.IndexOf("Request-DevDriveSizeGB -MaxGB `$realMaxShrinkableGB -Subject 'Shrink amount'")
        $refuseAt | Should -BeGreaterThan 0
        $measureAt | Should -BeGreaterThan $refuseAt
        $noteAt | Should -BeGreaterThan $measureAt
        $askAt | Should -BeGreaterThan $noteAt
    }

    # The headline behaviour: without this the plan could quietly go back to naming the amount
    # freed, every existing test would stay green, and the note would read "comes out 200 GB
    # rather than the 200 GB being freed".
    It 'plans the drive at the size the shrink decision gives, not at the amount freed' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $content | Should -Match ('(?ms)\$shrinkPlan = Resolve-ShrinkPlan -CurrentSize \$partitionInfo\.Size ' +
            '-MaxSize \$supportedSizes\.SizeMax `\s*\r?\n\s*-MinSize \$supportedSizes\.SizeMin ' +
            '-ShrinkBytes \(ConvertTo-ByteCount -GB \$ShrinkGB\)')
        $content | Should -Match '\$SizeGB = ConvertTo-FlooredGB -Bytes \$shrinkPlan\.DevDriveBytes'
    }

    It 'refuses a drive that came out below the minimum, rather than only reporting its size' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $floorAt = $content.IndexOf('if ($freedSize -lt ($DevDriveMinSizeGB * 1GB)) {')
        $createAt = $content.IndexOf('$newPart = New-Partition -DiskNumber $diskNum -Offset')
        $floorAt | Should -BeGreaterThan 0
        $createAt | Should -BeGreaterThan $floorAt
    }

    It 'says so when the space behind the drive did not come to what the plan named' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        # Compared at the precision the two are shown in, so the megabyte the alignment takes back
        # cannot make every single run announce a discrepancy nobody can see.
        $content | Should -Match '\(ConvertTo-FlooredGB -Bytes \$freedSize\) -ne \(ConvertTo-FlooredGB -Bytes \$shrinkPlan\.DevDriveBytes\)'
        $content | Should -Match 'not the \$\(ConvertTo-FlooredGB -Bytes \$shrinkPlan\.DevDriveBytes\) GB the plan named'
    }

    It 'warns about the extra space in the plan, before the question that asks to proceed' {
        # The whole point of the change: the user is told the drive comes out larger, and told it
        # while there is still something to say no to.
        $plan = (Format-CreationPlan -Answers (New-PlanAnswerSet -Mode 'ShrinkDrive')).Text -join "`n"
        $plan | Should -Match 'will be taken'
        $plan | Should -Match 'rather than the .* GB being freed'

        $content = Get-Content -Path $script:ScriptPath -Raw
        $planAt = $content.IndexOf($script:PlanPrintLoop)
        $confirmAt = $content.IndexOf('Are you ready to proceed')
        $planAt | Should -BeGreaterThan 0
        $confirmAt | Should -BeGreaterThan $planAt
    }

    It 'says the size is approximate where the adjoining space could not be measured' {
        # That branch knows the drive will differ and cannot say by how much, so it must not print
        # the number as though it were the answer. Not "at least", either: alignment can leave the
        # partition a little off the target, so the figure is not a floor.
        $answers = New-PlanAnswerSet -Mode 'ShrinkDrive'
        $answers.ShrinkAdjoiningGB = $null
        $plan = (Format-CreationPlan -Answers $answers).Text -join "`n"
        $plan | Should -Match 'About this much, and likely more'
        $plan | Should -Match 'could not be measured beforehand'
        $plan | Should -Not -Match 'will be taken' -Because 'no figure is known to name'
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

Describe 'Format-CreationPlan' {
    # The screen that asks for consent; nothing below it could be tested until it became a function.
    It 'names in the <Mode> plan only what that mode does' -TestCases @(
        @{ Mode = 'Vhdx';        Absent = @('on Disk', 'Shrink Drive') }
        @{ Mode = 'FreeSpace';   Absent = @('virtual hard disk', 'Shrink Drive', 'mounted on every Windows startup') }
        @{ Mode = 'ShrinkDrive'; Absent = @('virtual hard disk', 'mounted on every Windows startup') }
    ) {
        $plan = (Format-CreationPlan -Answers (New-PlanAnswerSet -Mode $Mode)).Text -join "`n"
        foreach ($phrase in $Absent) {
            $plan | Should -Not -Match ([regex]::Escape($phrase)) -Because "$Mode does not do that"
        }
    }

    It 'says a skipped step is skipped, rather than leaving it out' {
        $answers = New-PlanAnswerSet -Mode 'FreeSpace'
        $answers.SkipBitLocker = $true
        $answers.Remove('BitLockerNotes')
        $answers.SkipDeduplication = $true
        $plan = (Format-CreationPlan -Answers $answers).Text -join "`n"
        $plan | Should -Match '\* Skip BitLocker encryption'
        $plan | Should -Match '\* Skip deduplication and compression setup'
        $plan | Should -Not -Match '\* Enable BitLocker'
        $plan | Should -Not -Match '\* Enable ReFS'
    }

    It 'names the size, the label and the disk that were answered, not a literal' {
        $answers = New-PlanAnswerSet -Mode 'FreeSpace'
        $answers.SizeGB = 512
        $answers.DevDriveLabel = 'Bench'
        $answers.DiskNumber = 7
        $answers.DiskName = 'SOME DISK'
        $plan = (Format-CreationPlan -Answers $answers).Text -join "`n"
        $plan | Should -Match '\* Create 512 GB Dev Drive on Disk 7 \(SOME DISK\) using ReFS'
        $plan | Should -Match '\* Name the Dev Drive Bench'
    }

    It 'warns about the extra space only where a shrink brought it' {
        (Format-CreationPlan -Answers (New-PlanAnswerSet -Mode 'ShrinkDrive')).Text -join "`n" |
            Should -Match '50 GB of unallocated space already sits next to drive D:'
        (Format-CreationPlan -Answers (New-PlanAnswerSet -Mode 'FreeSpace')).Text -join "`n" |
            Should -Not -Match 'already sits next to'
    }

    It 'says which way the virtual disk will be mounted, whichever way that is' {
        $answers = New-PlanAnswerSet -Mode 'Vhdx'
        (Format-CreationPlan -Answers $answers).Text -join "`n" |
            Should -Match 'Register the virtual disk to be mounted on every Windows startup'
        $answers.VhdxAutoAttach = $false
        (Format-CreationPlan -Answers $answers).Text -join "`n" |
            Should -Match 'Skip automatic mounting'
    }

    It 'warns about the wait only for the disk type that makes you wait' {
        $answers = New-PlanAnswerSet -Mode 'Vhdx'
        $answers.VhdxDiskType = 'Fixed'
        (Format-CreationPlan -Answers $answers).Text -join "`n" | Should -Match 'claims all of its space up front'
        $answers.VhdxDiskType = 'Dynamic'
        (Format-CreationPlan -Answers $answers).Text -join "`n" | Should -Not -Match 'claims all of its space up front'
    }

    It 'ends every mode with the two steps that always run' {
        foreach ($mode in 'FreeSpace', 'ShrinkDrive', 'Vhdx') {
            $plan = (Format-CreationPlan -Answers (New-PlanAnswerSet -Mode $mode)).Text -join "`n"
            $plan | Should -Match '\* Mark Dev Drive as trusted for Windows Defender performance'
            $plan | Should -Match '\* Run initial optimization job to prepare the drive'
        }
    }

    It 'gives each kind of line the colour that kind is printed in' {
        # Not merely "a colour": the warning that turns yellow into white stops being a warning.
        $answers = New-PlanAnswerSet -Mode 'ShrinkDrive'
        $answers.VhdxDiskType = 'Fixed'
        $lines = @(Format-CreationPlan -Answers $answers)
        $lines.Count | Should -BeGreaterThan 10

        $colourOf = { param($pattern)
            $found = @($lines | Where-Object { $_.Text -match $pattern })
            $found.Count | Should -BeGreaterThan 0 -Because "the plan should carry $pattern"
            return $found[0].Colour
        }
        (& $colourOf 'DEV DRIVE CREATION PLAN') | Should -Be 'Cyan'
        (& $colourOf '^\* Create ') | Should -Be 'White'
        (& $colourOf 'already sits next to') | Should -Be 'Yellow'
        (& $colourOf '^  - a note about BitLocker') | Should -Be 'Gray'
    }

    It 'refuses a colour that is not one, rather than failing halfway through printing' {
        { New-PlanLine -Text 'x' -Colour 'Purpel' } | Should -Throw
    }

    It 'opens and closes with the banner, so the plan reads as one block' {
        $lines = @(Format-CreationPlan -Answers (New-PlanAnswerSet -Mode 'FreeSpace'))
        $lines[1].Text | Should -Match 'DEV DRIVE CREATION PLAN'
        $lines[0].Text | Should -Be $lines[-1].Text
    }

    It 'refuses a mode it has no plan for, rather than falling into the physical branch' {
        $answers = New-PlanAnswerSet -Mode 'FreeSpace'
        $answers.Mode = 'SomethingNew'
        { Format-CreationPlan -Answers $answers } | Should -Throw
    }

    It 'names the file, the size and the type of a virtual disk it is about to create' {
        $answers = New-PlanAnswerSet -Mode 'Vhdx'
        $answers.VhdxPath = 'E:\somewhere\dev.vhdx'
        $answers.SizeGB = 300
        $answers.VhdxDiskType = 'Fixed'
        (Format-CreationPlan -Answers $answers).Text -join "`n" |
            Should -Match ([regex]::Escape('* Create a 300 GB Fixed virtual hard disk at E:\somewhere\dev.vhdx'))
    }

    It 'names the drive it is about to shrink, by letter and by label' {
        $answers = New-PlanAnswerSet -Mode 'ShrinkDrive'
        $answers.DriveLetter = 'Q'
        $answers.DriveLabel = 'Scratch'
        $answers.ShrinkGB = 123
        (Format-CreationPlan -Answers $answers).Text -join "`n" |
            Should -Match '\* Shrink Drive Q \(Scratch\) by 123 GB to free up space'
    }

    It 'takes the partition table it was told about, not the one it was written beside' {
        # The fixture deliberately answers MBR while the script's own default is GPT.
        (Format-CreationPlan -Answers (New-PlanAnswerSet -Mode 'Vhdx')).Text -join "`n" |
            Should -Match '\* Initialize the new virtual disk with a MBR partition table'
    }

    It 'reads exactly the keys the run assembles, no more and no fewer' {
        # Three lists that have to agree: what the body sets, what the function reads, and what the
        # fixture builds. Left to drift, the fixture keeps the tests green while a real run throws
        # at the consent screen, after the whole interview.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$null, [ref]$null)
        $function = $ast.FindAll({ param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Format-CreationPlan' }, $false)[0]

        $read = @([regex]::Matches($function.Extent.Text, '\$Answers\.([A-Za-z]+)') |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $read.Count | Should -BeGreaterThan 10

        $body = $ast.Extent.Text.Substring($ast.Extent.Text.IndexOf('$planAnswers = @{'))
        $body = $body.Substring(0, $body.IndexOf('foreach ($planLine in (Format-CreationPlan'))
        $set = @(([regex]::Matches($body, '(?m)^\s*([A-Za-z]+)\s*=') |
                    ForEach-Object { $_.Groups[1].Value }) +
            ([regex]::Matches($body, '\$planAnswers\.([A-Za-z]+)\s*=') |
                ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique)

        $fixture = @((New-PlanAnswerSet -Mode 'Vhdx').Keys + (New-PlanAnswerSet -Mode 'ShrinkDrive').Keys |
                Sort-Object -Unique)

        Compare-Object $read $set | Should -BeNullOrEmpty -Because 'the run sets what the plan reads'
        Compare-Object $read $fixture | Should -BeNullOrEmpty -Because 'the fixture answers what the plan reads'
    }
}

Describe 'Resolve-ShrinkPlan' {
    # SizeMax is the partition's size plus the unallocated space right behind it - measured on a
    # scratch disk, where a 20 GB partition with a 10 GB gap behind it reported SizeMax 30 GB.
    It 'takes the amount asked for off the partition, and hands the drive the whole free run behind it' {
        # Drive D is 1000 GB with 50 GB unallocated next to it; the user frees 200 GB.
        $plan = Resolve-ShrinkPlan -CurrentSize 1000GB -MaxSize 1050GB -MinSize 300GB -ShrinkBytes 200GB
        $plan.Rejection | Should -BeNullOrEmpty
        $plan.TargetBytes | Should -Be 800GB -Because 'the partition gives up exactly what was asked for'
        $plan.DevDriveBytes | Should -Be 250GB -Because 'the 200 GB freed plus the 50 GB already there'
        $plan.AdjoiningBytes | Should -Be 50GB
    }

    # Measured end to end on a USB disk laid out as shrinkme(40) | gap 4 | part(5) | tail 70.23:
    # freeing 6 GB left the volume at 34 GB and produced a 10 GB partition right behind it.
    It 'matches what a real disk did, including that the far larger tail was not what it measured' {
        $plan = Resolve-ShrinkPlan -CurrentSize 40GB -MaxSize 44GB -MinSize 3.05GB -ShrinkBytes 6GB
        $plan.TargetBytes | Should -Be 34GB
        $plan.DevDriveBytes | Should -Be 10GB
        $plan.AdjoiningBytes | Should -Be 4GB
    }

    It 'hands the drive exactly the amount freed when nothing adjoins the partition' {
        $plan = Resolve-ShrinkPlan -CurrentSize 1000GB -MaxSize 1000GB -MinSize 300GB -ShrinkBytes 200GB
        $plan.TargetBytes | Should -Be 800GB
        $plan.DevDriveBytes | Should -Be 200GB
        $plan.AdjoiningBytes | Should -Be 0
    }

    # The defect this replaced: the target was SizeMax minus the shrink amount, so a partition with
    # more space behind it than the user asked to free was made LARGER by a request to shrink it.
    It 'never grows the partition, however much unallocated space adjoins it' {
        $plan = Resolve-ShrinkPlan -CurrentSize 1000GB -MaxSize 1050GB -MinSize 300GB -ShrinkBytes 20GB
        $plan.TargetBytes | Should -Be 980GB
        $plan.TargetBytes | Should -BeLessThan 1000GB
        $plan.DevDriveBytes | Should -Be 70GB
    }

    It 'refuses <Case>' -TestCases @(
        @{ Case = 'a target below what Windows will allow'; Current = 1000GB; Max = 1000GB; Min = 900GB; Shrink = 200GB; Rejection = 'TargetBelowMinimum' }
        @{ Case = 'shrinking by the whole partition';       Current = 1000GB; Max = 1000GB; Min = 0;     Shrink = 1000GB; Rejection = 'ShrinkExceedsPartition' }
        @{ Case = 'shrinking by more than there is';        Current = 1000GB; Max = 1000GB; Min = 0;     Shrink = 1200GB; Rejection = 'ShrinkExceedsPartition' }
        @{ Case = 'a maximum below the current size';       Current = 1000GB; Max = 900GB;  Min = 0;     Shrink = 100GB; Rejection = 'MaxBelowCurrent' }
    ) {
        $plan = Resolve-ShrinkPlan -CurrentSize $Current -MaxSize $Max -MinSize $Min -ShrinkBytes $Shrink
        $plan.Rejection | Should -Be $Rejection
    }

    # Its own vocabulary: Resolve-DevDriveSizeInput answers 'BelowMinimum' about a typed size, and a
    # shared literal would let a mis-wired comparison read one function's verdict as the other's.
    It 'names its rejections apart from the ones the size question uses' {
        $plan = Resolve-ShrinkPlan -CurrentSize 1000GB -MaxSize 1000GB -MinSize 900GB -ShrinkBytes 200GB
        $plan.Rejection | Should -Not -Be 'BelowMinimum'
    }

    It 'answers zero sizes when it refuses <Case>, so a caller cannot act on a number it never got' -TestCases @(
        @{ Case = 'a target below what Windows will allow'; Current = 1000GB; Max = 1000GB; Min = 900GB; Shrink = 200GB }
        @{ Case = 'shrinking by the whole partition';       Current = 1000GB; Max = 1000GB; Min = 0;     Shrink = 1000GB }
        @{ Case = 'a maximum below the current size';       Current = 1000GB; Max = 900GB;  Min = 0;     Shrink = 100GB }
    ) {
        $plan = Resolve-ShrinkPlan -CurrentSize $Current -MaxSize $Max -MinSize $Min -ShrinkBytes $Shrink
        $plan.Rejection | Should -Not -BeNullOrEmpty
        $plan.TargetBytes | Should -Be 0
        $plan.DevDriveBytes | Should -Be 0
        $plan.AdjoiningBytes | Should -Be 0
    }
}

Describe 'Format-ShrinkAdjoiningNote' {
    It 'names the drive, the amount, and that it joins the new Dev Drive' {
        $note = @(Format-ShrinkAdjoiningNote -DriveLetter 'D' -AdjoiningGB 4)
        $note | Should -HaveCount 1
        $note[0] | Should -Match 'Unallocated right behind D: 4 GB'
        $note[0] | Should -Match 'it joins the new Dev Drive'
    }

    It 'stays silent for <Adjoining> GB, so no run invents a number' -TestCases @(
        @{ Adjoining = 0 }
        @{ Adjoining = -1 }
    ) {
        @(Format-ShrinkAdjoiningNote -DriveLetter 'D' -AdjoiningGB $Adjoining) | Should -HaveCount 0
    }
}

Describe 'Resolve-AlignedPlacement' {
    # Measured: New-Partition refused all five offsets a non-round shrink produced - remainders of
    # 125952, 12800, 545280, 923136 and 82432 bytes against 1 MB - with "The specified offset is not
    # valid". A resize lands 20 to 389 bytes off its target, so this is the ordinary case, not a rare one.
    It 'moves an offset with a remainder of <Remainder> forward to the next megabyte' -TestCases @(
        @{ Remainder = 125952 }
        @{ Remainder = 12800 }
        @{ Remainder = 545280 }
        @{ Remainder = 923136 }
        @{ Remainder = 82432 }
        @{ Remainder = 1 }
        @{ Remainder = 1048575 }
    ) {
        $offset = [uint64](64MB + $Remainder)
        $placement = Resolve-AlignedPlacement -Offset $offset -Size 100GB
        $placement.Rejection | Should -BeNullOrEmpty
        $placement.Offset % 1MB | Should -Be 0
        $placement.Offset | Should -BeGreaterThan $offset
        $placement.ShiftedBy | Should -Be (1MB - $Remainder)
    }

    It 'leaves an offset that is already a whole number of megabytes exactly where it is' {
        $placement = Resolve-AlignedPlacement -Offset 36523999232 -Size 100GB
        $placement.Offset | Should -Be 36523999232
        $placement.Size | Should -Be 100GB
        $placement.ShiftedBy | Should -Be 0
    }

    It 'gives back from the size exactly what the nudge took from the front' {
        $placement = Resolve-AlignedPlacement -Offset ([uint64](64MB + 700000)) -Size 100GB
        $placement.Offset + $placement.Size | Should -Be (64MB + 700000 + 100GB) -Because 'the run must end where it ended'
    }

    It 'refuses rather than answer a size of zero or less when the run is shorter than the nudge' -TestCases @(
        @{ Size = 1 }
        @{ Size = 300000 }
        @{ Size = 348576 }
    ) {
        $placement = Resolve-AlignedPlacement -Offset ([uint64](64MB + 700000)) -Size $Size
        $placement.Rejection | Should -Be 'NothingLeftAfterAligning'
        $placement.Size | Should -Be 0
    }

    It 'stays exact on offsets too large for a double to hold to the byte' {
        # 8 TB and change: dividing this by 1 MB as a double and multiplying back loses bytes.
        $offset = [uint64]8796093022209
        $placement = Resolve-AlignedPlacement -Offset $offset -Size 100GB
        $placement.Offset % 1MB | Should -Be 0
        $placement.Offset | Should -Be ([uint64]8796094070784)
    }
}

Describe 'Format-ShrinkRefusal' {
    It 'says why in plain words for <Rejection>, naming no rejection token' -TestCases @(
        @{ Rejection = 'TargetBelowMinimum';     Expect = 'will not take it below 900 GB' }
        @{ Rejection = 'ShrinkExceedsPartition'; Expect = 'the whole volume is only 1000 GB' }
        @{ Rejection = 'MaxBelowCurrent';        Expect = 'maximum size below its current size' }
    ) {
        $line = (Format-ShrinkRefusal -DriveLetter 'D' -ShrinkGB 200 -Rejection $Rejection `
                -MinSizeGB 900 -CurrentSizeGB 1000) -join ' '
        $line | Should -Match ([regex]::Escape($Expect))
        $line | Should -Not -Match $Rejection
    }

    It 'refuses a rejection name it has no wording for' {
        { Format-ShrinkRefusal -DriveLetter 'D' -ShrinkGB 200 -Rejection 'Whatever' `
                -MinSizeGB 900 -CurrentSizeGB 1000 } | Should -Throw
    }

    # The case that will actually happen: a rejection added to Resolve-ShrinkPlan and to the
    # ValidateSet, but never given wording. A default arm carrying one message would hide it.
    It 'has wording for every rejection Resolve-ShrinkPlan can answer' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$null, [ref]$null)
        $plan = $ast.FindAll({ param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Resolve-ShrinkPlan' }, $false)[0]
        $answered = @([regex]::Matches($plan.Extent.Text, "Rejection = '([A-Za-z]+)'") |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $answered.Count | Should -BeGreaterThan 0

        foreach ($rejection in $answered) {
            { Format-ShrinkRefusal -DriveLetter 'D' -ShrinkGB 200 -Rejection $rejection `
                    -MinSizeGB 900 -CurrentSizeGB 1000 } | Should -Not -Throw -Because "$rejection needs wording"
        }
    }
}

Describe 'ConvertTo-ByteCount' {
    It 'reads <GB> GB as <Bytes> bytes' -TestCases @(
        @{ GB = 0;    Bytes = 0 }
        @{ GB = 1;    Bytes = 1073741824 }
        @{ GB = 2.5;  Bytes = 2684354560 }
        @{ GB = 0.01; Bytes = 10737418 }
    ) {
        ConvertTo-ByteCount -GB $GB | Should -Be $Bytes
    }

    It 'answers an unsigned whole number, which is what the storage cmdlets take' {
        ConvertTo-ByteCount -GB 1.5 | Should -BeOfType [uint64]
    }
}

Describe 'Format-ShrinkSizeNote' {
    It 'says the drive comes out larger, by how much, and why' {
        $note = (Format-ShrinkSizeNote -DriveLetter 'D' -ShrinkGB 200 -DevDriveGB 250) -join ' '
        $note | Should -Match '50 GB of unallocated space already sits next to drive D:'
        $note | Should -Match 'comes out 250 GB rather than the 200 GB being freed'
    }

    # Three figures on one screen: a reader adds the first two and expects the third.
    It 'shows an extra of <Extra> GB that is exactly the difference between the two sizes' -TestCases @(
        @{ Shrink = 200;    DevDrive = 250;    Extra = 50 }
        @{ Shrink = 50.999; DevDrive = 55.005; Extra = 4.006 }
        @{ Shrink = 0.01;   DevDrive = 0.02;   Extra = 0.01 }
    ) {
        $note = (Format-ShrinkSizeNote -DriveLetter 'D' -ShrinkGB $Shrink -DevDriveGB $DevDrive) -join ' '
        $note | Should -Match ([regex]::Escape("$Extra GB of unallocated space"))
        $note | Should -Match ([regex]::Escape("comes out $DevDrive GB rather than the $Shrink GB"))
    }

    It 'stays silent when the drive is no larger than the amount freed' -TestCases @(
        @{ Shrink = 200; DevDrive = 200 }
        @{ Shrink = 200; DevDrive = 199 }
    ) {
        @(Format-ShrinkSizeNote -DriveLetter 'D' -ShrinkGB $Shrink -DevDriveGB $DevDrive) | Should -HaveCount 0
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

Describe 'Get-VolumeProperty' {
    It 'reports whichever property was asked for' {
        Mock Get-Volume { [PSCustomObject]@{ UniqueId = '\\?\Volume{240cfe1b-1db4-415a-8ccf-e2675e2b449d}\'; FileSystemLabel = 'Projects' } }
        Get-VolumeProperty -DriveLetter 'X' -Name 'UniqueId' | Should -Be '\\?\Volume{240cfe1b-1db4-415a-8ccf-e2675e2b449d}\'
        Get-VolumeProperty -DriveLetter 'X' -Name 'FileSystemLabel' | Should -Be 'Projects'
    }

    It 'answers nothing rather than throwing when the volume cannot be found' {
        # Reading a property off an empty result throws under strict mode, and this runs once the
        # drive already exists, where an abort costs the whole run.
        Mock Get-Volume { }
        { Get-VolumeProperty -DriveLetter 'X' -Name 'UniqueId' } | Should -Not -Throw
        Get-VolumeProperty -DriveLetter 'X' -Name 'UniqueId' | Should -BeNullOrEmpty
    }

    It 'answers nothing when the query itself fails' {
        Mock Get-Volume { throw 'The volume could not be read.' }
        Get-VolumeProperty -DriveLetter 'X' -Name 'UniqueId' | Should -BeNullOrEmpty
    }

    It 'answers nothing when more than one volume comes back' {
        Mock Get-Volume { @([PSCustomObject]@{ UniqueId = 'a' }, [PSCustomObject]@{ UniqueId = 'b' }) }
        Get-VolumeProperty -DriveLetter 'X' -Name 'UniqueId' | Should -BeNullOrEmpty
    }

    It 'answers nothing rather than throwing for a property the volume does not carry' {
        Mock Get-Volume { [PSCustomObject]@{ UniqueId = 'a' } }
        { Get-VolumeProperty -DriveLetter 'X' -Name 'NoSuchProperty' } | Should -Not -Throw
        Get-VolumeProperty -DriveLetter 'X' -Name 'NoSuchProperty' | Should -BeNullOrEmpty
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

Describe 'Get-DiskLargestFreeExtent' {
    It 'answers the largest unbroken block, which is the only thing New-Partition can fill' {
        Get-DiskLargestFreeExtent -Disk ([PSCustomObject]@{ Size = 500GB; LargestFreeExtent = [uint64]118GB }) |
            Should -Be 118GB
    }

    It 'answers 0 for a full disk rather than a leftover from the arithmetic' {
        Get-DiskLargestFreeExtent -Disk ([PSCustomObject]@{ Size = 500GB; LargestFreeExtent = [uint64]0 }) |
            Should -Be 0
    }

    It 'takes a uint64 extent without rounding or throwing' {
        # An extent on a 4 TB disk does not fit in an Int32, and Get-Disk hands back a uint64.
        Get-DiskLargestFreeExtent -Disk ([PSCustomObject]@{ LargestFreeExtent = [uint64]3.5TB }) |
            Should -Be 3.5TB
    }

    It 'says so when the disk does not report an extent, rather than passing 0 off as a fact' {
        # The caller exits on 0 and tells the user the disk has no room. It must not say that
        # about a disk Windows declined to answer for.
        Mock Write-Warning { }
        Get-DiskLargestFreeExtent -Disk ([PSCustomObject]@{ Size = 500GB }) | Should -Be 0
        Should -Invoke Write-Warning -ParameterFilter { $Message -match 'did not report a largest free extent' }
    }

    It 'says the same when the disk reports nothing at all' {
        Mock Write-Warning { }
        Get-DiskLargestFreeExtent -Disk ([PSCustomObject]@{ LargestFreeExtent = $null }) | Should -Be 0
        Should -Invoke Write-Warning -Times 1
    }

    It 'stays silent on a disk that answered honestly' {
        Mock Write-Warning { }
        Get-DiskLargestFreeExtent -Disk ([PSCustomObject]@{ LargestFreeExtent = [uint64]0 }) | Out-Null
        Should -Not -Invoke Write-Warning
    }

    It 'refuses to be called without a disk' {
        # No caller can pass nothing; answering 0 to that would disguise a bug as a hardware fact.
        { Get-DiskLargestFreeExtent -Disk $null } | Should -Throw
    }
}

Describe 'Show-DriveSelection' {
    BeforeAll {
        Mock Write-Host { }
    }

    It 'shows what one unbroken block holds, not what the arithmetic used to invent' {
        # A 500 GB disk whose partitions fill it reads 0 here. The old sum of Basic-or-lettered
        # partitions reported 2.22 GB on exactly such a disk.
        Mock Get-Disk { @([PSCustomObject]@{ Number = 0; FriendlyName = 'Full disk'; Size = 500GB
                BusType = 'NVMe'; PartitionStyle = 'GPT'; LargestFreeExtent = [uint64]0 }) }
        Mock Get-Partition { @() }
        Show-DriveSelection -SupportedStyles @('GPT', 'MBR') | Out-Null
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'Unallocated: 0 GB in one unbroken block' }
    }

    It 'does not call an ordinary full disk free' {
        Mock Get-Disk { @([PSCustomObject]@{ Number = 0; FriendlyName = 'Full disk'; Size = 500GB
                BusType = 'NVMe'; PartitionStyle = 'GPT'; LargestFreeExtent = [uint64]0 }) }
        Mock Get-Partition { @() }
        Show-DriveSelection -SupportedStyles @('GPT', 'MBR') | Out-Null
        Should -Not -Invoke Write-Host -ParameterFilter { $Object -match 'Free Space' }
    }

    It 'reports the block a disk really has' {
        Mock Get-Disk { @([PSCustomObject]@{ Number = 2; FriendlyName = 'Spare'; Size = 119.24GB
                BusType = 'USB'; PartitionStyle = 'GPT'; LargestFreeExtent = [uint64]118.61GB }) }
        Mock Get-Partition { @() }
        Show-DriveSelection -SupportedStyles @('GPT', 'MBR') | Out-Null
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'Unallocated: 118\.61 GB' }
    }

    It 'says a disk with no readable partition table cannot be used, instead of calling it full' {
        # Observed on an uninitialized disk: Size 60 GB, LargestFreeExtent 0, because free space is
        # counted between partitions and such a disk has none.
        Mock Get-Disk { @([PSCustomObject]@{ Number = 3; FriendlyName = 'Brand new'; Size = 60GB
                BusType = 'NVMe'; PartitionStyle = 'RAW'; LargestFreeExtent = [uint64]0 }) }
        Mock Get-Partition { @() }
        Show-DriveSelection -SupportedStyles @('GPT', 'MBR') | Out-Null
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'Cannot be used: partition style RAW' }
        Should -Not -Invoke Write-Host -ParameterFilter { $Object -match 'Unallocated' }
    }

    It 'marks a disk of a style this script does not work with, however much room it reports' {
        # Not a RAW disk: this one reports its whole size as free, and the old size check would have
        # let it through. The style is the reason to refuse it, not the number beside it.
        Mock Get-Disk { @([PSCustomObject]@{ Number = 4; FriendlyName = 'Odd one'; Size = 200GB
                BusType = 'SAS'; PartitionStyle = 'Unknown'; LargestFreeExtent = [uint64]200GB }) }
        Mock Get-Partition { @() }
        Show-DriveSelection -SupportedStyles @('GPT', 'MBR') | Out-Null
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'Cannot be used: partition style Unknown' }
        Should -Not -Invoke Write-Host -ParameterFilter { $Object -match 'Unallocated' }
    }

    It 'still reports the unallocated block on a disk that does have a partition table' {
        Mock Get-Disk { @([PSCustomObject]@{ Number = 2; FriendlyName = 'Spare'; Size = 119.24GB
                BusType = 'USB'; PartitionStyle = 'MBR'; LargestFreeExtent = [uint64]119.24GB }) }
        Mock Get-Partition { @() }
        Show-DriveSelection -SupportedStyles @('GPT', 'MBR') | Out-Null
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'Unallocated: 119\.24 GB' }
        Should -Not -Invoke Write-Host -ParameterFilter { $Object -match 'Cannot be used' }
    }

    It 'says a disk that reported no style at all cannot be used, rather than throwing' {
        # Strict mode turns a missing property into an exception, in the middle of the disk list.
        Mock Get-Disk { @([PSCustomObject]@{ Number = 5; FriendlyName = 'Silent'; Size = 100GB
                BusType = 'SATA'; LargestFreeExtent = [uint64]100GB }) }
        Mock Get-Partition { @() }
        { Show-DriveSelection -SupportedStyles @('GPT', 'MBR') } | Should -Not -Throw
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'Cannot be used: no partition style reported' }
    }

    It 'carries on listing when a disk answers that it has no partitions' {
        # The real cmdlet raises an error record for that, which used to print into the list.
        Mock Get-Disk { @([PSCustomObject]@{ Number = 2; FriendlyName = 'Spare'; Size = 119.24GB
                BusType = 'USB'; PartitionStyle = 'MBR'; LargestFreeExtent = [uint64]119.24GB }) }
        Mock Get-Partition { Write-Error "No MSFT_Partition objects found with property 'DiskNumber' equal to '2'." }
        $ErrorActionPreference = 'Stop'
        { Show-DriveSelection -SupportedStyles @('GPT', 'MBR') } | Should -Not -Throw
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'Unallocated: 119\.24 GB' }
    }
}

Describe 'Get-DiskPartitionStyleName' {
    It 'reports the style the disk answers with' -TestCases @(
        @{ Style = 'GPT' }
        @{ Style = 'MBR' }
        @{ Style = 'RAW' }
        @{ Style = 'Unknown' }
    ) {
        Get-DiskPartitionStyleName -Disk ([PSCustomObject]@{ PartitionStyle = $Style }) | Should -Be $Style
    }

    It 'answers with an empty string when the disk reports no style' {
        # Reading a property that is not there throws under strict mode, mid disk list.
        { Get-DiskPartitionStyleName -Disk ([PSCustomObject]@{ Number = 0 }) } | Should -Not -Throw
        Get-DiskPartitionStyleName -Disk ([PSCustomObject]@{ Number = 0 }) | Should -Be ''
        Get-DiskPartitionStyleName -Disk ([PSCustomObject]@{ PartitionStyle = $null }) | Should -Be ''
    }
}

Describe 'Test-DiskStyleSupported' {
    It 'works with <Style>' -TestCases @(
        @{ Style = 'GPT' }
        @{ Style = 'MBR' }
    ) {
        # MBR was measured, not assumed: a Dev Drive was created on an MBR disk on this machine,
        # Windows called it a trusted developer volume, and its deduplication task was named after
        # the volume the same way a GPT one is.
        Test-DiskStyleSupported -Style $Style -Supported @('GPT', 'MBR') | Should -BeTrue
    }

    It 'refuses <Style>' -TestCases @(
        @{ Style = 'RAW' }
        @{ Style = 'Unknown' }
        @{ Style = '' }
        @{ Style = '2' }
    ) {
        Test-DiskStyleSupported -Style $Style -Supported @('GPT', 'MBR') | Should -BeFalse
    }

    It 'takes the supported set from its caller rather than knowing one of its own' {
        Test-DiskStyleSupported -Style 'MBR' -Supported @('GPT') | Should -BeFalse
    }
}

Describe 'Format-DiskStyleNote' {
    It 'quotes what Windows said, whatever it said' -TestCases @(
        @{ Style = 'RAW' }
        @{ Style = 'Unknown' }
        @{ Style = 'Something new' }
    ) {
        # One shape for every unusable style: the list reports, it does not interpret.
        Format-DiskStyleNote -Style $Style | Should -Be "Cannot be used: partition style $Style"
    }

    It 'does not invent a style for a disk that reported none' {
        Format-DiskStyleNote -Style '' | Should -Be 'Cannot be used: no partition style reported'
    }
}

Describe 'Resolve-UnusableDiskAdvice' {
    BeforeAll {
        function Get-Advice {
            param([string]$Style, [int]$Number = 3, [string]$Init = 'GPT', [string[]]$Set = @('GPT', 'MBR'))
            (Resolve-UnusableDiskAdvice -Style $Style -DiskNumber $Number -InitializeStyle $Init -Supported $Set) -join "`n"
        }
        $script:RawText = Get-Advice -Style 'RAW'
    }

    It 'gives one message for <Style>, differing only in what Windows reported' -TestCases @(
        @{ Style = 'RAW' }
        @{ Style = 'Unknown' }
        @{ Style = 'Something new' }
    ) {
        # One check, one refusal: nothing here knows enough about a style to say more about it.
        $text = Get-Advice -Style $Style
        $text | Should -Match "Disk 3 reports its partition style as $Style"
        $text | Should -Match 'works with GPT and MBR disks only'
        $text | Should -Match 'Initialize-Disk -Number 3 -PartitionStyle GPT'
    }

    It 'does not invent a style for a disk that reported none' {
        Get-Advice -Style '' | Should -Match 'Disk 3 did not report a partition style'
    }

    It 'names the supported set it was given, so the sentence cannot outlive the check' {
        $narrow = Get-Advice -Style 'RAW' -Set @('GPT')
        $narrow | Should -Match 'works with GPT disks only'
        $narrow | Should -Match 'once Windows reports it as GPT'
    }

    It 'hands over the command with the number and the style already in it' {
        $script:RawText | Should -Match 'Initialize-Disk -Number 3 -PartitionStyle GPT'
        Get-Advice -Style 'RAW' -Number 7 -Init 'MBR' | Should -Match 'Initialize-Disk -Number 7 -PartitionStyle MBR'
    }

    It 'refuses to render a style that Initialize-Disk would reject' {
        { Resolve-UnusableDiskAdvice -Style 'RAW' -DiskNumber 3 -InitializeStyle 'NTFS' -Supported @('GPT', 'MBR') } |
            Should -Throw
    }

    It 'says to run the command elsewhere and keep this prompt alive, which is the point of it' {
        # The script already requires administrator rights, so "elevated" says nothing the reader
        # does not have. What they need told is that the run is still standing at the prompt.
        $script:RawText | Should -Match 'Leave this prompt open'
        $script:RawText | Should -Match 'another PowerShell window'
    }

    It 'offers the remedy as a condition, not as an instruction' {
        # A disk that looks empty may be one whose table Windows failed to read.
        $script:RawText | Should -Match 'If you know this disk is new'
        $script:RawText | Should -Match 'RAW for a table it merely failed to read'
    }

    It 'says what initializing costs without overstating what the command does' {
        # Initialize-Disk writes a new partition table over the old one; the bytes are not erased,
        # they stop being reachable. Blunt enough, and true.
        $script:RawText | Should -Match 'makes every\s+file on the disk unreachable'
        $script:RawText | Should -Not -Match 'destroys every file'
    }

    It 'claims only what is true: the script does initialize the virtual disk it creates itself' {
        $script:RawText | Should -Match 'never initializes a physical disk'
        $script:RawText | Should -Not -Match 'never initializes disks'
    }

    It 'sends the user back to the same prompt, and says how to leave from there' {
        $script:RawText | Should -Match 'Choose a different disk, type this number again'
        $script:RawText | Should -Match 'Ctrl\+C to leave without creating anything'
    }

    It 'returns plain lines rather than objects to unwrap' {
        Resolve-UnusableDiskAdvice -Style 'RAW' -DiskNumber 3 -InitializeStyle 'GPT' -Supported @('GPT', 'MBR') |
            Should -BeOfType [string]
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

Describe 'Format-DevDriveStateAfterFailure' {
    It 'names the state for <VolumeState>' -TestCases @(
        @{ VolumeState = 'Encrypted'; Expected = 'already started encrypting' }
        @{ VolumeState = 'Clear'; Expected = 'works without BitLocker' }
        @{ VolumeState = 'Unknown'; Expected = 'could not be read' }
    ) {
        Format-DevDriveStateAfterFailure -VolumeState $VolumeState | Should -Match $Expected
    }

    It 'assumes nothing when no state is passed' {
        Format-DevDriveStateAfterFailure | Should -Match 'could not be read'
    }

    It 'never calls an unread volume unencrypted' {
        # The one wrong answer here can cost somebody their data.
        Format-DevDriveStateAfterFailure -VolumeState 'Unknown' | Should -Not -Match 'works without BitLocker'
    }

    It 'gives an encrypted drive a next step when the run stops there' {
        # Nothing prints after this, so a person told their drive is encrypting and nothing else
        # has been left without the one thing that gets them back into it.
        (Format-DevDriveStateAfterFailure -VolumeState 'Encrypted' -RunEnding) -join "`n" |
            Should -Match 'recovery key is the way back'
    }

    It 'leaves that out where the run carries on and says it later' {
        (Format-DevDriveStateAfterFailure -VolumeState 'Encrypted') -join "`n" |
            Should -Not -Match 'recovery key'
    }
}

Describe 'Resolve-BitLockerFailure' {
    It 'recognises <Description> as a rejected password, whatever language said it' -TestCases @(
        @{ Description = 'too short (0x80310080)'
           Message = 'Ihr Kennwort erfuellt nicht die Mindestlaenge. (0x80310080)' }
        @{ Description = 'not complex enough (0x80310081)'
           Message = 'Ihr Kennwort ist nicht komplex genug. (0x80310081)' }
        @{ Description = 'not printable ASCII (0x803100A4)'
           Message = 'Ihr Administrator verlangt nur druckbare ASCII-Zeichen. (0x803100A4)' }
        @{ Description = 'longer than 256 characters (0x803100AA)'
           Message = 'Das Kennwort darf 256 Zeichen nicht ueberschreiten. (0x803100AA)' }
    ) {
        # Matched by code: the sentence around each is localized.
        (Resolve-BitLockerFailure -Message $Message -RetryCount 1 -MaxRetries 10 -PasswordAsked).Kind |
            Should -Be 'Password'
    }

    It 'matches the code whatever case it is written in' {
        (Resolve-BitLockerFailure -Message 'refused (0x803100a4)' -RetryCount 1 -MaxRetries 10 -PasswordAsked).Kind |
            Should -Be 'Password'
    }

    It 'takes the code from the number when the text does not carry it' {
        # .NET puts the code in the message today, in both editions. That is one formatting choice
        # away from being absent, and the exception carries the number regardless.
        $verdict = Resolve-BitLockerFailure -Message 'Kennwort abgelehnt.' -HResult -2144272255 `
            -RetryCount 1 -MaxRetries 10 -PasswordAsked
        $verdict.Kind | Should -Be 'Password'
    }

    It 'takes a policy refusal from the number too' {
        $verdict = Resolve-BitLockerFailure -Message 'Abgelehnt.' -HResult -2144272290 `
            -RetryCount 1 -MaxRetries 10 -PasswordAsked
        $verdict.Kind | Should -Be 'Other'
        $verdict.CanRetry | Should -BeFalse
    }

    It 'reads no code out of an unset number' {
        # 0 is "nothing was passed", not a code, and must not collide with anything.
        (Resolve-BitLockerFailure -Message 'Etwas ging schief.' -HResult 0 `
                -RetryCount 1 -MaxRetries 10 -PasswordAsked).Kind | Should -Be 'Other'
    }

    It 'no longer decides by English words: <Description>' -TestCases @(
        @{ Description = 'the old complexity phrase'
           Message = 'The password does not meet the password complexity requirements.' }
        @{ Description = 'the old requirements phrase'; Message = 'Password requirements not met.' }
    ) {
        # These carry no code, so there is nothing to retry on. The old matcher took them, which is
        # why it worked in English and nowhere else; re-adding it "for safety" would fail here.
        (Resolve-BitLockerFailure -Message $Message -RetryCount 1 -MaxRetries 10 -PasswordAsked).Kind |
            Should -Be 'Other'
    }

    It 'keeps the set closed: <Description> is not a password to retype' -TestCases @(
        @{ Description = 'policy forbids creating a password (0x8031006A)'
           Message = 'Nicht erlaubt. (0x8031006A)' }
        @{ Description = 'FIPS forbids passwords (0x8031006C)'
           Message = 'FIPS. (0x8031006C)' }
    ) {
        # Both mention a password and both are refusals a retype cannot change, so they belong with
        # the policy refusals and must never be offered a retry.
        $verdict = Resolve-BitLockerFailure -Message $Message -RetryCount 1 -MaxRetries 10 -PasswordAsked
        $verdict.Kind | Should -Be 'Other'
        $verdict.CanRetry | Should -BeFalse
        ($verdict.Lines -join "`n") | Should -Match 'same refusal'
    }

    It 'does not call a FIPS refusal a group policy one' {
        # FIPS is a different machine setting with a different remedy, and the quoted Windows text
        # above already says which of the two refused. Naming one sends people to the wrong place.
        ((Resolve-BitLockerFailure -Message 'FIPS. (0x8031006C)' -RetryCount 1 -MaxRetries 10).Lines -join "`n") |
            Should -Not -Match 'Group policy'
    }

    It 'never blames the password on a run that never asks for one' {
        # In partition mode nothing is prompted, so a password retry would repeat the same call
        # ten times with nobody to change anything.
        $verdict = Resolve-BitLockerFailure -RetryCount 1 -MaxRetries 10 `
            -Message 'Your password does not meet the complexity requirements. (0x80310081)'
        $verdict.Kind | Should -Be 'Other'
    }

    It 'says what Windows said rather than guessing which of the four refusals it was' {
        # Three of the four are not about complexity at all, so naming complexity would be wrong.
        $lines = (Resolve-BitLockerFailure -Message 'Nur druckbare ASCII-Zeichen. (0x803100A4)' `
                -RetryCount 1 -MaxRetries 10 -PasswordAsked).Lines -join "`n"
        $lines | Should -Match 'Nur druckbare ASCII-Zeichen'
        $lines | Should -Not -Match 'complexity'
    }

    It 'counts the attempts left before giving up' {
        $verdict = Resolve-BitLockerFailure -Message 'refused (0x80310081)' -RetryCount 3 -MaxRetries 10 -PasswordAsked
        $verdict.Exhausted | Should -BeFalse
        $verdict.CanRetry | Should -BeTrue
        ($verdict.Lines -join "`n") | Should -Match 'Attempt 3 of 10'
    }

    It 'gives up once the attempts are used up' {
        $verdict = Resolve-BitLockerFailure -Message 'refused (0x80310081)' -RetryCount 10 -MaxRetries 10 -PasswordAsked
        $verdict.Exhausted | Should -BeTrue
        $verdict.CanRetry | Should -BeFalse
        ($verdict.Lines -join "`n") | Should -Match 'Maximum retry attempts reached'
    }

    It 'says what the drive is on the one password path that ends the run' {
        # The run throws right after this, so it is the last thing the user reads. Every other
        # failure path names the drive's state; this one used to stay silent about it.
        $lines = (Resolve-BitLockerFailure -Message 'refused (0x80310081)' -RetryCount 10 -MaxRetries 10 `
                -PasswordAsked -VolumeState 'Clear').Lines -join "`n"
        $lines | Should -Match 'works without BitLocker'
    }

    It 'does not clutter a retryable password refusal with the drive state' {
        # There are nine attempts left; nothing has ended, so nothing needs summarising.
        $lines = (Resolve-BitLockerFailure -Message 'refused (0x80310081)' -RetryCount 1 -MaxRetries 10 `
                -PasswordAsked -VolumeState 'Clear').Lines -join "`n"
        $lines | Should -Not -Match 'works without BitLocker'
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
        $verdict = Resolve-BitLockerFailure -Message 'refused (0x80310081)' -RetryCount 1 -MaxRetries 10 `
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
        # A message carrying both codes is a refusal policy will repeat, not a password to retype.
        $verdict = Resolve-BitLockerFailure -Message 'refused (0x8031005E) (0x80310081)' `
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
        $lines | Should -Match 'only works in English'
        $lines | Should -Match 'everything is as it should be'
    }

    It 'raises no alarm on a run where only the language stopped it reading the answer' {
        # This is what every successful run looks like on a Windows that is not in English, so it
        # must not read as a fault, and must not ask for anything to be done.
        $lines = (Resolve-DevDriveTrustReport -MountPoint 'X:' -TrustExitCode 0 -QueryOutput 'Dies ist ein vertrauenswuerdiges Entwicklervolume.').Lines -join "`n"
        $lines | Should -Not -Match 'could not mark'
        $lines | Should -Not -Match 'will still work'
        $lines | Should -Not -Match 'Retry by hand'
        $lines | Should -Not -Match 'It should say'
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
            [PSCustomObject]@{
                Type = 'DedupAndCompress'; CompressionFormat = 'ZSTD'; CompressionLevel = [uint16]7
                Start = [datetime]'2026-08-25 17:00:00'
            }
        }
        $report = Get-DedupVolumeReport -MountPoint 'X:'
        $report.Known | Should -BeTrue
        $report.Mode | Should -Be 'DedupAndCompress'
        $report.Format | Should -Be 'ZSTD'
        $report.Level | Should -Be 7
        $report.Start | Should -Be '17:00'
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
            param(
                [string]$Mode, [string]$Format, [int]$Level,
                [bool]$Known = $true, [string]$Reason = '', [string]$Start = '17:00'
            )
            return [PSCustomObject]@{
                Known = $Known; Reason = $Reason; Mode = $Mode; Format = $Format; Level = $Level; Start = $Start
            }
        }
    }

    It 'agrees when the volume reports what was asked for' {
        $verdict = Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'DedupAndCompress' `
            -ExpectedFormat 'ZSTD' -ExpectedLevel 7 -ExpectedStart '17:00' `
            -Actual (New-Report -Mode 'DedupAndCompress' -Format 'ZSTD' -Level 7)
        $verdict.Agrees | Should -BeTrue
        $verdict.Lines -join "`n" | Should -Match 'X: confirms it: deduplication and ZSTD compression, level 7\.'
    }

    It 'treats a reported level of 0 as the default, which is what asking for no level means' {
        $verdict = Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'Compress' `
            -ExpectedFormat 'LZ4' -ExpectedLevel $null -ExpectedStart '17:00' `
            -Actual (New-Report -Mode 'Compress' -Format 'LZ4' -Level 0)
        $verdict.Agrees | Should -BeTrue
        $lines = $verdict.Lines -join "`n"
        $lines | Should -Match 'The compression level is the one Windows picks\.'
        $lines | Should -Not -Match 'level 0'
    }

    It 'accepts any level when none was asked for' {
        $verdict = Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'DedupAndCompress' `
            -ExpectedFormat 'ZSTD' -ExpectedLevel $null -ExpectedStart '17:00' `
            -Actual (New-Report -Mode 'DedupAndCompress' -Format 'ZSTD' -Level 3)
        $verdict.Agrees | Should -BeTrue
        $verdict.Lines -join "`n" | Should -Match 'level 3'
    }

    It 'names every setting that came back different' -TestCases @(
        @{ Mode = 'Compress'; Format = 'ZSTD'; Level = 7; Start = '17:00'; Expect = 'mode: asked for DedupAndCompress, the volume reports Compress' }
        @{ Mode = 'DedupAndCompress'; Format = 'LZ4'; Level = 7; Start = '17:00'; Expect = 'compression format: asked for ZSTD, the volume reports LZ4' }
        @{ Mode = 'DedupAndCompress'; Format = 'ZSTD'; Level = 3; Start = '17:00'; Expect = 'compression level: asked for level 7, the volume reports level 3' }
        @{ Mode = 'DedupAndCompress'; Format = 'ZSTD'; Level = 7; Start = '11:00'; Expect = 'start time: asked for 17:00, the volume reports 11:00' }
    ) {
        $verdict = Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'DedupAndCompress' `
            -ExpectedFormat 'ZSTD' -ExpectedLevel 7 -ExpectedStart '17:00' `
            -Actual (New-Report -Mode $Mode -Format $Format -Level $Level -Start $Start)
        $verdict.Agrees | Should -BeFalse
        $verdict.Lines -join "`n" | Should -Match ([regex]::Escape($Expect))
    }

    # Nothing compared the written time until now.
    It 'catches a time that was promised and not written' {
        $verdict = Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'Dedup' `
            -ExpectedFormat '' -ExpectedLevel $null -ExpectedStart '11:00' `
            -Actual (New-Report -Mode 'Dedup' -Format '' -Level 0 -Start '17:00')
        $verdict.Agrees | Should -BeFalse
        $verdict.Lines -join "`n" | Should -Match 'start time: asked for 11:00, the volume reports 17:00'
    }

    It 'names the gap rather than passing silently when no start time could be read' {
        $verdict = Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'Dedup' `
            -ExpectedFormat '' -ExpectedLevel $null -ExpectedStart '17:00' `
            -Actual (New-Report -Mode 'Dedup' -Format '' -Level 0 -Start '')
        $verdict.Agrees | Should -BeFalse
        $verdict.Lines -join "`n" | Should -Match 'the volume reported none that could be read'
    }

    It 'compares the time for every mode, including the one that does not compress' {
        $verdict = Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'Dedup' `
            -ExpectedFormat 'ZSTD' -ExpectedLevel 9 -ExpectedStart '17:00' `
            -Actual (New-Report -Mode 'Dedup' -Format 'LZ4' -Level 0 -Start '09:00')
        $verdict.Agrees | Should -BeFalse
        $verdict.Lines -join "`n" | Should -Match 'start time: asked for 17:00, the volume reports 09:00'
    }

    It 'calls a level asked for and answered with the default a difference, and names it as the default' {
        $verdict = Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'DedupAndCompress' `
            -ExpectedFormat 'ZSTD' -ExpectedLevel 7 -ExpectedStart '17:00' `
            -Actual (New-Report -Mode 'DedupAndCompress' -Format 'ZSTD' -Level 0)
        $verdict.Agrees | Should -BeFalse
        $verdict.Lines -join "`n" | Should -Match 'the volume reports the default'
    }

    It 'ignores the compression settings for the mode that does not compress' {
        $verdict = Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'Dedup' `
            -ExpectedFormat 'ZSTD' -ExpectedLevel 9 -ExpectedStart '17:00' `
            -Actual (New-Report -Mode 'Dedup' -Format 'LZ4' -Level 0)
        $verdict.Agrees | Should -BeTrue
        $verdict.Lines -join "`n" | Should -Be 'X: confirms it: deduplication only, without compression.'
    }

    It 'says the drive still works when the settings disagree' {
        $verdict = Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'Dedup' `
            -ExpectedFormat '' -ExpectedLevel $null -ExpectedStart '17:00' `
            -Actual (New-Report -Mode 'Disabled' -Format 'LZ4' -Level 0)
        $verdict.Agrees | Should -BeFalse
        $verdict.Lines -join "`n" | Should -Match 'created and usable'
    }

    It 'asks the user to look for themselves when the volume could not be read' {
        $verdict = Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'Dedup' `
            -ExpectedFormat '' -ExpectedLevel $null -ExpectedStart '17:00' `
            -Actual (New-Report -Known $false -Mode '' -Format '' -Level 0 -Start '')
        $verdict.Agrees | Should -BeFalse
        $lines = $verdict.Lines -join "`n"
        $lines | Should -Match 'Could not confirm the deduplication settings on X:'
        $lines | Should -Match 'Get-ReFSDedupSchedule -Volume X:'
    }

    It 'passes on the reason the volume gave, when there is one' {
        $verdict = Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'Dedup' -ExpectedFormat '' `
            -ExpectedLevel $null -ExpectedStart '17:00' `
            -Actual (New-Report -Known $false -Mode '' -Format '' -Level 0 -Start '' -Reason 'Windows said: Access is denied.')
        $verdict.Lines -join "`n" | Should -Match 'Windows said: Access is denied\.'
    }

    It 'refuses a mode it does not know' {
        { Resolve-DedupReadBackVerdict -MountPoint 'X:' -ExpectedMode 'Disabled' -ExpectedFormat '' `
                -ExpectedLevel $null -ExpectedStart '17:00' `
                -Actual (New-Report -Mode 'Disabled' -Format '' -Level 0) } | Should -Throw
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

Describe 'Format-DedupScheduleStart' {
    It 'renders the hour and minute the cmdlet returns, dropping the date it carries' {
        # Measured: the cmdlet answers a DateTime stamped with the day the schedule was written.
        Format-DedupScheduleStart -Start ([datetime]'2026-08-25 17:00:00') | Should -Be '17:00'
    }

    It 'renders the same text whatever the machine regional format is' {
        $original = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            foreach ($name in 'en-US', 'uk-UA', 'de-DE', 'th-TH', 'ar-SA') {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::new($name)
                Format-DedupScheduleStart -Start ([datetime]'2026-08-25 19:00:00') | Should -Be '19:00'
            }
        }
        finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $original
        }
    }

    It 'answers empty for <Case>, so a read-back names the gap instead of comparing nothing' -TestCases @(
        @{ Case = 'null';     Start = $null }
        @{ Case = 'a string'; Start = '17:00' }
        @{ Case = 'a number'; Start = 17 }
    ) {
        Format-DedupScheduleStart -Start $Start | Should -Be ''
    }

    # The read-back compares this against what Resolve-DedupTimeInput built. Two unrelated format
    # strings produce those, and a drive set up correctly would be reported wrong if they diverged.
    It 'renders <Typed> the same way the answer parser stores it' -TestCases @(
        @{ Typed = '8:15' }
        @{ Typed = '08:15' }
        @{ Typed = '0:00' }
        @{ Typed = '9:05' }
        @{ Typed = '17:00' }
        @{ Typed = '18:30' }
        @{ Typed = '23:59' }
    ) {
        $stored = (Resolve-DedupTimeInput -Answer $Typed).Time
        $parts = $stored -split ':'
        $asCmdletReturnsIt = (Get-Date -Year 2026 -Month 8 -Day 25 -Hour ([int]$parts[0]) `
                -Minute ([int]$parts[1]) -Second 0)
        Format-DedupScheduleStart -Start $asCmdletReturnsIt | Should -Be $stored
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
    It 'names the days, the daily time, the weekly day and its start' {
        $lines = Format-DedupScheduleSummary -DailyTime '17:00' -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -WeeklyJob
        $lines.Count | Should -Be 2
        $lines[0] | Should -Be '  Daily optimization : Monday-Friday at 17:00'
        $lines[1] | Should -Be '  Weekly maintenance : Monday at 17:30, every 1 week'
    }

    It 'shows what the user chose rather than the defaults' {
        $lines = Format-DedupScheduleSummary -DailyTime '08:00' -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Saturday' -WeeklyStart '09:00' -WeeksInterval 1 -WeeklyJob
        $lines[0] | Should -Match 'at 08:00$'
        $lines[1] | Should -Match 'Saturday at 09:00'
    }

    It 'promises one daily run, never a list' {
        # The line that told a user their second chosen time would run, when only one ever did.
        $lines = Format-DedupScheduleSummary -DailyTime '17:00' -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -WeeklyJob
        $lines[0] | Should -Not -Match ' and '
        $lines[0] | Should -Not -Match ','
    }

    It 'says weeks in the plural for an interval above one' {
        $lines = Format-DedupScheduleSummary -DailyTime '11:00' -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 2 -WeeklyJob
        $lines[1] | Should -Match 'every 2 weeks'
    }

    It 'promises no weekly maintenance where Windows will schedule none' {
        # @(): one line comes back as a bare string, and strict mode refuses .Count on one of those.
        $lines = @(Format-DedupScheduleSummary -DailyTime '17:00' -DailyDaysLabel 'Monday-Friday' `
                -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1)
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be '  Daily optimization : Monday-Friday at 17:00'
    }

    It 'needs no weekly day at all when there is no weekly job' {
        { Format-DedupScheduleSummary -DailyTime '11:00' -DailyDaysLabel 'Monday-Friday' } |
            Should -Not -Throw
    }
}

Describe 'Resolve-DedupTaskName' {
    It 'takes the name from the volume identifier, in the form Windows registers it' {
        # Measured on two volumes on separate disks: the task is named after the volume's own GUID.
        Resolve-DedupTaskName -UniqueId '\\?\Volume{240cfe1b-1db4-415a-8ccf-e2675e2b449d}\' |
            Should -Be '{240CFE1B-1DB4-415A-8CCF-E2675E2B449D}'
    }

    It 'answers nothing for an identifier that carries no GUID' {
        Resolve-DedupTaskName -UniqueId 'D:\' | Should -BeNullOrEmpty
    }

    It 'answers nothing for a device path, whose GUID names an interface class and not the volume' {
        # A volume with no volume GUID answers with this shape. Naming a task after the class GUID
        # would look like an answer and be one nobody could act on.
        Resolve-DedupTaskName -UniqueId '\\?\scsi#disk&ven_x#4&1c9d1cd5&0&000000#{53f56307-b6bf-11d0-94f2-00a0c91efb8b}' |
            Should -BeNullOrEmpty
    }

    It 'answers nothing rather than throwing when the volume could not be read' {
        { Resolve-DedupTaskName -UniqueId $null } | Should -Not -Throw
        Resolve-DedupTaskName -UniqueId $null | Should -BeNullOrEmpty
        Resolve-DedupTaskName -UniqueId '   ' | Should -BeNullOrEmpty
    }

    It 'does not take a shorter run of hex for a volume identifier' {
        Resolve-DedupTaskName -UniqueId '{240cfe1b-1db4-415a-8ccf}' | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-OwnDedupTask' {
    BeforeAll {
        $script:OwnTask = '{AA0DAF00-0000-0000-0000-100000000000}'
        $script:OtherTask = '{240CFE1B-1DB4-415A-8CCF-E2675E2B449D}'
        $script:Folder = @(
            'Initialization'
            $script:OtherTask
            "$($script:OtherTask)-Scrub"
            $script:OwnTask
            "$($script:OwnTask)-Scrub"
        ) | ForEach-Object { [PSCustomObject]@{ TaskName = $_; State = 'Ready' } }
    }

    It 'takes this volume''s daily task and its scrub twin, and nothing else' {
        $picked = @(Resolve-OwnDedupTask -Tasks $script:Folder -VolumeTaskName $script:OwnTask)
        $picked | Should -HaveCount 2
        $picked.TaskName | Should -Contain $script:OwnTask
        $picked.TaskName | Should -Contain "$($script:OwnTask)-Scrub"
    }

    It 'leaves another drive''s tasks alone' {
        # That folder holds every drive's tasks, and the tasks of volumes that no longer exist.
        $picked = @(Resolve-OwnDedupTask -Tasks $script:Folder -VolumeTaskName $script:OwnTask)
        $picked.TaskName | Should -Not -Contain $script:OtherTask
        $picked.TaskName | Should -Not -Contain "$($script:OtherTask)-Scrub"
    }

    It 'leaves the task Windows registers alone without comparing its display name' {
        # The old exclusion named it in English, which stops matching wherever that name is translated.
        $picked = @(Resolve-OwnDedupTask -Tasks $script:Folder -VolumeTaskName $script:OwnTask)
        $picked.TaskName | Should -Not -Contain 'Initialization'
    }

    It 'hands back the tasks themselves, so nothing has to be looked up again to change them' {
        $picked = @(Resolve-OwnDedupTask -Tasks $script:Folder -VolumeTaskName $script:OwnTask)
        $picked[0].State | Should -Be 'Ready'
    }

    It 'takes a task of this volume that Windows has disabled' {
        # It is still this volume's, and setting a condition on it is not the same as running it.
        $disabled = @([PSCustomObject]@{ TaskName = $script:OwnTask; State = 'Disabled' })
        Resolve-OwnDedupTask -Tasks $disabled -VolumeTaskName $script:OwnTask | Should -HaveCount 1
    }

    It 'matches whatever case the name is reported in' {
        $lower = @([PSCustomObject]@{ TaskName = $script:OwnTask.ToLowerInvariant() })
        Resolve-OwnDedupTask -Tasks $lower -VolumeTaskName $script:OwnTask | Should -HaveCount 1
    }

    It 'answers an empty list when the folder holds nothing of ours' {
        $foreign = @([PSCustomObject]@{ TaskName = 'Initialization' })
        Resolve-OwnDedupTask -Tasks $foreign -VolumeTaskName $script:OwnTask | Should -HaveCount 0
    }

    It 'answers an empty list for an empty folder rather than asking for a value' {
        Resolve-OwnDedupTask -Tasks @() -VolumeTaskName $script:OwnTask | Should -HaveCount 0
    }
}

Describe 'Resolve-DedupScheduleReminder' {
    BeforeAll {
        $script:TreePath = 'Task Scheduler Library > Microsoft > Windows > ReFsDedupSvc'
        $script:ReminderTask = '{AA0DAF00-0000-0000-0000-100000000000}'
    }

    It 'names the time just chosen, so the user can see what was set without opening anything' {
        $lines = (Resolve-DedupScheduleReminder -DailyTime '08:00' -WeeklyDay 'Monday' `
                -WeeklyStart '17:30' -TaskTreePath $script:TreePath -WeeklyJob) -join "`n"
        $lines | Should -Match '08:00 daily'
        $lines | Should -Match 'Monday at 17:30 weekly'
    }

    It 'names no weekly time where no weekly task was created' {
        # Naming one sends the user hunting through Task Scheduler for a task that is not there.
        $lines = (Resolve-DedupScheduleReminder -DailyTime '08:00' -WeeklyDay 'Monday' `
                -WeeklyStart '17:30' -TaskTreePath $script:TreePath) -join "`n"
        $lines | Should -Match '08:00 daily\.'
        $lines | Should -Not -Match 'weekly'
        $lines | Should -Not -Match '17:30'
    }

    It 'gives the folder location, the admin steps and the Actions tab warning' {
        $lines = (Resolve-DedupScheduleReminder -DailyTime '17:00' -WeeklyDay 'Monday' `
                -WeeklyStart '17:30' -TaskTreePath $script:TreePath) -join "`n"
        $lines | Should -Match ([regex]::Escape($script:TreePath))
        $lines | Should -Match 'taskschd\.msc'
        $lines | Should -Match 'Ctrl\+Shift\+Enter'
        $lines | Should -Match 'Triggers tab'
        $lines | Should -Match 'Leave the Actions tab alone'
        $lines | Should -Match 'may belong to Windows or to earlier runs'
    }

    It 'returns plain lines rather than an object to unwrap' {
        Resolve-DedupScheduleReminder -DailyTime '11:00' -WeeklyDay 'Monday' -WeeklyStart '17:30' `
            -TaskTreePath $script:TreePath | Should -BeOfType [string]
    }

    It 'names each task that was read back, and says which job it is' {
        # Two drives scheduled at the same times are indistinguishable by their Triggers column, so
        # the times are not an answer to "which of these is mine".
        $lines = (Resolve-DedupScheduleReminder -DailyTime '17:00' -WeeklyDay 'Monday' `
                -WeeklyStart '17:30' -TaskTreePath $script:TreePath -VolumeTaskName $script:ReminderTask `
                -TaskNames @($script:ReminderTask, "$($script:ReminderTask)-Scrub") -WeeklyJob) -join "`n"
        $lines | Should -Match ([regex]::Escape("$($script:ReminderTask)  - the daily job"))
        $lines | Should -Match ([regex]::Escape("$($script:ReminderTask)-Scrub  - the weekly maintenance job"))
        $lines | Should -Match 'look for those names'
    }

    It 'names only what it was given, so it cannot promise a task that was never found' {
        # The run says a few lines earlier when no task was found; naming one here would contradict it.
        $lines = (Resolve-DedupScheduleReminder -DailyTime '11:00' -WeeklyDay 'Monday' `
                -WeeklyStart '17:30' -TaskTreePath $script:TreePath -VolumeTaskName $script:ReminderTask `
                -TaskNames @($script:ReminderTask)) -join "`n"
        $lines | Should -Match ([regex]::Escape("$($script:ReminderTask)  - the daily job"))
        $lines | Should -Not -Match 'Scrub'
    }

    It 'does not call the other tasks stale, because the folder holds live drives too' {
        $lines = (Resolve-DedupScheduleReminder -DailyTime '11:00' -WeeklyDay 'Monday' `
                -WeeklyStart '17:30' -TaskTreePath $script:TreePath -VolumeTaskName $script:ReminderTask `
                -TaskNames @($script:ReminderTask)) -join "`n"
        $lines | Should -Match 'to another drive'
        $lines | Should -Not -Match 'may belong to'
    }

    It 'falls back to the times when no task was read back' {
        # Nothing to name then, so the old wording is the only handle the user has left.
        foreach ($none in @(@(), @($null), @('   '))) {
            $lines = (Resolve-DedupScheduleReminder -DailyTime '11:00' -WeeklyDay 'Monday' `
                    -WeeklyStart '17:30' -TaskTreePath $script:TreePath -TaskNames $none `
                    -VolumeTaskName $script:ReminderTask) -join "`n"
            $lines | Should -Match 'whose Triggers column matches'
            $lines | Should -Not -Match 'named after the volume itself'
        }
    }

    Context 'the note about adding further triggers by hand' {
        It 'appears whether or not the tasks could be named' {
            foreach ($names in @(@(), @($script:ReminderTask))) {
                $lines = (Resolve-DedupScheduleReminder -DailyTime '17:00' -WeeklyDay 'Monday' `
                        -WeeklyStart '17:30' -TaskTreePath $script:TreePath -TaskNames $names `
                        -VolumeTaskName $script:ReminderTask) -join "`n"
                $lines | Should -Match 'one daily start time per volume'
                $lines | Should -Match 'add further triggers'
            }
        }

        It 'warns that the next schedule written removes them' {
            # Measured: a hand-added trigger sticks, and the next Set-ReFSDedupSchedule wipes it.
            $lines = (Resolve-DedupScheduleReminder -DailyTime '17:00' -WeeklyDay 'Monday' `
                    -WeeklyStart '17:30' -TaskTreePath $script:TreePath) -join "`n"
            $lines | Should -Match 'rerunning this script'
            $lines | Should -Match 'Set-ReFSDedupSchedule'
            $lines | Should -Match 'they are\s+removed'
        }

        It 'claims no more than was established, because no run on such a trigger was observed' {
            $lines = (Resolve-DedupScheduleReminder -DailyTime '17:00' -WeeklyDay 'Monday' `
                    -WeeklyStart '17:30' -TaskTreePath $script:TreePath) -join "`n"
            $lines | Should -Match 'has not been\s+confirmed'
        }
    }
}

Describe 'Request-DedupSchedule' {
    BeforeAll {
        # The menu text is not under test here, only what the answers do to the three fields.
        Mock Write-Host { }
    }

    It 'keeps the offered time when the user takes it' {
        Mock Read-Host { '1' }
        $chosen = Request-DedupSchedule -DailyTime '17:00' -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -DailyDurationHours 2 -DailyCpuPercent 60 -BlockDedup
        $chosen.DailyTime | Should -Be '17:00'
        $chosen.WeeklyDay | Should -Be 'Monday'
        $chosen.WeeklyStart | Should -Be '17:30'
    }

    It 'takes the three answers when the user picks the times' {
        $script:answers = @('2', '08:15', 'sat', '9:00')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        $chosen = Request-DedupSchedule -DailyTime '17:00' -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -DailyDurationHours 2 -DailyCpuPercent 60 -BlockDedup
        $chosen.DailyTime | Should -Be '08:15'
        $chosen.WeeklyDay | Should -Be 'Saturday'
        $chosen.WeeklyStart | Should -Be '09:00'
    }

    It 'keeps a daily time with minutes in it, which is why the question still asks for HH:MM' {
        $script:answers = @('2', '18:30', 'Mon', '17:30')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        $chosen = Request-DedupSchedule -DailyTime '17:00' -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -DailyDurationHours 2 -DailyCpuPercent 60 -BlockDedup
        $chosen.DailyTime | Should -Be '18:30'
    }

    It 'keeps each current value when the answer is empty' {
        $script:answers = @('2', '', '', '')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        $chosen = Request-DedupSchedule -DailyTime '17:00' -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -DailyDurationHours 2 -DailyCpuPercent 60 -BlockDedup
        $chosen.DailyTime | Should -Be '17:00'
        $chosen.WeeklyDay | Should -Be 'Monday'
        $chosen.WeeklyStart | Should -Be '17:30'
    }

    It 'keeps asking until each answer is one it can use' {
        # A comma separated list used to be accepted here; it is one answer among the rejected ones now.
        $script:answers = @('9', '2', '11:00,17:00', 'noon', '08:15', 'someday', 'Tue', '99:99', '7:30')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        $chosen = Request-DedupSchedule -DailyTime '17:00' -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -DailyDurationHours 2 -DailyCpuPercent 60 -BlockDedup
        $chosen.DailyTime | Should -Be '08:15'
        $chosen.WeeklyDay | Should -Be 'Tuesday'
        $chosen.WeeklyStart | Should -Be '07:30'
        $script:index | Should -Be 9
    }

    It 'never offers to take more than one daily time' {
        # The question that caused this: it invited a list, and only the last entry was ever written.
        # Answer 2 first, or the prompt under test never prints and the assertions pass on nothing.
        $script:answers = @('2', '08:15', 'Mon', '17:30')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        Request-DedupSchedule -DailyTime '17:00' -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -DailyDurationHours 2 -DailyCpuPercent 60 `
            -BlockDedup | Out-Null
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'Start time for the daily optimization' }
        Should -Not -Invoke Write-Host -ParameterFilter { $Object -match 'comma separated' }
        Should -Not -Invoke Write-Host -ParameterFilter { $Object -match 'own scheduled task' }
    }

    It 'says the daily job, not both jobs, run on mains power for a duration and CPU cap it names' {
        Mock Read-Host { '1' }
        Request-DedupSchedule -DailyTime '17:00' -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -DailyDurationHours 3 -DailyCpuPercent 45 `
            -BlockDedup | Out-Null
        Should -Invoke Write-Host -ParameterFilter {
            $Object -match 'The daily job runs on mains power only, for up to 3 hours, using at most 45% of the CPU\.'
        }
    }

    It 'asks nothing about a weekly job that cannot exist' {
        # Compression only: the user picks the daily time and is never asked for a day or a time
        # for maintenance Windows will refuse to schedule.
        $script:answers = @('2', '08:15')
        $script:index = 0
        Mock Read-Host { $script:answers[$script:index++] }
        $chosen = Request-DedupSchedule -DailyTime '17:00' -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -DailyDurationHours 2 -DailyCpuPercent 60
        $chosen.DailyTime | Should -Be '08:15'
        $script:index | Should -Be 2
    }

    It 'hands back the weekly values it was given when it asked about none' {
        Mock Read-Host { '1' }
        $chosen = Request-DedupSchedule -DailyTime '11:00' -DailyDaysLabel 'Monday-Friday' `
            -WeeklyDay 'Monday' -WeeklyStart '17:30' -WeeksInterval 1 -DailyDurationHours 2 -DailyCpuPercent 60
        $chosen.WeeklyDay | Should -Be 'Monday'
        $chosen.WeeklyStart | Should -Be '17:30'
    }

    It 'promises no time limit and no CPU share where neither applies' {
        Mock Read-Host { '1' }
        Request-DedupSchedule -DailyTime '11:00' -DailyDaysLabel 'Monday-Friday' `
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

Describe 'Resolve-UnmetPasswordRequirement' {
    BeforeAll {
        # The floor and ceiling are read out of the script in the file-level BeforeAll, so the
        # fixtures that are about length are built from them rather than from numbers of their own.
        $script:AtFloor = 'Ab1!' + ('c' * [math]::Max(0, $script:PasswordFloor - 4))
        $script:BelowFloor = $script:AtFloor.Substring(0, $script:AtFloor.Length - 1)
        $script:FloorMessage = "at least $script:PasswordFloor characters"
        $script:CeilingMessage = "at most $script:PasswordCeiling characters"

        function Get-Unmet {
            <# The call every test makes, so the two length arguments are not repeated in each. It
               unrolls like any function, so a caller wanting .Count wraps it in @() as the script
               does - the array a return statement carries out of a function is not one. #>
            param([Parameter(Mandatory)][AllowEmptyString()][string]$Plain)

            return @(Resolve-UnmetPasswordRequirement -Plain $Plain `
                    -MinimumLength $script:PasswordFloor -MaximumLength $script:PasswordCeiling)
        }
    }

    It 'answers nothing for a password that meets every rule' {
        @(Get-Unmet -Plain $script:AtFloor).Count | Should -Be 0
    }

    It 'names the length requirement one character below the floor, and not at it' {
        Get-Unmet -Plain $script:BelowFloor | Should -Contain $script:FloorMessage
        Get-Unmet -Plain $script:AtFloor | Should -Not -Contain $script:FloorMessage
    }

    It 'names the ceiling one character above it, and not at it' {
        # BitLocker answers 0x803100AA past its ceiling, so a longer password is refused here first.
        $atCeiling = 'Ab1!' + ('c' * ($script:PasswordCeiling - 4))
        Get-Unmet -Plain $atCeiling | Should -Not -Contain $script:CeilingMessage
        Get-Unmet -Plain ($atCeiling + 'c') | Should -Contain $script:CeilingMessage
    }

    It 'refuses an all-lowercase password for want of an uppercase letter' {
        # -notmatch would accept this: it is case-insensitive, so [A-Z] matches a lowercase letter.
        Get-Unmet -Plain 'abcdefg1!' | Should -Contain 'at least one uppercase letter'
    }

    It 'refuses an all-uppercase password for want of a lowercase letter' {
        Get-Unmet -Plain 'ABCDEFG1!' | Should -Contain 'at least one lowercase letter'
    }

    It 'names the digit requirement when there is no digit' {
        Get-Unmet -Plain 'Abcdefgh!' | Should -Contain 'at least one digit'
    }

    It 'names the special-character requirement when every character is alphanumeric' {
        Get-Unmet -Plain 'Abcdefg12' | Should -Contain 'at least one special character'
    }

    It 'does not accept a space as the special character' {
        Get-Unmet -Plain 'Abcdefg1 ' | Should -Contain 'at least one special character'
    }

    It 'refuses a password of nothing but spaces on all four class rules and no other' {
        # Named in the issue as untested. Spaces are printable ASCII and reach the floor, so this is
        # the one input where every class rule fires while the length and ASCII rules pass.
        $unmet = @(Get-Unmet -Plain (' ' * $script:PasswordFloor))
        $unmet.Count | Should -Be 4
        $unmet | Should -Not -Contain $script:FloorMessage
        $unmet | Should -Not -Contain 'printable ASCII characters only'
    }

    It 'accepts a space inside an otherwise valid password' {
        # Space is printable ASCII, so only the special-character rule refuses to count it.
        @(Get-Unmet -Plain 'Ab 1!cde').Count | Should -Be 0
    }

    It 'refuses a password Windows would refuse as non-ASCII, for <Name>' -TestCases @(
        @{ Name = 'a Cyrillic capital'; Code = 0x0416 }
        @{ Name = 'an Arabic-Indic digit'; Code = 0x0665 }
        @{ Name = 'an accented Latin letter'; Code = 0x00E9 }
    ) {
        # Built from code points so this file stays ASCII. Each of these satisfied the old negated
        # class or \d and was then refused by BitLocker as non-printable ASCII (0x803100A4).
        $unmet = @(Get-Unmet -Plain ('Abcdefg1!' + [char]$Code))
        $unmet.Count | Should -Be 1
        $unmet | Should -Contain 'printable ASCII characters only'
    }

    It 'refuses a control character, which is ASCII but not printable' {
        Get-Unmet -Plain ('Abcdefg1!' + [char]9) | Should -Contain 'printable ASCII characters only'
    }

    It 'does not count a non-ASCII digit as the digit' {
        # \d is Unicode in .NET, so it would take an Arabic-Indic five and call the rule met while
        # BitLocker refuses the password outright. The class is [0-9] for that reason.
        $unmet = @(Get-Unmet -Plain ('Abcdefg!' + [char]0x0665))
        $unmet | Should -Contain 'at least one digit'
        $unmet | Should -Contain 'printable ASCII characters only'
    }

    It 'counts only ASCII punctuation as the special character' {
        # The old class counted any non-Latin letter; this one is the printable ASCII range less
        # space and alphanumerics, so a Cyrillic capital no longer stands in for punctuation.
        $unmet = @(Get-Unmet -Plain ('Abcdefg1' + [char]0x0416))
        $unmet | Should -Contain 'at least one special character'
    }

    It 'names every unmet requirement at once rather than the first' {
        @(Get-Unmet -Plain '').Count | Should -Be 5
    }

    It 'answers in the order the prompt lists the requirements' {
        Get-Unmet -Plain '' | Should -Be @(
            $script:FloorMessage
            'at least one uppercase letter'
            'at least one lowercase letter'
            'at least one digit'
            'at least one special character'
        )
    }

    It 'takes the lengths from its arguments rather than from literals, <Name>' -TestCases @(
        @{ Name = 'inside both'; Floor = 4; Ceiling = 64; Plain = 'Ab1!'; Met = $true }
        @{ Name = 'under a raised floor'; Floor = 12; Ceiling = 64; Plain = 'Abcdefg1!'; Met = $false
            Message = 'at least 12 characters' }
        @{ Name = 'over a lowered ceiling'; Floor = 4; Ceiling = 8; Plain = 'Abcdefg1!'; Met = $false
            Message = 'at most 8 characters' }
    ) {
        $unmet = @(Resolve-UnmetPasswordRequirement -Plain $Plain -MinimumLength $Floor -MaximumLength $Ceiling)
        if ($Met) {
            $unmet.Count | Should -Be 0
        } else {
            $unmet | Should -Contain $Message
        }
    }
}
