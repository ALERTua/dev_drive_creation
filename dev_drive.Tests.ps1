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
}

Describe 'Get-Win32ErrorText' {
    It 'includes the numeric code so it can be searched for' {
        Get-Win32ErrorText -Code 87 | Should -Match '\(error 87\)'
    }

    It 'includes the message Windows gives for the code' {
        Get-Win32ErrorText -Code 5 | Should -Match 'Access is denied'
    }
}
