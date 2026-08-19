# -*- coding: utf-8 -*-
#Requires -RunAsAdministrator

<#
.SYNOPSIS
 Dev Drive creation script that guides users through creating a Dev Drive with BitLocker encryption and ReFS deduplication.
#>
param()

function Initialize-VirtDiskInterop {
    <#
        Declares the virtdisk.dll calls used to create and attach a .vhdx; only these can request
        ATTACH_VIRTUAL_DISK_FLAG_AT_BOOT. Layouts and constants come from virtdisk.h.
        Each parameter struct below inlines only the version arm the script asks for, which is safe
        because virtdisk reads the struct according to its Version field.
    #>
    if (([System.Management.Automation.PSTypeName]'DevDriveInterop.VirtDisk').Type) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace DevDriveInterop
{
    [StructLayout(LayoutKind.Sequential)]
    public struct VIRTUAL_STORAGE_TYPE
    {
        public UInt32 DeviceId;
        public Guid VendorId;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct CREATE_VIRTUAL_DISK_PARAMETERS
    {
        public UInt32 Version;
        // The union is 8-byte aligned, so its Version2 arm starts at offset 8, not 4.
        public UInt32 UnionAlignmentPadding;
        public Guid UniqueId;
        public UInt64 MaximumSize;
        public UInt32 BlockSizeInBytes;
        public UInt32 SectorSizeInBytes;
        public UInt32 PhysicalSectorSizeInBytes;
        [MarshalAs(UnmanagedType.LPWStr)] public string ParentPath;
        [MarshalAs(UnmanagedType.LPWStr)] public string SourcePath;
        public UInt32 OpenFlags;
        public VIRTUAL_STORAGE_TYPE ParentVirtualStorageType;
        public VIRTUAL_STORAGE_TYPE SourceVirtualStorageType;
        public Guid ResiliencyGuid;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct OPEN_VIRTUAL_DISK_PARAMETERS
    {
        public UInt32 Version;
        public UInt32 RWDepth;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ATTACH_VIRTUAL_DISK_PARAMETERS
    {
        public UInt32 Version;
        public UInt32 Reserved;
    }

    public static class VirtDisk
    {
        public const UInt32 VIRTUAL_STORAGE_TYPE_DEVICE_VHDX = 3;
        public static readonly Guid VIRTUAL_STORAGE_TYPE_VENDOR_MICROSOFT =
            new Guid("EC984AEC-A0F9-47E9-901F-71415A66345B");

        public const UInt32 CREATE_VIRTUAL_DISK_VERSION_2 = 2;
        public const UInt32 OPEN_VIRTUAL_DISK_VERSION_1 = 1;
        public const UInt32 OPEN_VIRTUAL_DISK_RWDEPTH_DEFAULT = 1;
        public const UInt32 ATTACH_VIRTUAL_DISK_VERSION_1 = 1;

        public const Int32 ERROR_NOT_SUPPORTED = 50;
        public const Int32 ERROR_INVALID_PARAMETER = 87;

        public const UInt32 VIRTUAL_DISK_ACCESS_NONE = 0x00000000;
        public const UInt32 VIRTUAL_DISK_ACCESS_ALL = 0x003F0000;

        public const UInt32 CREATE_VIRTUAL_DISK_FLAG_NONE = 0x00000000;
        public const UInt32 CREATE_VIRTUAL_DISK_FLAG_FULL_PHYSICAL_ALLOCATION = 0x00000001;

        public const UInt32 OPEN_VIRTUAL_DISK_FLAG_NONE = 0x00000000;

        public const UInt32 ATTACH_VIRTUAL_DISK_FLAG_PERMANENT_LIFETIME = 0x00000004;
        public const UInt32 ATTACH_VIRTUAL_DISK_FLAG_AT_BOOT = 0x00000400;

        [DllImport("virtdisk.dll", CharSet = CharSet.Unicode)]
        public static extern Int32 CreateVirtualDisk(
            ref VIRTUAL_STORAGE_TYPE VirtualStorageType,
            string Path,
            UInt32 VirtualDiskAccessMask,
            IntPtr SecurityDescriptor,
            UInt32 Flags,
            UInt32 ProviderSpecificFlags,
            ref CREATE_VIRTUAL_DISK_PARAMETERS Parameters,
            IntPtr Overlapped,
            out SafeFileHandle Handle);

        [DllImport("virtdisk.dll", CharSet = CharSet.Unicode)]
        public static extern Int32 OpenVirtualDisk(
            ref VIRTUAL_STORAGE_TYPE VirtualStorageType,
            string Path,
            UInt32 VirtualDiskAccessMask,
            UInt32 Flags,
            ref OPEN_VIRTUAL_DISK_PARAMETERS Parameters,
            out SafeFileHandle Handle);

        [DllImport("virtdisk.dll", CharSet = CharSet.Unicode)]
        public static extern Int32 AttachVirtualDisk(
            SafeFileHandle VirtualDiskHandle,
            IntPtr SecurityDescriptor,
            UInt32 Flags,
            UInt32 ProviderSpecificFlags,
            ref ATTACH_VIRTUAL_DISK_PARAMETERS Parameters,
            IntPtr Overlapped);
    }
}
'@
}

function Get-VhdxStorageType {
    $storageType = New-Object DevDriveInterop.VIRTUAL_STORAGE_TYPE
    $storageType.DeviceId = [DevDriveInterop.VirtDisk]::VIRTUAL_STORAGE_TYPE_DEVICE_VHDX
    $storageType.VendorId = [DevDriveInterop.VirtDisk]::VIRTUAL_STORAGE_TYPE_VENDOR_MICROSOFT
    return $storageType
}

function Get-Win32ErrorText {
    param([Parameter(Mandatory)][int]$Code)
    return "$([System.ComponentModel.Win32Exception]::new($Code).Message) (error $Code)"
}

function Get-VhdxAlignedSize {
    # A .vhdx virtual size must be a whole number of sectors, so a fractional GB has to be trimmed.
    param([Parameter(Mandatory)][uint64]$SizeBytes)
    return $SizeBytes - ($SizeBytes % 1MB)
}

function New-VirtualDiskFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][uint64]$SizeBytes,
        [Parameter(Mandatory)][ValidateSet('Dynamic', 'Fixed')][string]$DiskType
    )

    Initialize-VirtDiskInterop
    $storageType = Get-VhdxStorageType
    $SizeBytes = Get-VhdxAlignedSize -SizeBytes $SizeBytes

    $createParams = New-Object DevDriveInterop.CREATE_VIRTUAL_DISK_PARAMETERS
    $createParams.Version = [DevDriveInterop.VirtDisk]::CREATE_VIRTUAL_DISK_VERSION_2
    $createParams.MaximumSize = $SizeBytes

    $flags = if ($DiskType -eq 'Fixed') {
        [DevDriveInterop.VirtDisk]::CREATE_VIRTUAL_DISK_FLAG_FULL_PHYSICAL_ALLOCATION
    } else {
        [DevDriveInterop.VirtDisk]::CREATE_VIRTUAL_DISK_FLAG_NONE
    }

    $handle = $null
    try {
        $result = [DevDriveInterop.VirtDisk]::CreateVirtualDisk(
            [ref]$storageType,
            $Path,
            [DevDriveInterop.VirtDisk]::VIRTUAL_DISK_ACCESS_NONE,
            [IntPtr]::Zero,
            $flags,
            0,
            [ref]$createParams,
            [IntPtr]::Zero,
            [ref]$handle)
    }
    finally {
        if ($handle -and -not $handle.IsInvalid) { $handle.Close() }
    }

    if ($result -ne 0) {
        # A failed allocation can leave a partial file behind, which would block the next run.
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        throw "Could not create $Path`: $(Get-Win32ErrorText -Code $result)"
    }
}

