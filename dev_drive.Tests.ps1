# Pester 5 checks for dev_drive.ps1.
#
# These never touch storage and never need administrator rights. They cover the two things where a
# wrong answer would be silent: the layout of the structures passed to virtdisk.dll, and the rules
# that decide what a typed answer means. Everything that partitions or formats stays manual.
#
#   Invoke-Pester -Path .\dev_drive.Tests.ps1

#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
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
        (Select-String -Path $script:ScriptPath -Pattern '^\$DevDriveMinSizeGB\s*=' ).Count | Should -Be 1
    }

    It 'sets the minimum to Microsoft''s documented 50 GB' {
        $line = Select-String -Path $script:ScriptPath -Pattern '^\$DevDriveMinSizeGB\s*=\s*(\d+)'
        [int]$line.Matches[0].Groups[1].Value | Should -Be 50
    }

    It 'declares the shrink head-room exactly once' {
        (Select-String -Path $script:ScriptPath -Pattern '^\$ShrinkSpareBytes\s*=' ).Count | Should -Be 1
    }

    It 'never lets an untyped 0 choose the overload of a Math comparison' {
        # A bare 0 is an Int32, so Max/Min bind their Int32 overload: the other argument is rounded,
        # and a byte count too big for an Int32 throws instead.
        Select-String -Path $script:ScriptPath -Pattern '\[math\]::(Max|Min)\(\s*0\s*,' |
            Should -BeNullOrEmpty
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

    It 'checks the fsutil devdrv trust exit code before declaring the drive trusted' {
        $content = Get-Content -Path $script:ScriptPath -Raw
        $content | Should -Match '(?ms)fsutil devdrv trust "\$devLetterColon" \| Out-Null\s*\r?\n\s*if \(\$LASTEXITCODE'
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

Describe 'Get-Win32ErrorText' {
    It 'includes the numeric code so it can be searched for' {
        Get-Win32ErrorText -Code 87 | Should -Match '\(error 87\)'
    }

    It 'includes the message Windows gives for the code' {
        Get-Win32ErrorText -Code 5 | Should -Match 'Access is denied'
    }
}

Describe 'Resolve-BitLockerSetupPlan' {
    It 'asks for a password only in virtual hard disk mode' -TestCases @(
        @{ Vhdx = $true;  Expected = $true }
        @{ Vhdx = $false; Expected = $false }
    ) {
        (Resolve-BitLockerSetupPlan -VhdxMode:$Vhdx).UsePasswordProtector | Should -Be $Expected
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