function Add-VirtualDiskAttachment {
    <#
        Attaches the .vhdx. With -AtBoot, Windows also reattaches it on every startup and
        records it under HKLM\SYSTEM\CurrentControlSet\Control\AutoAttachVirtualDisks itself.
        Returns $true when automatic mounting was granted.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AtBoot
    )

    Initialize-VirtDiskInterop
    $storageType = Get-VhdxStorageType

    $openParams = New-Object DevDriveInterop.OPEN_VIRTUAL_DISK_PARAMETERS
    $openParams.Version = [DevDriveInterop.VirtDisk]::OPEN_VIRTUAL_DISK_VERSION_1
    $openParams.RWDepth = [DevDriveInterop.VirtDisk]::OPEN_VIRTUAL_DISK_RWDEPTH_DEFAULT

    $handle = $null
    $result = [DevDriveInterop.VirtDisk]::OpenVirtualDisk(
        [ref]$storageType,
        $Path,
        [DevDriveInterop.VirtDisk]::VIRTUAL_DISK_ACCESS_ALL,
        [DevDriveInterop.VirtDisk]::OPEN_VIRTUAL_DISK_FLAG_NONE,
        [ref]$openParams,
        [ref]$handle)

    if ($result -ne 0) {
        throw "Could not open $Path`: $(Get-Win32ErrorText -Code $result)"
    }

    try {
        $attachParams = New-Object DevDriveInterop.ATTACH_VIRTUAL_DISK_PARAMETERS
        $attachParams.Version = [DevDriveInterop.VirtDisk]::ATTACH_VIRTUAL_DISK_VERSION_1
        $lifetimeFlag = [DevDriveInterop.VirtDisk]::ATTACH_VIRTUAL_DISK_FLAG_PERMANENT_LIFETIME

        if ($AtBoot) {
            $result = [DevDriveInterop.VirtDisk]::AttachVirtualDisk(
                $handle, [IntPtr]::Zero,
                ($lifetimeFlag -bor [DevDriveInterop.VirtDisk]::ATTACH_VIRTUAL_DISK_FLAG_AT_BOOT),
                0, [ref]$attachParams, [IntPtr]::Zero)

            if ($result -eq 0) {
                return $true
            }

            # Only a build that does not know the flag is worth retrying without it. Anything else -
            # a sharing violation, access denied - would fail the same way twice.
            $flagUnsupported = $result -in @(
                [DevDriveInterop.VirtDisk]::ERROR_NOT_SUPPORTED,
                [DevDriveInterop.VirtDisk]::ERROR_INVALID_PARAMETER)

            if (-not $flagUnsupported) {
                throw "Could not attach $Path`: $(Get-Win32ErrorText -Code $result)"
            }

            Write-Host "This Windows build does not support mounting at startup: $(Get-Win32ErrorText -Code $result)" -ForegroundColor Yellow
            Write-Host "Attaching without it." -ForegroundColor Yellow
        }

        $result = [DevDriveInterop.VirtDisk]::AttachVirtualDisk(
            $handle, [IntPtr]::Zero, $lifetimeFlag, 0, [ref]$attachParams, [IntPtr]::Zero)

        # A refused first attempt may still have attached the disk, which makes the retry fail.
        if ($result -ne 0 -and -not (Get-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue).Attached) {
            throw "Could not attach $Path`: $(Get-Win32ErrorText -Code $result)"
        }
    }
    finally {
        if ($handle -and -not $handle.IsInvalid) { $handle.Close() }
    }

    return $false
}

function Prompt-BitLockerChoice {
    param([switch]$VhdxMode)

    Write-Host "`nDo you want to enable BitLocker encryption for the Dev Drive?" -ForegroundColor Cyan
    Write-Host "BitLocker provides security but may impact performance." -ForegroundColor White
    if ($VhdxMode) {
        Write-Host "If the volume hosting the .vhdx file is itself encrypted, its contents are already" -ForegroundColor Yellow
        Write-Host "covered, and Microsoft does not recommend encrypting the virtual disk as well." -ForegroundColor Yellow
    }
    Write-Host "1. Yes, enable BitLocker encryption" -ForegroundColor White
    Write-Host "2. No, skip BitLocker encryption" -ForegroundColor White
    Write-Host ""

    while ($true) {
        $choice = Read-Host "Enter your choice (1 or 2)"
        if ($choice -eq "1") {
            return $true
        } elseif ($choice -eq "2") {
            return $false
        } else {
            Write-Host "Invalid choice. Please enter 1 or 2." -ForegroundColor Red
        }
    }
}

function Prompt-DeduplicationChoice {
    Write-Host "`nDo you want to enable ReFS deduplication for the Dev Drive?" -ForegroundColor Cyan
    Write-Host "Deduplication saves disk space by eliminating duplicate data." -ForegroundColor White
    Write-Host "1. Yes, enable deduplication only (recommended for most users)" -ForegroundColor White
    Write-Host "2. Yes, enable deduplication + compression (configure compression settings)" -ForegroundColor White
    Write-Host "3. No, skip deduplication (maximum performance, less space savings)" -ForegroundColor White
    Write-Host ""

    while ($true) {
        $choice = Read-Host "Enter your choice (1, 2 or 3)"
        if ($choice -eq "1") {
            return "Dedup"
        } elseif ($choice -eq "2") {
            return "DedupAndCompress"
        } elseif ($choice -eq "3") {
            return "None"
        } else {
            Write-Host "Invalid choice. Please enter 1, 2 or 3." -ForegroundColor Red
        }
    }
}

function Prompt-CompressionFormat {
    Write-Host "`nChoose compression format:" -ForegroundColor Cyan
    Write-Host "1. LZ4: Fast compression with good balance of speed and compression ratio" -ForegroundColor White
    Write-Host "2. ZSTD: Better compression ratio but uses more CPU (allows custom compression level)" -ForegroundColor White
    Write-Host ""

    while ($true) {
        $choice = Read-Host "Enter your choice (1 or 2)"
        if ($choice -eq "1") {
            return "LZ4"
        } elseif ($choice -eq "2") {
            return "ZSTD"
        } else {
            Write-Host "Invalid choice. Please enter 1 or 2." -ForegroundColor Red
        }
    }
}

function Prompt-CompressionLevel {
    Write-Host "`nChoose ZSTD compression level (1-9):" -ForegroundColor Cyan
    Write-Host "Lower levels (1-3): Faster compression, less CPU usage" -ForegroundColor White
    Write-Host "Medium levels (4-6): Balanced speed and compression" -ForegroundColor White
    Write-Host "Higher levels (7-9): Better compression, more CPU usage" -ForegroundColor White
    Write-Host ""

    while ($true) {
        $level = Read-Host "Enter compression level (1-9)"
        if ($level -match '^[1-9]$') {
            return [int]$level
        } else {
            Write-Host "Invalid level. Please enter a number between 1 and 9." -ForegroundColor Red
        }
    }
}

function Resolve-DevDriveSizeInput {
    <#
        Decides what one typed answer to the size question means. Kept free of Read-Host and of
        any storage call so it can be tested directly. Rejection is $null when the answer is good.
    #>
    param(
        [AllowEmptyString()][string]$Answer,
        [Parameter(Mandatory)][decimal]$MinGB,
        [Parameter(Mandatory)][decimal]$MaxGB,
        [switch]$AllowEmpty,
        [switch]$MaxIsAdvisory
    )

    $result = [PSCustomObject]@{ Rejection = $null; SizeGB = $null; ExceedsMax = $false }

    if ([string]::IsNullOrWhiteSpace($Answer)) {
        if ($AllowEmpty) {
            $result.SizeGB = $MaxGB
            return $result
        }
        $result.Rejection = 'NotANumber'
        return $result
    }

    if ($Answer -notmatch '^\d+\.?\d*$') {
        $result.Rejection = 'NotANumber'
        return $result
    }

    $parsed = [decimal]$Answer
    if ($parsed -lt $MinGB) {
        $result.Rejection = 'BelowMinimum'
        return $result
    }
    if ($parsed -gt $MaxGB) {
        if (-not $MaxIsAdvisory) {
            $result.Rejection = 'AboveMaximum'
            return $result
        }
        $result.ExceedsMax = $true
    }

    $result.SizeGB = $parsed
    return $result
}

function Prompt-DevDriveSizeGB {
    <#
        The one size question for all three creation modes. -MaxIsAdvisory warns instead of
        rejecting, for a dynamically expanding disk that is allowed to outgrow its host volume.
    #>
    param(
        [Parameter(Mandatory)][decimal]$MaxGB,
        [Parameter(Mandatory)][string]$Subject,
        [switch]$AllowMaxOnEmpty,
        [switch]$MaxIsAdvisory
    )

    $maxHint = if ($AllowMaxOnEmpty) { "max: $MaxGB, press Enter for max" } else { "max: $MaxGB" }

    while ($true) {
        $answer = Read-Host "Enter $Subject in GB (min: $DevDriveMinSizeGB, $maxHint)"

        $verdict = Resolve-DevDriveSizeInput -Answer $answer -MinGB $DevDriveMinSizeGB -MaxGB $MaxGB `
            -AllowEmpty:$AllowMaxOnEmpty -MaxIsAdvisory:$MaxIsAdvisory

        if ($verdict.Rejection -eq 'NotANumber') {
            Write-Host "Invalid $Subject. Please enter a positive decimal number." -ForegroundColor Red
            continue
        }
        if ($verdict.Rejection -eq 'BelowMinimum') {
            Write-Host "$Subject must be at least $DevDriveMinSizeGB GB. Please enter a larger value." -ForegroundColor Red
            continue
        }
        if ($verdict.Rejection -eq 'AboveMaximum') {
            Write-Host "$Subject cannot exceed $MaxGB GB. Please enter a smaller value." -ForegroundColor Red
            continue
        }

        if ($AllowMaxOnEmpty -and [string]::IsNullOrWhiteSpace($answer)) {
            Write-Host "Using maximum available space: $($verdict.SizeGB) GB" -ForegroundColor Green
        }
        if ($verdict.ExceedsMax) {
            Write-Host "Warning: only $MaxGB GB is available, less than the $($verdict.SizeGB) GB you asked for." -ForegroundColor Yellow
            Write-Host "The Dev Drive will report its full size but run out of space early." -ForegroundColor Yellow
        }

        return $verdict.SizeGB
    }
}

function Read-StrongPassword {
    while ($true) {
        $secure = Read-Host "Enter password (min 8 chars, incl. upper, lower, digit, special)" -AsSecureString
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        )

        # Build validation flags
        $errors = @()
        if ($plain.Length -lt 8)                  { $errors += "at least 8 characters" }
        if ($plain -notmatch '[A-Z]')             { $errors += "at least one uppercase letter" }
        if ($plain -notmatch '[a-z]')             { $errors += "at least one lowercase letter" }
        if ($plain -notmatch '\d')                { $errors += "at least one digit" }
        if ($plain -notmatch '[^a-zA-Z\d\s]')     { $errors += "at least one special character" }

        if ($errors.Count -eq 0) {
            return $secure  # All good
        }

        # Output errors
        Write-Host "Password does not meet the following requirement(s):" -ForegroundColor Red
        foreach ($e in $errors) {
            Write-Host " - $e" -ForegroundColor Yellow
        }
    }
}

function Show-DriveSelection {
    Write-Host "`nSelect the physical drive where you want to create your Dev Drive:`n" -ForegroundColor Cyan

    $disks = Get-Disk | Where-Object { $_.BusType -ne 'Unknown' } | Sort-Object Number

    foreach ($disk in $disks) {
        $diskNumber = $disk.Number
        $diskSizeGB = [math]::Round($disk.Size / 1GB, 2)

        # Calculate allocated space more accurately
        $partitions = Get-Partition -DiskNumber $diskNumber
        $allocatedSize = 0
        foreach ($partition in $partitions) {
            # Only count actual data partitions, not system/reserved
            if ($partition.Type -eq 'Basic' -or $partition.Type -eq 'Dynamic' -or $partition.DriveLetter) {
                $allocatedSize += $partition.Size
            }
        }

        $freeSpaceGB = [math]::Round(($disk.Size - $allocatedSize) / 1GB, 2)

        Write-Host "Disk $diskNumber`: $($disk.FriendlyName)" -ForegroundColor Yellow
        Write-Host "  Size: $diskSizeGB GB" -ForegroundColor White
        Write-Host "  Free Space: $freeSpaceGB GB" -ForegroundColor Green

        # Show drive letters on this disk
        $driveLetters = ($disk | Get-Partition | Where-Object { $_.DriveLetter } | Select-Object -ExpandProperty DriveLetter) -join ", "
        if ($driveLetters) {
            Write-Host "  Drives: $driveLetters" -ForegroundColor Gray
        }
        Write-Host ""
    }
}

function Select-DriveMode {
    Write-Host "`nChoose Dev Drive creation method:" -ForegroundColor Cyan
    Write-Host "1. Use UNALLOCATED FREE SPACE on a physical drive" -ForegroundColor White
    Write-Host "2. SHRINK an existing logical drive to create space" -ForegroundColor White
    Write-Host "3. Create a VIRTUAL HARD DISK (.vhdx file) on an existing drive" -ForegroundColor White
    Write-Host "4. Exit" -ForegroundColor White
    Write-Host ""

    while ($true) {
        $choice = Read-Host "Enter your choice (1, 2, 3 or 4)"
        if ($choice -eq "1") {
            return "FreeSpace"
        } elseif ($choice -eq "2") {
            return "ShrinkDrive"
        } elseif ($choice -eq "3") {
            return "Vhdx"
        } elseif ($choice -eq "4") {
            exit 0
        } else {
            Write-Host "Invalid choice. Please enter 1, 2, 3 or 4." -ForegroundColor Red
        }
    }
}

function Resolve-VhdxPathInput {
    <#
        The part of the path check that needs no disk: shape, extension, and canonical form with an
        upper case drive letter. Rejection is $null when the path is usable.
    #>
    param([AllowEmptyString()][string]$Answer)

    $result = [PSCustomObject]@{ Rejection = $null; Path = $null }

    if ([string]::IsNullOrWhiteSpace($Answer)) {
        $result.Rejection = 'Empty'
        return $result
    }

    # A network path or a drive-relative one like D:file.vhdx would pass IsPathRooted and then
    # resolve somewhere the user never named, so require a drive letter and a separator.
    if ($Answer -notmatch '^[A-Za-z]:\\') {
        $result.Rejection = 'NotALocalPath'
        return $result
    }

    $full = [System.IO.Path]::GetFullPath($Answer)
    $full = $full.Substring(0, 1).ToUpper() + $full.Substring(1)

    if ([System.IO.Path]::GetExtension($full) -ne '.vhdx') {
        $result.Rejection = 'WrongExtension'
        return $result
    }

    $result.Path = $full
    return $result
}

function Prompt-VhdxPath {
    Write-Host "`n=== VIRTUAL HARD DISK LOCATION ===" -ForegroundColor Cyan
    Write-Host "Enter the full path of the .vhdx file to create, for example D:\DevDrive.vhdx" -ForegroundColor White
    Write-Host "A per-user directory is recommended to avoid sharing the Dev Drive unintentionally." -ForegroundColor Gray
    Write-Host ""

    while ($true) {
        $verdict = Resolve-VhdxPathInput -Answer (Read-Host "Path of the .vhdx file").Trim('"', ' ')

        if ($verdict.Rejection -eq 'Empty') {
            Write-Host "Path cannot be empty." -ForegroundColor Red
            continue
        }
        if ($verdict.Rejection -eq 'NotALocalPath') {
            Write-Host "Enter a path on a local drive, for example D:\DevDrive.vhdx" -ForegroundColor Red
            continue
        }
        if ($verdict.Rejection -eq 'WrongExtension') {
            Write-Host "The file name must end with .vhdx" -ForegroundColor Red
            continue
        }

        $answer = $verdict.Path

        if (Test-Path -LiteralPath $answer) {
            Write-Host "$answer already exists. Choose a different name, or dismount and delete it first." -ForegroundColor Red
            continue
        }

        $parent = Split-Path -Path $answer -Parent
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            Write-Host "The folder $parent does not exist. Create it first, or enter another path." -ForegroundColor Red
            continue
        }

        # Dev Drive is unsupported inside a VHDX that lives on a removable disk.
        $hostLetter = [char]$answer[0]
        $hostVolume = @(Get-Volume -DriveLetter $hostLetter -ErrorAction SilentlyContinue)
        if ($hostVolume.Count -ne 1) {
            Write-Host "Could not read drive $hostLetter`:. Enter a path on a local fixed drive." -ForegroundColor Red
            continue
        }
        if ($hostVolume[0].DriveType -ne 'Fixed') {
            Write-Host "Drive $hostLetter`: is $($hostVolume[0].DriveType), not Fixed." -ForegroundColor Red
            Write-Host "Windows does not support a Dev Drive inside a VHDX on a removable disk." -ForegroundColor Yellow
            continue
        }

        return $answer
    }
}

function Prompt-VhdxDiskType {
    Write-Host "`nChoose the virtual hard disk type:" -ForegroundColor Cyan
    Write-Host "1. Dynamically expanding: the file grows as data is written (recommended)" -ForegroundColor White
    Write-Host "2. Fixed size: the file claims its full size immediately, which takes a while" -ForegroundColor White
    Write-Host ""

    while ($true) {
        $choice = Read-Host "Enter your choice (1 or 2)"
        if ($choice -eq "1") {
            return "Dynamic"
        } elseif ($choice -eq "2") {
            return "Fixed"
        } else {
            Write-Host "Invalid choice. Please enter 1 or 2." -ForegroundColor Red
        }
    }
}

function Prompt-VhdxSize {
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [Parameter(Mandatory)][ValidateSet('Dynamic', 'Fixed')][string]$DiskType
    )

    $hostLetter = [char]$VhdxPath[0]
    # Keep a gigabyte spare so a fixed size disk cannot fill the host volume to the last byte.
    $hostUsableBytes = (Get-Volume -DriveLetter $hostLetter).SizeRemaining - 1GB
    $hostFreeGB = [math]::Floor($hostUsableBytes / 1GB * 100) / 100

    if ($DiskType -eq 'Fixed' -and $hostUsableBytes -lt ($DevDriveMinSizeGB * 1GB)) {
        throw "Drive $hostLetter`: has $hostFreeGB GB to spare, less than the $DevDriveMinSizeGB GB a fixed size Dev Drive needs. Choose a dynamically expanding disk or another drive."
    }

    Write-Host "`nDrive $hostLetter`: has $hostFreeGB GB to spare." -ForegroundColor Cyan
    if ($DiskType -eq 'Fixed') {
        Write-Host "A fixed size disk takes all of its space right away, so it cannot exceed that." -ForegroundColor White
    } else {
        Write-Host "A dynamically expanding disk may be larger than the free space, but it will" -ForegroundColor White
        Write-Host "fail once the host drive fills up." -ForegroundColor White
    }
    Write-Host ""

    return Prompt-DevDriveSizeGB -MaxGB $hostFreeGB -Subject 'Dev Drive size' -MaxIsAdvisory:($DiskType -eq 'Dynamic')
}

function Prompt-AutoAttachChoice {
    Write-Host "`nMount this virtual hard disk automatically on every Windows startup?" -ForegroundColor Cyan
    Write-Host "Without this, the Dev Drive disappears after each restart until mounted by hand." -ForegroundColor White
    Write-Host "1. Yes, register it for automatic mounting (recommended)" -ForegroundColor White
    Write-Host "2. No, I will mount it myself" -ForegroundColor White
    Write-Host ""

    while ($true) {
        $choice = Read-Host "Enter your choice (1 or 2)"
        if ($choice -eq "1") {
            return $true
        } elseif ($choice -eq "2") {
            return $false
        } else {
            Write-Host "Invalid choice. Please enter 1 or 2." -ForegroundColor Red
        }
    }
}

Write-Host "Dev Drive creation script with BitLocker encryption and ReFS deduplication." -ForegroundColor Green

# Check Windows version
$windows_build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuild).CurrentBuild -as [int]
$windows_build_min = 26100

if ($windows_build -ge $windows_build_min) {
    Write-Host "Windows Build $windows_build is OK" -ForegroundColor Gray
} else {
    Write-Error "Your Windows build $windows_build is lower than $windows_build_min. Please update before using the script."
    exit 0
}

# Microsoft's documented minimum size for a Dev Drive volume (https://learn.microsoft.com/en-us/windows/dev-drive/)
$DevDriveMinSizeGB = 50

# Set default values for deduplication and compression settings
$DedupMode = 'Dedup'
$CompressionFormat = 'LZ4'
$CompressionLevel = 5
$RunInitialJob = $true
$SkipBitLocker = $false

# Interactive mode only - Gather all information first
Write-Host "`n=== GATHERING CONFIGURATION ===" -ForegroundColor Cyan
Write-Host "Let's collect all the information needed to create your Dev Drive." -ForegroundColor White
Write-Host "No changes will be made until you confirm the plan.`n" -ForegroundColor White

# Step 1: Ask user to select the creation mode
$mode = Select-DriveMode

# Step 2: Ask user to select a physical drive. A .vhdx lives on an existing volume instead.
if ($mode -ne "Vhdx") {
    Show-DriveSelection

    Write-Host "`n=== SELECT PHYSICAL DRIVE ===" -ForegroundColor Cyan
    Write-Host "Enter the disk number you want to use for Dev Drive creation:" -ForegroundColor White

    while ($true) {
        $selectedDiskInput = Read-Host "Disk number"
        if ($selectedDiskInput -match '^\d+$') {
            $selectedDiskNumber = [int]$selectedDiskInput
            # Validate that the disk exists
            $diskExists = Get-Disk -Number $selectedDiskNumber -ErrorAction SilentlyContinue
            if ($diskExists) {
                $DiskNumber = $selectedDiskNumber
                $selectedDiskName = $diskExists.FriendlyName
                Write-Host "Selected Disk $DiskNumber`: $selectedDiskName" -ForegroundColor Green
                break
            } else {
                Write-Host "Disk $selectedDiskNumber does not exist. Please select a valid disk number." -ForegroundColor Red
            }
        } else {
            Write-Host "Invalid input. Please enter a number (0, 1, 2, etc.)." -ForegroundColor Red
        }
    }
}

# Step 3: Get mode-specific parameters
if ($mode -eq "FreeSpace") {
    # Get disk info for free space calculation
    $selectedDisk = Get-Disk -Number $DiskNumber
    $partitions = Get-Partition -DiskNumber $DiskNumber
    $allocatedSize = 0
    foreach ($partition in $partitions) {
        if ($partition.Type -eq 'Basic' -or $partition.Type -eq 'Dynamic' -or $partition.DriveLetter) {
            $allocatedSize += $partition.Size
        }
    }
    $freeSpace = $selectedDisk.Size - $allocatedSize
    # Floor (not round) so the displayed/accepted maximum is never above the real free space
    $freeSpaceGB = [math]::Floor($freeSpace / 1GB * 100) / 100

    Write-Host "`nDisk $DiskNumber has $freeSpaceGB GB of free space available." -ForegroundColor Cyan

    if ($freeSpace -lt ($DevDriveMinSizeGB * 1GB)) {
        Write-Host "Disk $DiskNumber only has $freeSpaceGB GB of free space, which is below the $DevDriveMinSizeGB GB minimum required for a Dev Drive." -ForegroundColor Red
        Write-Host "Exiting. Please choose a different disk or free up more space, then run the script again." -ForegroundColor Yellow
        exit 1
    }

    $SizeGB = Prompt-DevDriveSizeGB -MaxGB $freeSpaceGB -Subject 'Dev Drive size' -AllowMaxOnEmpty

    $creationMethod = "Use $SizeGB GB of free space from Disk $DiskNumber ($selectedDiskName)"
} elseif ($mode -eq "ShrinkDrive") {
    Write-Host "`n=== SELECT DRIVE TO SHRINK ===" -ForegroundColor Cyan
    Write-Host "Available drives on Disk $DiskNumber for shrinking:" -ForegroundColor White

    # Show only drives on the selected disk
    $volumesOnDisk = Get-Volume | Where-Object {
        $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and
        (Get-Partition -DriveLetter $_.DriveLetter).DiskNumber -eq $DiskNumber
    } | Sort-Object DriveLetter

    if ($volumesOnDisk.Count -eq 0) {
        Write-Host "No shrinkable drives found on Disk $DiskNumber." -ForegroundColor Red
        Write-Host "Please select a different disk or use free space mode." -ForegroundColor Yellow
        exit 1
    }

    foreach ($vol in $volumesOnDisk) {
        $letter = $vol.DriveLetter
        $sizeGB = [math]::Round($vol.Size / 1GB, 2)
        $freeGB = [math]::Round($vol.SizeRemaining / 1GB, 2)
        $shrinkableGB = [math]::Max(0, $freeGB - 5)

        Write-Host "  Drive $letter`: $($vol.FileSystemLabel)" -ForegroundColor Yellow
        Write-Host "    Total: $sizeGB GB | Free: $freeGB GB | Shrinkable: ~$shrinkableGB GB" -ForegroundColor White
    }
    Write-Host ""

    while ($true) {
        $selectedDrive = Read-Host "Enter drive letter to shrink"
        if ($selectedDrive -match '^[A-Z]$') {
            # Validate that the drive exists on the selected disk
            $driveOnDisk = $volumesOnDisk | Where-Object { $_.DriveLetter -eq $selectedDrive }
            if ($driveOnDisk) {
                $DriveLetter = $selectedDrive
                $driveFreeGB = [math]::Round($driveOnDisk.SizeRemaining / 1GB, 2)
                $driveLabel = $driveOnDisk.FileSystemLabel
                Write-Host "Selected Drive $DriveLetter`: $driveLabel ($driveFreeGB GB free)" -ForegroundColor Green

                # Get the real shrinkable size from Windows
                Write-Host "Getting Partition shrinkable size information (this may take ~30 seconds)..." -ForegroundColor Cyan
                try {
                    $partitionInfo = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
                    $supportedSizes = $partitionInfo | Get-PartitionSupportedSize -ErrorAction Stop
                    $minSizeGB = [math]::Round($supportedSizes.SizeMin / 1GB, 2)
                    $realMaxShrinkableBytes = $partitionInfo.Size - $supportedSizes.SizeMin
                    # Floor (not round) so the displayed/accepted maximum is never above the real shrinkable size
                    $realMaxShrinkableGB = [math]::Floor($realMaxShrinkableBytes / 1GB * 100) / 100

                    Write-Host "Shrinkable size information:" -ForegroundColor Yellow
                    Write-Host "  Current partition size: $([math]::Round($partitionInfo.Size / 1GB, 2)) GB" -ForegroundColor White
                    Write-Host "  Minimum partition size: $minSizeGB GB" -ForegroundColor White
                    Write-Host "  Maximum shrinkable: $realMaxShrinkableGB GB" -ForegroundColor Green
                    Write-Host ""
                    Write-Host "Note: Windows allows shrinking by the size of starting from the end of the drive disk space to the nearest written file block. Disk Fragmentation can affect this. If Windows does not allow for a drive to be shrunk, please use third-party tools (e.g. AOMEI)." -ForegroundColor Gray
                    Write-Host ""
                }
                catch {
                    Write-Host "Could not determine real shrinkable size. Using estimated values." -ForegroundColor Yellow
                    $realMaxShrinkableBytes = [math]::Max(0, $driveOnDisk.SizeRemaining - (5 * 1GB))
                    $realMaxShrinkableGB = [math]::Floor($realMaxShrinkableBytes / 1GB * 100) / 100
                    Write-Host "Estimated maximum shrinkable: $realMaxShrinkableGB GB" -ForegroundColor Green
                    # Set partitionInfo to null so we know to get it again later
                    $partitionInfo = $null
                }

                break
            } else {
                Write-Host "Drive $selectedDrive is not on Disk $DiskNumber. Please select a drive from the list above." -ForegroundColor Red
            }
        } else {
            Write-Host "Invalid drive letter. Please enter a single letter A-Z." -ForegroundColor Red
        }
    }

    if ($realMaxShrinkableBytes -lt ($DevDriveMinSizeGB * 1GB)) {
        if ($partitionInfo) {
            Write-Host "Drive $DriveLetter can only be shrunk by $realMaxShrinkableGB GB, which is below the $DevDriveMinSizeGB GB minimum required for a Dev Drive." -ForegroundColor Red
        } else {
            Write-Host "Drive $DriveLetter can only be shrunk by an estimated $realMaxShrinkableGB GB, which is below the $DevDriveMinSizeGB GB minimum required for a Dev Drive." -ForegroundColor Red
        }
        Write-Host "Exiting. Please choose a different drive or use free space mode, then run the script again." -ForegroundColor Yellow
        exit 1
    }

    $ShrinkGB = Prompt-DevDriveSizeGB -MaxGB $realMaxShrinkableGB -Subject 'Shrink amount'
    $SizeGB = $ShrinkGB  # The Dev Drive fills exactly the space that was freed

    $creationMethod = "Shrink Drive $DriveLetter ($driveLabel) by $ShrinkGB GB to create $ShrinkGB GB Dev Drive"
} else { # Vhdx
    $VhdxPath = Prompt-VhdxPath
    $VhdxDiskType = Prompt-VhdxDiskType
    $SizeGB = Prompt-VhdxSize -VhdxPath $VhdxPath -DiskType $VhdxDiskType
    $VhdxAutoAttach = Prompt-AutoAttachChoice
}

# Ask about BitLocker encryption
$enableBitLocker = Prompt-BitLockerChoice -VhdxMode:($mode -eq "Vhdx")
$SkipBitLocker = -not $enableBitLocker
$bitLockerChoice = if ($enableBitLocker) { "Enable BitLocker encryption" } else { "Skip BitLocker encryption" }

# Ask about deduplication
$dedupChoice = Prompt-DeduplicationChoice
if ($dedupChoice -eq "None") {
    $SkipDeduplication = $true
    $deduplicationChoice = "Skip deduplication"
} elseif ($dedupChoice -eq "DedupAndCompress") {
    $DedupMode = $dedupChoice

    # Ask for compression format
    $CompressionFormat = Prompt-CompressionFormat

    # Ask for compression level if ZSTD is selected
    if ($CompressionFormat -eq "ZSTD") {
        $CompressionLevel = Prompt-CompressionLevel
        $deduplicationChoice = "Enable deduplication with ZSTD compression (level $CompressionLevel)"
        Write-Host "Selected ZSTD compression with level $CompressionLevel" -ForegroundColor Green
    } else {
        $deduplicationChoice = "Enable deduplication with LZ4 compression"
        Write-Host "Selected LZ4 compression" -ForegroundColor Green
    }
} else {
    $DedupMode = $dedupChoice
    $deduplicationChoice = "Enable deduplication only (no compression)"
    Write-Host "Selected deduplication only (no compression)" -ForegroundColor Green
}

# Display summary and ask for confirmation
Write-Host "`n"
Write-Host "===============================================================================" -ForegroundColor Cyan
Write-Host "                        DEV DRIVE CREATION PLAN" -ForegroundColor Cyan
Write-Host "===============================================================================" -ForegroundColor Cyan
Write-Host "" -ForegroundColor Cyan

# Unified action list with all details
if ($mode -eq "ShrinkDrive") {
    Write-Host "* Shrink Drive $DriveLetter ($driveLabel) by $ShrinkGB GB to free up space" -ForegroundColor White
}
if ($mode -eq "Vhdx") {
    Write-Host "* Create a $SizeGB GB $VhdxDiskType virtual hard disk at $VhdxPath" -ForegroundColor White
    if ($VhdxDiskType -eq 'Fixed') {
        Write-Host "  (a fixed size disk claims all of its space up front, which takes a while)" -ForegroundColor Gray
    }
    Write-Host "* Format the attached virtual disk as a Dev Drive using ReFS" -ForegroundColor White
    if ($VhdxAutoAttach) {
        Write-Host "* Register the virtual disk to be mounted on every Windows startup" -ForegroundColor White
    } else {
        Write-Host "* Skip automatic mounting; the Dev Drive is gone after every restart until mounted by hand" -ForegroundColor White
    }
} else {
    Write-Host "* Create $SizeGB GB Dev Drive on Disk $DiskNumber ($selectedDiskName) using ReFS" -ForegroundColor White
}

if (-not $SkipBitLocker) {
    Write-Host "* Enable BitLocker encryption with Azure AD recovery key backup" -ForegroundColor White
}

if (-not $SkipDeduplication) {
    if ($DedupMode -eq "DedupAndCompress") {
        Write-Host "* Enable ReFS deduplication with $CompressionFormat compression (level $CompressionLevel)" -ForegroundColor White
    } else {
        Write-Host "* Enable ReFS deduplication only (no compression)" -ForegroundColor White
    }
    Write-Host "* Schedule daily optimization jobs at 11:00 and 17:00 (AC power only)" -ForegroundColor White
    Write-Host "* Schedule weekly maintenance job every Monday at 17:30" -ForegroundColor White
} else {
    Write-Host "* Skip deduplication and compression setup" -ForegroundColor White
}

Write-Host "* Mark Dev Drive as trusted for Windows Defender performance" -ForegroundColor White
Write-Host "* Run initial optimization job to prepare the drive" -ForegroundColor White

Write-Host "" -ForegroundColor Cyan
Write-Host "===============================================================================" -ForegroundColor Cyan

$confirmation = Read-Host "Are you ready to proceed with Dev Drive creation? (yes/no)"
if ($confirmation -notmatch "^(yes|y)$") {
    Write-Host "`nDev Drive creation cancelled. No changes were made." -ForegroundColor Yellow
    exit 0
}

Write-Host "`nStarting Dev Drive creation..." -ForegroundColor Green

try {
    if ($mode -eq "FreeSpace") {
        # Check disk and free space
        Write-Host "Checking disk $DiskNumber for available free space..." -ForegroundColor Green
        $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop

        # Get total disk size and calculate allocated space
        $diskSize = $disk.Size

        # Calculate allocated space more accurately
        $partitions = Get-Partition -DiskNumber $DiskNumber
        $allocatedSize = 0
        foreach ($partition in $partitions) {
            # Only count actual data partitions, not system/reserved
            if ($partition.Type -eq 'Basic' -or $partition.Type -eq 'Dynamic' -or $partition.DriveLetter) {
                $allocatedSize += $partition.Size
            }
        }

        # Calculate free space
        $freeSpace = $diskSize - $allocatedSize
        $freeSpaceGB = [math]::Round($freeSpace / 1GB, 2)

        Write-Host "Disk $DiskNumber total size: $([math]::Round($diskSize / 1GB, 2)) GB" -ForegroundColor Green
        Write-Host "Disk $DiskNumber allocated space: $([math]::Round($allocatedSize / 1GB, 2)) GB" -ForegroundColor Green
        Write-Host "Disk $DiskNumber free space: $freeSpaceGB GB" -ForegroundColor Green

        # Check if requested size is available
        $requestedSizeBytes = [math]::Round($SizeGB * 1GB, 2)
        if ($freeSpace -lt $requestedSizeBytes) {
            throw "Insufficient free space on disk $DiskNumber. Requested: $SizeGB GB, Available: $freeSpaceGB GB"
        }

        Write-Host "Creating Dev Drive with $SizeGB GB from free space on disk $DiskNumber" -ForegroundColor Green

        # Create Dev Drive
        Write-Host "Creating a new partition with $SizeGB GB on disk $DiskNumber" -ForegroundColor Green
        $newPart = New-Partition -DiskNumber $DiskNumber -Size $requestedSizeBytes -AssignDriveLetter -ErrorAction Stop
    } elseif ($mode -eq "ShrinkDrive") {
        # Use stored partition information to avoid redundant API calls
        if ($partitionInfo) {
            # We already have the partition info from the shrinkable size check
            $diskNum = $partitionInfo.DiskNumber
            $maxSize = $supportedSizes.SizeMax
            Write-Host "Using previously retrieved partition information for drive $DriveLetter" -ForegroundColor Green
        } else {
            # Fallback: get partition info if we couldn't get it earlier
            Write-Host "Getting partition details for drive $DriveLetter. This may take a minute." -ForegroundColor Green
            $partitionInfo = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
            $diskNum = $partitionInfo.DiskNumber
            $supportedSizes = $partitionInfo | Get-PartitionSupportedSize -ErrorAction Stop
            $maxSize = $supportedSizes.SizeMax
        }

        Write-Host "Maximum size for $DriveLetter`: $([math]::Round($maxSize / 1GB, 2)) GB" -ForegroundColor Green
        $targetSize = $maxSize - [math]::Round($ShrinkGB * 1GB, 2)
        Write-Host "Target size after shrinking: $([math]::Round($targetSize / 1GB, 2)) GB" -ForegroundColor Green
        if ($targetSize -lt 0) {
            throw "Cannot shrink drive $DriveLetter by $ShrinkGB GB; insufficient space."
        }

        Write-Host "Resizing Partition $($partitionInfo.PartitionNumber) of disk $diskNum to $([math]::Round($targetSize / 1GB, 2)) GB ..." -ForegroundColor Green
        Resize-Partition -DiskNumber $diskNum -PartitionNumber $partitionInfo.PartitionNumber -Size $targetSize -ErrorAction Stop
        Write-Host "Shrunk drive $DriveLetter by $ShrinkGB GB" -ForegroundColor Green

        # Create Dev Drive from the freed space
        Write-Host "Creating a new partition from the freed space on disk $diskNum" -ForegroundColor Green
        $newPart = New-Partition -DiskNumber $diskNum -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
    } else { # Vhdx
        Write-Host "Creating a $SizeGB GB $VhdxDiskType virtual hard disk at $VhdxPath" -ForegroundColor Green
        if ($VhdxDiskType -eq 'Fixed') {
            Write-Host "Allocating the whole file up front. This may take several minutes and cannot be interrupted." -ForegroundColor Yellow
        }
        New-VirtualDiskFile -Path $VhdxPath -SizeBytes ([uint64][math]::Round($SizeGB * 1GB)) -DiskType $VhdxDiskType

        Write-Host "Attaching $VhdxPath" -ForegroundColor Green
        $VhdxAtBootGranted = Add-VirtualDiskAttachment -Path $VhdxPath -AtBoot:$VhdxAutoAttach

        $vhdxImage = Get-DiskImage -ImagePath $VhdxPath -ErrorAction SilentlyContinue
        if (-not $vhdxImage -or -not $vhdxImage.Attached -or $null -eq $vhdxImage.Number) {
            throw "$VhdxPath was created but did not come up as a disk."
        }

        $vhdxDiskNumber = $vhdxImage.Number
        Write-Host "Attached $VhdxPath as disk $vhdxDiskNumber" -ForegroundColor Green
        if ($VhdxAutoAttach -and -not $VhdxAtBootGranted) {
            Write-Host "Automatic mounting was NOT enabled. After each restart, mount it with:" -ForegroundColor Yellow
            Write-Host "  Mount-DiskImage -ImagePath '$VhdxPath' -StorageType VHDX -Access ReadWrite" -ForegroundColor Yellow
        } elseif ($VhdxAtBootGranted) {
            Write-Host "Windows will mount it automatically on every startup." -ForegroundColor Green
        }

        Write-Host "Initializing disk $vhdxDiskNumber with a GPT partition table" -ForegroundColor Green
        Initialize-Disk -Number $vhdxDiskNumber -PartitionStyle GPT -ErrorAction Stop | Out-Null

        Write-Host "Creating a partition spanning the whole virtual disk" -ForegroundColor Green
        $newPart = New-Partition -DiskNumber $vhdxDiskNumber -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
    }

    $devLetter = $newPart.DriveLetter
    $devLetterColon = "$devLetter`:"
    Write-Host "Formatting the newly created partition drive $devLetterColon to a Dev Drive" -ForegroundColor Green
    Format-Volume -DriveLetter $devLetter -FileSystem ReFS -DevDrive -NewFileSystemLabel "DevDrive" -Confirm:$false -Force -ErrorAction Stop
    Write-Host "Dev Drive created at $devLetterColon" -ForegroundColor Green

    Write-Host "Marking Dev Drive $devLetterColon as trusted for Defender performance" -ForegroundColor Green
    fsutil devdrv trust "$devLetterColon" | Out-Null
    Write-Host "Dev Drive marked trusted." -ForegroundColor Green


    if ($env:USERNAME -eq "SYSTEM") {
        $user_name = Split-Path $env:USERPROFILE -Leaf
    } else {
        $user_name = $env:USERNAME
    }

    $user_name = $user_name -replace "^hpa\.", ""
    $domain_user = "$($env:USERDOMAIN)\$user_name"

    # BitLocker (conditional)
    if (-not $SkipBitLocker) {
        # Loop for BitLocker password entry and setup
        $bitLockerSuccess = $false
        $retryCount = 0
        $maxRetries = 10

        while (-not $bitLockerSuccess -and $retryCount -lt $maxRetries) {
            try {
                Write-Host "Enter BitLocker password for the new volume. It must be a complex one." -ForegroundColor Yellow
                $SecurePassword = Read-StrongPassword

                Write-Host "Enabling BitLocker for $devLetterColon and recovery key back up to Azure AD." -ForegroundColor Green
                Write-Host "Adding BitLockerKeyProtector PasswordProtector"
                Add-BitLockerKeyProtector -MountPoint $devLetterColon -PasswordProtector -Password $SecurePassword -ErrorAction Stop
                Write-Host "Adding BitLockerKeyProtector RecoveryPasswordProtector"
                Add-BitLockerKeyProtector -MountPoint $devLetterColon -RecoveryPasswordProtector -ErrorAction Stop

                Write-Host "Enabling Bitlocker"
                Enable-BitLocker -MountPoint $devLetterColon -AdAccountOrGroup $domain_user -AdAccountOrGroupProtector -SkipHardwareTest -UsedSpaceOnly -ErrorAction Stop

                # Backup recovery key to Azure AD (works for AAD-joined devices only)
                Write-Host "Getting Bitlocker Volume Data"
                $bitlocker_volume = Get-BitLockerVolume -MountPoint $devLetterColon
                Write-Host "Getting Bitlocker Protector ID"
                $protectorId = $bitlocker_volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" } | Select-Object -ExpandProperty KeyProtectorId
                Write-Host "Backing Up Bitlocker Key Protector to Azure AD"
                BackupToAAD-BitLockerKeyProtector -MountPoint $devLetterColon -KeyProtectorId $protectorId -ErrorAction Stop

                Write-Host "Unlocking Bitlocker Volume"
                Unlock-BitLocker -MountPoint $devLetterColon -Password $SecurePassword -ErrorAction Stop
                Write-Host "Enabling BitLockerAutoUnlock"
                Enable-BitLockerAutoUnlock -MountPoint $devLetterColon -ErrorAction Stop

                Write-Host "BitLocker has been enabled for $devLetterColon and recovery key backed up to Azure AD." -ForegroundColor Green
                $bitLockerSuccess = $true
            }
            catch {
                $errorMessage = $_.Exception.Message
                $retryCount++

                if ($errorMessage -match "password.*complexity|password.*requirements|password.*not.*meet" -or
                    $errorMessage -match "password.*does.*not.*meet|password.*requirements.*not.*met") {
                    Write-Host "BitLocker rejected the password due to complexity requirements." -ForegroundColor Red
                    if ($retryCount -lt $maxRetries) {
                        Write-Host "Please try a different password. Attempt $retryCount of $maxRetries." -ForegroundColor Yellow
                        Write-Host ""
                    } else {
                        Write-Host "Maximum retry attempts reached. BitLocker setup failed." -ForegroundColor Red
                        throw "BitLocker password complexity requirements not met after $maxRetries attempts."
                    }
                } else {
                    # Re-throw non-password related errors
                    throw
                }
            }
        }

        if (-not $bitLockerSuccess) {
            throw "Failed to set up BitLocker encryption after $maxRetries attempts."
        }
    } else {
        Write-Host "Skipping BitLocker encryption as requested." -ForegroundColor Yellow
    }


    # Enable Deduplication + Compression (conditional)
    if (-not $SkipDeduplication) {
        Write-Host "Enabling Deduplication mode $DedupMode for $devLetterColon" -ForegroundColor Green
        Enable-ReFSDedup -Volume "$devLetterColon" -Type $DedupMode -ErrorAction Stop
        Write-Host "Enabled ReFS Dedup mode: $DedupMode" -ForegroundColor Green

        # Define common schedule parameters
        $baseScheduleParams = @{
            Volume            = "$devLetterColon"
            Days              = "Monday,Tuesday,Wednesday,Thursday,Friday"
            Duration          = New-TimeSpan -Hours 2
            CpuPercentage     = 60
        }

        # Add compression parameters only if not Dedup-only mode
        if ($DedupMode -ne 'Dedup') {
            $baseScheduleParams.CompressionFormat = $CompressionFormat
            if ($CompressionFormat -eq 'ZSTD') {
                $baseScheduleParams.CompressionLevel = [uint16]$CompressionLevel
            }
        }

        # Define start times
        $startTimes = @("11:00", "17:00")

        foreach ($time in $startTimes) {
            $scheduleParams = $baseScheduleParams.Clone()
            $scheduleParams.Start = $time

            Write-Host "Scheduling deduplication job at $time (2h)" -ForegroundColor Green
            Set-ReFSDedupSchedule @scheduleParams -ErrorAction Stop
        }

        Write-Host "Scheduled daily dedup jobs" -ForegroundColor Green

        # Configure deduplication tasks to run only on AC power
        Write-Host "Configuring deduplication tasks to run only on AC power..." -ForegroundColor Green
        try {
            # Find all ReFS deduplication tasks
            $dedupTasks = Get-ScheduledTask | Where-Object {$_.TaskPath -Like "\Microsoft\Windows\ReFsDedupSvc\" -And $_.TaskName -ne "Initialization" -And $_.State -ne "Disabled"}

            $configuredTasks = 0
            foreach ($task in $dedupTasks) {
                try {
                    $task.Settings.DisallowStartIfOnBatteries = $true
                    $task.Settings.StopIfGoingOnBatteries = $true
                    $task | Set-ScheduledTask | Out-Null
                    $lec = $LASTEXITCODE
                    # Write-Host "$task.TaskName change result: $lec"
                    if ($lec -eq 0) {
                        $configuredTasks++
                    }
                }
                catch {
                    # Continue with other tasks if one fails
                }
            }

            if ($configuredTasks -gt 0) {
                Write-Host "Successfully configured $configuredTasks deduplication task(s) to run only on AC power" -ForegroundColor Green
            } else {
                Write-Host "No deduplication tasks were found to configure. Tasks will run on any power source." -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "Could not configure AC power condition for deduplication tasks. Tasks will run on any power source." -ForegroundColor Yellow
        }

        Write-Host "Scheduling deduplication scrub jobs" -ForegroundColor Green
        Set-ReFSDedupScrubSchedule -Volume "$devLetterColon" -Days "Monday" -Start "17:30" -WeeksInterval 1 -ErrorAction Stop
        Write-Host "Scheduled weekly scrub job on Monday at 12:00 (4h)" -ForegroundColor Green

        if ($RunInitialJob) {
            $jobParams = @{
                Volume            = "$devLetterColon"
                Duration          = (New-TimeSpan -Hours 5)
                CpuPercentage     = 60
            }

            # Add compression parameters only if not Dedup-only mode
            if ($DedupMode -ne 'Dedup') {
                $jobParams.CompressionFormat = $CompressionFormat
                if ($CompressionFormat -eq 'ZSTD') {
                    $jobParams.CompressionLevel = $CompressionLevel
                }
            }

            Write-Host "Running initial Deduplication Job for $devLetterColon" -ForegroundColor Green

            if ($DedupMode -eq 'Dedup') {
                Start-ReFSDedupJob @jobParams -FullRun -ErrorAction Stop | Out-Null
                Write-Host "Triggered initial dedup job (deduplication only)" -ForegroundColor Green
            } else {
                Start-ReFSDedupJob @jobParams -ErrorAction Stop | Out-Null
                Write-Host "Triggered initial dedup job: Format=$CompressionFormat, Level=$CompressionLevel" -ForegroundColor Green
            }
            Write-Host "You should wait for it to complete for the deduplication to properly work" -ForegroundColor Yellow
        }
    } else {
        Write-Host "Skipping deduplication as requested." -ForegroundColor Yellow
    }

    Write-Host "All done. Dev Drive $devLetterColon ready." -ForegroundColor Green
}
catch {
    Write-Host "An error occurred during Dev Drive creation:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow

    # A .vhdx that was created before the failure stays attached, and may already be registered
    # to attach on every startup, so say what is there and how to undo it.
    if ($mode -eq "Vhdx" -and $VhdxPath -and (Test-Path -LiteralPath $VhdxPath)) {
        Write-Host "Left behind: $VhdxPath" -ForegroundColor Yellow
        Write-Host "To remove it: Dismount-DiskImage -ImagePath '$VhdxPath'; Remove-Item -LiteralPath '$VhdxPath'" -ForegroundColor Yellow
    }

    Write-Host "Please check the error message and try again." -ForegroundColor Yellow
    exit 1
}
