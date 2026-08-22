# -*- coding: utf-8 -*-
#Requires -RunAsAdministrator

<#
.SYNOPSIS
 Dev Drive creation script that guides users through creating a Dev Drive with BitLocker encryption and ReFS deduplication.
#>
param()

# Strict mode: a script that repartitions disks must stop on a typo, not act on an empty value.
Set-StrictMode -Version Latest

function Initialize-VirtDiskInterop {
    <#
        virtdisk.dll declarations for creating and attaching a .vhdx; only these can request
        ATTACH_VIRTUAL_DISK_FLAG_AT_BOOT. Layouts and constants come from virtdisk.h.
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

    // Both structs below carry every union arm the header declares, not just the one this script
    // asks for, so the buffer handed to virtdisk is never shorter than the struct it expects.
    [StructLayout(LayoutKind.Sequential)]
    public struct OPEN_VIRTUAL_DISK_PARAMETERS
    {
        public UInt32 Version;
        public UInt32 RWDepth;          // Version1 arm
        public Int32 ReadOnly;          // Version2 and Version3 arms from here on
        public Guid ResiliencyGuid;
        public Guid SnapshotId;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ATTACH_VIRTUAL_DISK_PARAMETERS
    {
        public UInt32 Version;
        // The union is 8-byte aligned because its Version2 arm holds ULONGLONGs.
        public UInt32 UnionAlignmentPadding;
        public UInt32 Reserved;         // Version1 arm
        public UInt32 ReservedTail;
        public UInt64 RestrictedLength; // Version2 arm reaches this far
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

function ConvertTo-FlooredGB {
    # Floor, never round: a displayed maximum must never exceed the real one.
    # A volume with nothing to give reads as 0, not as a negative.
    param([Parameter(Mandatory)][double]$Bytes)
    if ($Bytes -le 0) { return 0 }
    return [math]::Floor($Bytes / 1GB * 100) / 100
}

function ConvertTo-CeilingedGB {
    # Ceiling, never round: a displayed minimum must never read below the real one.
    param([Parameter(Mandatory)][double]$Bytes)
    if ($Bytes -le 0) { return 0 }
    return [math]::Ceiling($Bytes / 1GB * 100) / 100
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
    $pathExisted = Test-Path -LiteralPath $Path

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
        # Clean up a partial file so it does not block the next run, but never delete a file that
        # appeared between the path question and now.
        if (-not $pathExisted) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        }
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
        $image = Get-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue
        if ($result -ne 0 -and -not ($image -and $image.Attached)) {
            throw "Could not attach $Path`: $(Get-Win32ErrorText -Code $result)"
        }
    }
    finally {
        if ($handle -and -not $handle.IsInvalid) { $handle.Close() }
    }

    return $false
}

function Request-BitLockerChoice {
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

function Resolve-EntraJoinState {
    <# Reads AzureAdJoined out of dsregcmd output; anything else, including no output, means no. #>
    param([AllowNull()][AllowEmptyCollection()][string[]]$StatusLines)

    $joined = @($StatusLines | Where-Object { $_ -match '^\s*AzureAdJoined\s*:\s*YES\s*$' })
    return $joined.Count -gt 0
}

function Resolve-BitLockerVolumeState {
    <#
        Any status but a fully decrypted one leaves ciphertext on the volume, so encryption that is
        still running, suspended or being undone counts as covered. Unknown is its own answer.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$ProtectionStatus,
        [AllowNull()][AllowEmptyString()][string]$VolumeStatus,
        [switch]$Unknown
    )

    if ($Unknown) {
        return [PSCustomObject]@{ Known = $false; Protected = $false; HasCiphertext = $false; Covered = $false; Label = 'Unknown' }
    }

    $protected = $ProtectionStatus -eq 'On'
    $hasCiphertext = -not [string]::IsNullOrWhiteSpace($VolumeStatus) -and $VolumeStatus -ne 'FullyDecrypted'
    $covered = $protected -or $hasCiphertext
    $label = 'Clear'
    if ($covered) {
        $label = 'Encrypted'
    }

    return [PSCustomObject]@{
        Known         = $true
        Protected     = $protected
        HasCiphertext = $hasCiphertext
        Covered       = $covered
        Label         = $label
    }
}

function Get-BitLockerProtectionState {
    <# Asks one volume how it is protected; a volume that cannot answer says so, rather than "no". #>
    param([Parameter(Mandatory)][string]$MountPoint)

    try {
        $volume = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
        return Resolve-BitLockerVolumeState -ProtectionStatus ([string]$volume.ProtectionStatus) `
            -VolumeStatus ([string]$volume.VolumeStatus)
    }
    catch {
        return Resolve-BitLockerVolumeState -Unknown
    }
}

function Resolve-BitLockerSetupPlan {
    <# Decides which protectors this machine can carry, and the lines explaining why. #>
    param(
        [switch]$DomainJoined,
        [switch]$EntraJoined,
        [switch]$VhdxMode,
        [switch]$OsDriveProtected
    )

    $notes = @()

    if ($VhdxMode) {
        $notes += "The Dev Drive lives in a virtual hard disk, so a BitLocker password will be asked for: it unlocks the volume after the file is mounted."
    } else {
        $notes += "No BitLocker password will be asked for. The recovery key stays the way to unlock this partition by hand."
    }

    if ($DomainJoined) {
        $notes += "This machine is joined to an Active Directory domain, so a domain account protector will be added."
    } else {
        $notes += "This machine is not joined to an Active Directory domain, so a domain account protector cannot be created for it."
        $notes += "The drive is still encrypted and still protected by its recovery key."
    }

    # Kept as their own list so the run can repeat exactly these lines where the backup is skipped.
    $aadNotes = @()
    if ($EntraJoined) {
        $aadNotes += "This device is joined to Entra ID, so the recovery key will be backed up to Azure AD."
    } else {
        $aadNotes += "This device is not joined to Entra ID, so the recovery key cannot be backed up to Azure AD."
        $aadNotes += "It will be stored nowhere but on the volume itself and on the paper you write it on, so keep it."
    }
    $notes += $aadNotes

    if ($OsDriveProtected) {
        $notes += "The operating system drive is protected by BitLocker, so this drive can be set to unlock automatically."
    } else {
        $notes += "Windows requires the operating system drive to be protected by BitLocker before a fixed data drive can unlock automatically."
        $notes += "Automatic unlocking will be skipped, so the drive will have to be unlocked by hand after every restart."
    }

    return [PSCustomObject]@{
        UsePasswordProtector  = [bool]$VhdxMode
        UseAdAccountProtector = [bool]$DomainJoined
        UseAadBackup          = [bool]$EntraJoined
        UseAutoUnlock         = [bool]$OsDriveProtected
        AadNotes              = $aadNotes
        Notes                 = $notes
    }
}

function Resolve-BitLockerRecoveryProtector {
    <#
        Picks the one recovery protector to back up. Two are a refusal, never a guess: the older key
        still unlocks the volume, and an array of ids breaks BackupToAAD-BitLockerKeyProtector.
    #>
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$KeyProtector,
        [Parameter(Mandatory)][string]$MountPoint
    )

    $recovery = @($KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })
    $ids = @($recovery | ForEach-Object { $_.KeyProtectorId })
    $result = [PSCustomObject]@{ Rejection = $null; ProtectorId = $null; ProtectorIds = $ids; Message = $null }

    if ($ids.Count -eq 0) {
        $result.Rejection = 'None'
        $result.Message = "Drive $MountPoint carries no BitLocker recovery key to back up to Azure AD."
        return $result
    }
    if ($ids.Count -gt 1) {
        $result.Rejection = 'Multiple'
        $result.Message = "Drive $MountPoint carries $($ids.Count) BitLocker recovery keys ($($ids -join ', ')). " +
            "This script will not guess which one to back up to Azure AD. Remove the ones you do not want " +
            "with Remove-BitLockerKeyProtector, or back them up by hand, then run the script again."
        return $result
    }

    $result.ProtectorId = $ids[0]
    return $result
}

function Resolve-BitLockerProtectorPlan {
    <#
        Names the protector types still missing from the volume. Add-BitLockerKeyProtector adds a
        second one rather than refuse, and an existing protector is kept: replacing it would
        invalidate a key that may already be written down or escrowed.
    #>
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$KeyProtector,
        [Parameter(Mandatory)][string]$MountPoint
    )

    $recovery = Resolve-BitLockerRecoveryProtector -KeyProtector $KeyProtector -MountPoint $MountPoint
    $existingTypes = @($KeyProtector | ForEach-Object { $_.KeyProtectorType })

    # Only more than one recovery key stops the run; none at all is the ordinary case on a new volume.
    $rejection = $null
    $message = $null
    if ($recovery.Rejection -eq 'Multiple') {
        $rejection = $recovery.Rejection
        $message = $recovery.Message
    }

    $typesToAdd = @()
    if ($existingTypes -notcontains 'Password') {
        $typesToAdd += 'Password'
    }
    if ($recovery.Rejection -eq 'None') {
        $typesToAdd += 'RecoveryPassword'
    }

    return [PSCustomObject]@{
        Rejection           = $rejection
        Message             = $message
        TypesToAdd          = $typesToAdd
        RecoveryProtectorId = $recovery.ProtectorId
    }
}

function Resolve-BitLockerFailure {
    <#
        Sorts a BitLocker error into the one kind the loop can retry on its own - a password the
        volume refused - and everything else, where the user has to choose what happens next.
        CanRetry is false once the attempts are used up or the error cannot change on a retry.
    #>
    param(
        [AllowEmptyString()][string]$Message,
        [Parameter(Mandatory)][int]$RetryCount,
        [Parameter(Mandatory)][int]$MaxRetries,
        [ValidateSet('Encrypted', 'Clear', 'Unknown')][string]$VolumeState = 'Unknown',
        [switch]$Unretryable,
        [switch]$PasswordAsked
    )

    $exhausted = $RetryCount -ge $MaxRetries
    $canRetry = -not $exhausted -and -not $Unretryable

    # Only a run that asks for a password can be failing on one, whatever the message mentions.
    if ($PasswordAsked -and $Message -match "password.*(complexity|requirements|not.*meet)") {
        $lines = @("BitLocker rejected the password due to complexity requirements.")
        if ($canRetry) {
            $lines += "Please try a different password. Attempt $RetryCount of $MaxRetries."
        } else {
            $lines += "Maximum retry attempts reached. BitLocker setup failed."
        }
        return [PSCustomObject]@{ Kind = 'Password'; Exhausted = $exhausted; CanRetry = $canRetry; Lines = $lines }
    }

    $lines = @("BitLocker setup did not finish. Windows reported: $Message")
    if ($VolumeState -eq 'Encrypted') {
        $lines += "The Dev Drive is created and formatted, and BitLocker has already started encrypting it."
    } elseif ($VolumeState -eq 'Clear') {
        $lines += "The Dev Drive itself is created and formatted, and works without BitLocker."
    } else {
        $lines += "The Dev Drive is created and formatted, but its BitLocker state could not be read. Check it with Get-BitLockerVolume before assuming it is unencrypted."
    }

    return [PSCustomObject]@{ Kind = 'Other'; Exhausted = $exhausted; CanRetry = $canRetry; Lines = $lines }
}

function Resolve-BitLockerAdProtectorNeed {
    <# A domain account protector is added only where the plan allows one and the volume has none. #>
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$ExistingTypes,
        [switch]$Wanted
    )

    return [bool]$Wanted -and (@($ExistingTypes) -notcontains 'AdAccountOrGroup')
}

function Resolve-BitLockerUnlockAction {
    <#
        What to do with the volume before automatic unlocking: unlock it, say why this run cannot,
        or leave it alone. Automatic unlocking is deferred while the volume stays locked.
    #>
    param(
        [Parameter(Mandatory)][string]$MountPoint,
        [AllowNull()][AllowEmptyString()][string]$LockStatus,
        [switch]$HasPassword
    )

    if ($LockStatus -ne 'Locked') {
        return [PSCustomObject]@{ Action = 'None'; DeferAutoUnlock = $false; Lines = @() }
    }

    if ($HasPassword) {
        return [PSCustomObject]@{ Action = 'Unlock'; DeferAutoUnlock = $false; Lines = @() }
    }

    return [PSCustomObject]@{
        Action          = 'Explain'
        DeferAutoUnlock = $true
        Lines           = @(
            "Drive $MountPoint is locked and this run holds no password for it, so it cannot be unlocked here."
            "Unlock it by hand with: manage-bde -unlock $MountPoint -RecoveryPassword <the key above>"
        )
    }
}

function Test-RecoveryKeyAcknowledged {
    <# Only the acknowledgement word, in any case and with spaces trimmed, lets the run go on. #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Answer,
        [Parameter(Mandatory)][string]$Word
    )

    if ([string]::IsNullOrWhiteSpace($Answer)) {
        return $false
    }
    return $Answer.Trim() -eq $Word
}

function Resolve-BitLockerAbandonedAdvice {
    <#
        What is true after the user carries on without finishing BitLocker: encryption that already
        started leaves the recovery key as the only way back into the volume.
    #>
    param(
        [Parameter(Mandatory)][string]$MountPoint,
        [ValidateSet('Encrypted', 'Clear', 'Unknown')][string]$VolumeState = 'Unknown'
    )

    if ($VolumeState -eq 'Encrypted') {
        return @(
            "Carrying on without finishing BitLocker. Drive $MountPoint is already encrypted."
            "Its recovery key is the only way back into it, so keep the key you wrote down. Read it again with: (Get-BitLockerVolume -MountPoint $MountPoint).KeyProtector"
        )
    }

    if ($VolumeState -eq 'Clear') {
        return @("Carrying on without BitLocker. Drive $MountPoint is not encrypted, and is created and usable as it is.")
    }

    return @(
        "Carrying on without finishing BitLocker. The state of drive $MountPoint could not be read, so do not assume it is unencrypted."
        "Check it, and read its recovery key, with: Get-BitLockerVolume -MountPoint $MountPoint"
    )
}

function Request-BitLockerFailureChoice {
    param([switch]$AllowRetry)

    Write-Host "`nWhat do you want to do about BitLocker?" -ForegroundColor Cyan
    if ($AllowRetry) {
        Write-Host "1. Try the BitLocker setup again" -ForegroundColor White
        Write-Host "2. Carry on without BitLocker" -ForegroundColor White
        Write-Host "3. Stop the run" -ForegroundColor White
        $prompt = "Enter your choice (1, 2 or 3)"
        $answers = @{ "1" = "Retry"; "2" = "Continue"; "3" = "Stop" }
        $complaint = "Invalid choice. Please enter 1, 2 or 3."
    } else {
        Write-Host "1. Carry on without BitLocker" -ForegroundColor White
        Write-Host "2. Stop the run" -ForegroundColor White
        $prompt = "Enter your choice (1 or 2)"
        $answers = @{ "1" = "Continue"; "2" = "Stop" }
        $complaint = "Invalid choice. Please enter 1 or 2."
    }
    Write-Host ""

    while ($true) {
        $choice = Read-Host $prompt
        if ($answers.ContainsKey([string]$choice)) {
            return $answers[[string]$choice]
        }
        Write-Host $complaint -ForegroundColor Red
    }
}

function Request-DeduplicationChoice {
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

function Request-CompressionFormat {
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

function Request-CompressionLevel {
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

function Resolve-DedupTimeInput {
    <#
        Decides what one typed start time means. Takes HH:MM or H:MM on a 24-hour clock and
        normalises it to HH:MM. Rejection is $null when the answer is good.
    #>
    param(
        [AllowEmptyString()][string]$Answer,
        [string]$CurrentTime,
        [switch]$AllowEmpty
    )

    $result = [PSCustomObject]@{ Rejection = $null; Time = $null }

    if ([string]::IsNullOrWhiteSpace($Answer)) {
        if ($AllowEmpty -and -not [string]::IsNullOrWhiteSpace($CurrentTime)) {
            $result.Time = $CurrentTime
            return $result
        }
        $result.Rejection = 'Empty'
        return $result
    }

    $match = [regex]::Match($Answer.Trim(), '^([01]?[0-9]|2[0-3]):([0-5][0-9])$')
    if (-not $match.Success) {
        $result.Rejection = 'InvalidTime'
        return $result
    }

    $result.Time = '{0:00}:{1}' -f [int]$match.Groups[1].Value, $match.Groups[2].Value
    return $result
}

function Resolve-DedupTimeListInput {
    <#
        Decides what a typed comma separated list of start times means. Trims each entry, turns away
        a repeated time, and returns the times in ascending order.
    #>
    param(
        [AllowEmptyString()][string]$Answer,
        [string[]]$CurrentTimes,
        [switch]$AllowEmpty,
        [int]$MaxTimes = 4
    )

    $result = [PSCustomObject]@{ Rejection = $null; Times = $null }

    if ([string]::IsNullOrWhiteSpace($Answer)) {
        if ($AllowEmpty) {
            $result.Times = $CurrentTimes
            return $result
        }
        $result.Rejection = 'Empty'
        return $result
    }

    $entries = @($Answer -split ',')
    if (@($entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) {
        $result.Rejection = 'Empty'
        return $result
    }
    if ($entries.Count -gt $MaxTimes) {
        # More entries than this create overlapping jobs rather than a useful schedule.
        $result.Rejection = 'TooMany'
        return $result
    }

    $times = @()
    foreach ($entry in $entries) {
        # A blank entry between two commas is a typo, not a request to keep anything.
        $verdict = Resolve-DedupTimeInput -Answer $entry
        if ($verdict.Rejection) {
            $result.Rejection = 'InvalidTime'
            return $result
        }
        if ($times -contains $verdict.Time) {
            $result.Rejection = 'DuplicateTime'
            return $result
        }
        $times += $verdict.Time
    }

    $result.Times = @($times | Sort-Object)
    return $result
}

function Resolve-DedupDayInput {
    <#
        Decides what a typed weekday means. Takes a full day name or its three-letter form in any
        case, and returns the spelling the scheduler cmdlet expects.
    #>
    param(
        [AllowEmptyString()][string]$Answer,
        [string]$CurrentDay,
        [switch]$AllowEmpty
    )

    $result = [PSCustomObject]@{ Rejection = $null; Day = $null }

    if ([string]::IsNullOrWhiteSpace($Answer)) {
        if ($AllowEmpty) {
            $result.Day = $CurrentDay
            return $result
        }
        $result.Rejection = 'Empty'
        return $result
    }

    $wanted = $Answer.Trim()
    foreach ($day in [System.Enum]::GetNames([System.DayOfWeek])) {
        if ($wanted -eq $day -or $wanted -eq $day.Substring(0, 3)) {
            $result.Day = $day
            return $result
        }
    }

    $result.Rejection = 'InvalidDay'
    return $result
}

function Format-DedupTimeList {
    <# Joins start times the way a sentence reads them: "11:00 and 17:00". #>
    param([Parameter(Mandatory)][string[]]$Times)

    if ($Times.Count -eq 1) {
        return $Times[0]
    }
    return (($Times[0..($Times.Count - 2)] -join ', ') + ' and ' + $Times[-1])
}

function Format-DedupScheduleSummary {
    <# The two lines saying when the deduplication jobs run, shown while choosing and in the plan. #>
    param(
        [Parameter(Mandatory)][string[]]$DailyTimes,
        [Parameter(Mandatory)][string]$DailyDaysLabel,
        [Parameter(Mandatory)][string]$WeeklyDay,
        [Parameter(Mandatory)][string]$WeeklyStart,
        [Parameter(Mandatory)][int]$WeeksInterval
    )

    $weeks = if ($WeeksInterval -eq 1) { "every 1 week" } else { "every $WeeksInterval weeks" }

    return @(
        "  Daily optimization : $DailyDaysLabel at $(Format-DedupTimeList -Times $DailyTimes)"
        "  Weekly maintenance : $WeeklyDay at $WeeklyStart, $weeks"
    )
}

function Resolve-DedupScheduleReminder {
    <#
        The fixed lines telling the user where these schedule times live and how to change them
        later. Points at the times just chosen instead of trying to tell which task is which.
    #>
    param(
        [Parameter(Mandatory)][string[]]$DailyTimes,
        [Parameter(Mandatory)][string]$WeeklyDay,
        [Parameter(Mandatory)][string]$WeeklyStart,
        [Parameter(Mandatory)][string]$TaskTreePath
    )

    return @(
        "Deduplication runs on a schedule kept in Task Scheduler, under:"
        "  $TaskTreePath"
        ""
        "Times just chosen: $(Format-DedupTimeList -Times $DailyTimes) daily, $WeeklyDay at $WeeklyStart weekly."
        ""
        "To change the times later, press Win+R, type taskschd.msc and press Ctrl+Shift+Enter to open"
        "it as administrator, then open that folder and find the tasks whose Triggers column matches"
        "the times above. Edit them on the Triggers tab. Leave the Actions tab alone - that is what"
        "actually runs the deduplication."
        ""
        "Other tasks in that folder may belong to Windows or to earlier runs."
    )
}

function Request-DedupSchedule {
    <#
        The one question about when the deduplication jobs run, with three follow-ups for a user who
        wants to pick the times. Returns the daily start times, the weekly day and its start time.
    #>
    param(
        [Parameter(Mandatory)][string[]]$DailyTimes,
        [Parameter(Mandatory)][string]$DailyDaysLabel,
        [Parameter(Mandatory)][string]$WeeklyDay,
        [Parameter(Mandatory)][string]$WeeklyStart,
        [Parameter(Mandatory)][int]$WeeksInterval,
        [Parameter(Mandatory)][int]$DailyDurationHours,
        [Parameter(Mandatory)][int]$DailyCpuPercent
    )

    $chosenTimes = $DailyTimes
    $chosenDay = $WeeklyDay
    $chosenStart = $WeeklyStart

    Write-Host "`n=== DEDUPLICATION SCHEDULE ===" -ForegroundColor Cyan
    Write-Host ""
    foreach ($line in (Format-DedupScheduleSummary -DailyTimes $chosenTimes -DailyDaysLabel $DailyDaysLabel `
                -WeeklyDay $chosenDay -WeeklyStart $chosenStart -WeeksInterval $WeeksInterval)) {
        Write-Host $line -ForegroundColor White
    }
    Write-Host ""
    Write-Host "The daily job runs on mains power only, for up to $DailyDurationHours hours, using at most $DailyCpuPercent% of the CPU." -ForegroundColor White
    Write-Host "1. Use these times (recommended)" -ForegroundColor White
    Write-Host "2. Choose the times myself" -ForegroundColor White
    Write-Host ""

    while ($true) {
        $choice = Read-Host "Enter your choice (1 or 2)"
        if ($choice -eq "1" -or $choice -eq "2") {
            break
        }
        Write-Host "Invalid choice. Please enter 1 or 2." -ForegroundColor Red
    }

    if ($choice -eq "2") {
        $maxDailyTimes = 4
        while ($true) {
            Write-Host "`nStart times for the daily optimization, comma separated, 24-hour HH:MM (for example 08:15,13:00)." -ForegroundColor Cyan
            $answer = Read-Host "Press Enter to keep $($chosenTimes -join ',')"
            $verdict = Resolve-DedupTimeListInput -Answer $answer -CurrentTimes $chosenTimes -AllowEmpty -MaxTimes $maxDailyTimes

            if ($verdict.Rejection -eq 'Empty') {
                Write-Host "No time given. Enter at least one time as HH:MM, for example 08:15,13:00." -ForegroundColor Red
                continue
            }
            if ($verdict.Rejection -eq 'InvalidTime') {
                Write-Host "Invalid time. Enter it as HH:MM on a 24-hour clock, for example 08:15." -ForegroundColor Red
                continue
            }
            if ($verdict.Rejection -eq 'DuplicateTime') {
                Write-Host "Repeated time. Enter each start time only once." -ForegroundColor Red
                continue
            }
            if ($verdict.Rejection -eq 'TooMany') {
                Write-Host "Too many times. Overlapping jobs waste effort; enter at most $maxDailyTimes." -ForegroundColor Red
                continue
            }

            $chosenTimes = $verdict.Times
            break
        }

        while ($true) {
            Write-Host "`nDay for the weekly maintenance." -ForegroundColor Cyan
            $answer = Read-Host "Press Enter to keep $chosenDay"
            $verdict = Resolve-DedupDayInput -Answer $answer -CurrentDay $chosenDay -AllowEmpty

            if ($verdict.Rejection) {
                Write-Host "Invalid day. Enter one day name, for example Monday." -ForegroundColor Red
                continue
            }

            $chosenDay = $verdict.Day
            break
        }

        while ($true) {
            Write-Host "`nStart time for the weekly maintenance, 24-hour HH:MM." -ForegroundColor Cyan
            $answer = Read-Host "Press Enter to keep $chosenStart"
            $verdict = Resolve-DedupTimeInput -Answer $answer -CurrentTime $chosenStart -AllowEmpty

            if ($verdict.Rejection) {
                Write-Host "Invalid time. Enter it as HH:MM on a 24-hour clock, for example 08:15." -ForegroundColor Red
                continue
            }

            $chosenStart = $verdict.Time
            break
        }

        Write-Host ""
        foreach ($line in (Format-DedupScheduleSummary -DailyTimes $chosenTimes -DailyDaysLabel $DailyDaysLabel `
                    -WeeklyDay $chosenDay -WeeklyStart $chosenStart -WeeksInterval $WeeksInterval)) {
            Write-Host $line -ForegroundColor Green
        }
    }

    return [PSCustomObject]@{ DailyTimes = $chosenTimes; WeeklyDay = $chosenDay; WeeklyStart = $chosenStart }
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

    # The length cap keeps a very long run of digits from overflowing the cast below.
    if ($Answer -notmatch '^\d+\.?\d*$' -or $Answer.Length -gt 20) {
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

function Request-DevDriveSizeGB {
    <#
        The one size question for all three creation modes. -MaxIsAdvisory warns instead of
        rejecting, for a dynamically expanding disk that is allowed to outgrow its host volume.
    #>
    param(
        [Parameter(Mandatory)][decimal]$MaxGB,
        [Parameter(Mandatory)][string]$Subject,
        [decimal]$MinGB = $script:DevDriveMinSizeGB,
        [switch]$AllowMaxOnEmpty,
        [switch]$MaxIsAdvisory
    )

    $maxHint = if ($AllowMaxOnEmpty) { "max: $MaxGB, press Enter for max" } else { "max: $MaxGB" }

    while ($true) {
        $answer = Read-Host "Enter $Subject in GB (min: $MinGB, $maxHint)"

        $verdict = Resolve-DevDriveSizeInput -Answer $answer -MinGB $MinGB -MaxGB $MaxGB `
            -AllowEmpty:$AllowMaxOnEmpty -MaxIsAdvisory:$MaxIsAdvisory

        if ($verdict.Rejection -eq 'NotANumber') {
            Write-Host "Invalid $Subject. Please enter a positive decimal number." -ForegroundColor Red
            continue
        }
        if ($verdict.Rejection -eq 'BelowMinimum') {
            Write-Host "$Subject must be at least $MinGB GB. Please enter a larger value." -ForegroundColor Red
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
    if ($Answer -notmatch '^[A-Za-z]:[\\/]') {
        $result.Rejection = 'NotALocalPath'
        return $result
    }

    # Windows PowerShell throws from GetFullPath on characters Windows forbids while PowerShell 7
    # passes them through, so they are rejected here explicitly and the call is guarded as well.
    if ($Answer.Substring(2) -match '[<>":|?*]') {
        $result.Rejection = 'InvalidPath'
        return $result
    }

    try {
        $full = [System.IO.Path]::GetFullPath($Answer)
    }
    catch {
        $result.Rejection = 'InvalidPath'
        return $result
    }

    $full = $full.Substring(0, 1).ToUpper() + $full.Substring(1)

    if ([System.IO.Path]::GetExtension($full) -ne '.vhdx') {
        $result.Rejection = 'WrongExtension'
        return $result
    }

    $result.Path = $full
    return $result
}

function Request-VhdxPath {
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
        if ($verdict.Rejection -eq 'InvalidPath') {
            Write-Host "Windows does not accept that path. Check for characters like | < > or a very long name." -ForegroundColor Red
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

function Request-VhdxDiskType {
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

function Request-VhdxSize {
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [Parameter(Mandatory)][ValidateSet('Dynamic', 'Fixed')][string]$DiskType
    )

    $hostLetter = [char]$VhdxPath[0]
    $hostUsableBytes = (Get-Volume -DriveLetter $hostLetter).SizeRemaining - $VhdxHostSpareBytes
    $hostFreeGB = ConvertTo-FlooredGB -Bytes $hostUsableBytes

    if ($DiskType -eq 'Fixed' -and $hostUsableBytes -lt ($DevDriveMinSizeGB * 1GB)) {
        Write-Host "Drive $hostLetter`: has $hostFreeGB GB to spare, below the $DevDriveMinSizeGB GB minimum required for a Dev Drive." -ForegroundColor Red
        Write-Host "Exiting. Choose a dynamically expanding disk or another drive, then run the script again." -ForegroundColor Yellow
        exit 1
    }

    Write-Host "`nDrive $hostLetter`: has $hostFreeGB GB to spare." -ForegroundColor Cyan
    if ($DiskType -eq 'Fixed') {
        Write-Host "A fixed size disk takes all of its space right away, so it cannot exceed that." -ForegroundColor White
    } else {
        Write-Host "A dynamically expanding disk may be larger than the free space, but it will" -ForegroundColor White
        Write-Host "fail once the host drive fills up." -ForegroundColor White
    }
    Write-Host ""

    return Request-DevDriveSizeGB -MaxGB $hostFreeGB -Subject 'Dev Drive size' -MaxIsAdvisory:($DiskType -eq 'Dynamic')
}

function Resolve-VhdxMountAdvice {
    <# Names the mount command whenever Windows will not do it, whether the user declined it or Windows refused. #>
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [switch]$AutoAttachRequested,
        [switch]$AutoAttachGranted
    )

    if ($AutoAttachGranted) {
        return @("Windows will mount $VhdxPath automatically on every startup.")
    }

    $opening = if ($AutoAttachRequested) {
        "Automatic mounting was NOT enabled, so this Dev Drive's mount point is gone after every restart."
    } else {
        "You chose to mount this Dev Drive yourself, so its mount point is gone after every restart."
    }

    return @(
        $opening
        "Mount it again with:"
        "  Mount-DiskImage -ImagePath '$VhdxPath' -StorageType VHDX -Access ReadWrite"
        "Run that from a PowerShell started as administrator: mounting a virtual hard disk needs"
        "administrator rights, unlike mounting a .iso file."
    )
}

function Request-AutoAttachChoice {
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

function Resolve-RerunAdvice {
    <#
        What the closing failure message says about running again. A run never resumes - it always
        starts from the beginning - so shrink mode has to warn when a resize already happened.
    #>
    param([AllowNull()][AllowEmptyString()][string]$ShrunkDriveLetter)

    $lines = @(
        "Check the error above, undo whatever this run already changed, and only then run it again."
        "This script does not resume: every run starts from the beginning."
    )

    if (-not [string]::IsNullOrWhiteSpace($ShrunkDriveLetter)) {
        $lines += "Drive ${ShrunkDriveLetter}: has already been shrunk."
        $lines += "Running again with the same answer takes that much off it a second time."
    }

    return $lines
}

Write-Host "Dev Drive creation script with BitLocker encryption and ReFS deduplication." -ForegroundColor Green

# Check Windows version. Read in two steps: a missing value leaves nothing to take CurrentBuild off.
$buildKey = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuild -ErrorAction SilentlyContinue
$windows_build = if ($buildKey) { $buildKey.CurrentBuild -as [int] } else { $null }
$windows_build_min = 26100

if ($windows_build -ge $windows_build_min) {
    Write-Host "Windows Build $windows_build is OK" -ForegroundColor Gray
} else {
    Write-Error "Your Windows build $windows_build is lower than $windows_build_min. Please update before using the script."
    exit 1
}

# Microsoft's documented minimum size for a Dev Drive volume (https://learn.microsoft.com/en-us/windows/dev-drive/)
$DevDriveMinSizeGB = 50

# Head-room kept on the volume hosting a fixed size .vhdx, so it is never filled to the last byte.
$VhdxHostSpareBytes = 1GB

# Head-room left on a shrunk volume, so an estimate never offers to take its last free byte.
$ShrinkSpareBytes = 5GB

# Set default values for deduplication and compression settings
$DedupMode = 'Dedup'
$CompressionFormat = 'LZ4'
$CompressionLevel = 5
$RunInitialJob = $true
$SkipBitLocker = $false
$SkipDeduplication = $false

# ReFS dedup schedule defaults, changeable by the user below. Read by both the plan summary and the
# actual calls, so the two cannot say different things about when the jobs run.
$DedupStartTimes = @("11:00", "17:00")
$ScrubDays = "Monday"
$ScrubStart = "17:30"
$ScrubWeeksInterval = 1

# Load tuning that stays fixed: the daily job's days, duration and CPU cap, and where its tasks live.
$DedupDailyDays = "Monday,Tuesday,Wednesday,Thursday,Friday"
$DedupDailyDaysLabel = "Monday-Friday" # kept beside $DedupDailyDays by hand, not derived from it
$DedupDailyDurationHours = 2
$DedupDailyCpuPercent = 60
$DedupTaskPath = "\Microsoft\Windows\ReFsDedupSvc\"
$DedupTaskTreePath = "Task Scheduler Library > " + (($DedupTaskPath.Trim('\') -split '\\') -join ' > ')

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
    $freeSpaceGB = ConvertTo-FlooredGB -Bytes $freeSpace

    Write-Host "`nDisk $DiskNumber has $freeSpaceGB GB of free space available." -ForegroundColor Cyan

    if ($freeSpace -lt ($DevDriveMinSizeGB * 1GB)) {
        Write-Host "Disk $DiskNumber only has $freeSpaceGB GB of free space, which is below the $DevDriveMinSizeGB GB minimum required for a Dev Drive." -ForegroundColor Red
        Write-Host "Exiting. Please choose a different disk or free up more space, then run the script again." -ForegroundColor Yellow
        exit 1
    }

    $SizeGB = Request-DevDriveSizeGB -MaxGB $freeSpaceGB -Subject 'Dev Drive size' -AllowMaxOnEmpty
} elseif ($mode -eq "ShrinkDrive") {
    Write-Host "`n=== SELECT DRIVE TO SHRINK ===" -ForegroundColor Cyan
    Write-Host "Available drives on Disk $DiskNumber for shrinking:" -ForegroundColor White

    # Drives on the selected disk only. @() so one match still answers .Count; an unmappable volume drops out.
    $volumesOnDisk = @(Get-Volume | Where-Object {
        if (-not ($_.DriveLetter -and $_.DriveType -eq 'Fixed')) { return $false }
        $volumePartition = Get-Partition -DriveLetter $_.DriveLetter -ErrorAction SilentlyContinue
        $volumePartition -and $volumePartition.DiskNumber -eq $DiskNumber
    } | Sort-Object DriveLetter)

    if ($volumesOnDisk.Count -eq 0) {
        Write-Host "No shrinkable drives found on Disk $DiskNumber." -ForegroundColor Red
        Write-Host "Please select a different disk or use free space mode." -ForegroundColor Yellow
        exit 1
    }

    foreach ($vol in $volumesOnDisk) {
        $letter = $vol.DriveLetter
        # Not $sizeGB: names are case-insensitive here, and $SizeGB is the Dev Drive size.
        $volSizeGB = [math]::Round($vol.Size / 1GB, 2)
        $freeGB = [math]::Round($vol.SizeRemaining / 1GB, 2)
        # From bytes, not from the already-rounded $freeGB, so the listed figure is never above the real one.
        $shrinkableGB = ConvertTo-FlooredGB -Bytes ($vol.SizeRemaining - $ShrinkSpareBytes)

        Write-Host "  Drive $letter`: $($vol.FileSystemLabel)" -ForegroundColor Yellow
        Write-Host "    Total: $volSizeGB GB | Free: $freeGB GB | Shrinkable: ~$shrinkableGB GB" -ForegroundColor White
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
                    $realMaxShrinkableGB = ConvertTo-FlooredGB -Bytes $realMaxShrinkableBytes

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
                    # Left free to go negative: the Dev Drive minimum check below then refuses the volume.
                    $realMaxShrinkableBytes = $driveOnDisk.SizeRemaining - $ShrinkSpareBytes
                    $realMaxShrinkableGB = ConvertTo-FlooredGB -Bytes $realMaxShrinkableBytes
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

    $ShrinkGB = Request-DevDriveSizeGB -MaxGB $realMaxShrinkableGB -Subject 'Shrink amount'
    $SizeGB = $ShrinkGB  # The Dev Drive fills exactly the space that was freed
} else { # Vhdx
    # Compile the interop now rather than after every question, so a machine that forbids Add-Type
    # fails before the user has answered anything.
    Initialize-VirtDiskInterop

    $VhdxPath = Request-VhdxPath
    $VhdxDiskType = Request-VhdxDiskType
    $SizeGB = Request-VhdxSize -VhdxPath $VhdxPath -DiskType $VhdxDiskType
    $VhdxAutoAttach = Request-AutoAttachChoice
}

# Ask about BitLocker encryption
$enableBitLocker = Request-BitLockerChoice -VhdxMode:($mode -eq "Vhdx")
$SkipBitLocker = -not $enableBitLocker

# Settled before the plan is shown; a fact that cannot be read counts as the safe answer.
$bitLockerPlan = $null
if ($enableBitLocker) {
    # Both queries below can take a while on a machine that cannot reach its domain controller.
    Write-Host "Checking what this machine can do with BitLocker (domain, Entra ID, system drive)..." -ForegroundColor Gray

    $isDomainJoined = $false
    try {
        $isDomainJoined = [bool](Get-CimInstance -ClassName Win32_ComputerSystem -OperationTimeoutSec 15 -ErrorAction Stop).PartOfDomain
    }
    catch {
        $isDomainJoined = $false
    }

    $isEntraJoined = $false
    try {
        $isEntraJoined = Resolve-EntraJoinState -StatusLines (& dsregcmd.exe /status 2>$null)
    }
    catch {
        $isEntraJoined = $false
    }

    $osDriveProtected = $false
    try {
        $osDriveProtected = (Get-BitLockerProtectionState -MountPoint $env:SystemDrive).Protected
    }
    catch {
        $osDriveProtected = $false
    }

    $bitLockerPlan = Resolve-BitLockerSetupPlan -DomainJoined:$isDomainJoined -EntraJoined:$isEntraJoined `
        -VhdxMode:($mode -eq "Vhdx") -OsDriveProtected:$osDriveProtected
}

# Ask about deduplication
$dedupChoice = Request-DeduplicationChoice
if ($dedupChoice -eq "None") {
    $SkipDeduplication = $true
} elseif ($dedupChoice -eq "DedupAndCompress") {
    $DedupMode = $dedupChoice

    # Ask for compression format
    $CompressionFormat = Request-CompressionFormat

    # Ask for compression level if ZSTD is selected
    if ($CompressionFormat -eq "ZSTD") {
        $CompressionLevel = Request-CompressionLevel
        Write-Host "Selected ZSTD compression with level $CompressionLevel" -ForegroundColor Green
    } else {
        Write-Host "Selected LZ4 compression" -ForegroundColor Green
    }
} else {
    $DedupMode = $dedupChoice
    Write-Host "Selected deduplication only (no compression)" -ForegroundColor Green
}

# Ask when the deduplication jobs should run
if (-not $SkipDeduplication) {
    $dedupSchedule = Request-DedupSchedule -DailyTimes $DedupStartTimes -DailyDaysLabel $DedupDailyDaysLabel `
        -WeeklyDay $ScrubDays -WeeklyStart $ScrubStart -WeeksInterval $ScrubWeeksInterval `
        -DailyDurationHours $DedupDailyDurationHours -DailyCpuPercent $DedupDailyCpuPercent
    $DedupStartTimes = $dedupSchedule.DailyTimes
    $ScrubDays = $dedupSchedule.WeeklyDay
    $ScrubStart = $dedupSchedule.WeeklyStart
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
        Write-Host "* Skip automatic mounting; the Dev Drive mount point is gone after every restart until mounted by hand" -ForegroundColor White
    }
} else {
    Write-Host "* Create $SizeGB GB Dev Drive on Disk $DiskNumber ($selectedDiskName) using ReFS" -ForegroundColor White
}

if (-not $SkipBitLocker) {
    Write-Host "* Enable BitLocker encryption for the Dev Drive" -ForegroundColor White
    foreach ($note in $bitLockerPlan.Notes) {
        Write-Host "  - $note" -ForegroundColor Gray
    }
} else {
    Write-Host "* Skip BitLocker encryption" -ForegroundColor White
}

if (-not $SkipDeduplication) {
    if ($DedupMode -eq "DedupAndCompress") {
        Write-Host "* Enable ReFS deduplication with $CompressionFormat compression (level $CompressionLevel)" -ForegroundColor White
    } else {
        Write-Host "* Enable ReFS deduplication only (no compression)" -ForegroundColor White
    }
    foreach ($line in (Format-DedupScheduleSummary -DailyTimes $DedupStartTimes -DailyDaysLabel $DedupDailyDaysLabel `
                -WeeklyDay $ScrubDays -WeeklyStart $ScrubStart -WeeksInterval $ScrubWeeksInterval)) {
        Write-Host "* $($line.Trim())" -ForegroundColor White
    }
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

# The catch below reads this even when the run fails before the attach.
$VhdxAtBootGranted = $false
# Repeated at the end: printed once at attach time, it scrolls away behind formatting and dedup.
$VhdxMountAdvice = @()
# The catch below reads this to know whether a shrink already resized a partition.
$ShrunkDriveLetter = $null

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
            $minSize = $supportedSizes.SizeMin
            Write-Host "Using previously retrieved partition information for drive $DriveLetter" -ForegroundColor Green
        } else {
            # Fallback: get partition info if we couldn't get it earlier
            Write-Host "Getting partition details for drive $DriveLetter. This may take a minute." -ForegroundColor Green
            $partitionInfo = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
            $diskNum = $partitionInfo.DiskNumber
            $supportedSizes = $partitionInfo | Get-PartitionSupportedSize -ErrorAction Stop
            $maxSize = $supportedSizes.SizeMax
            $minSize = $supportedSizes.SizeMin
        }

        Write-Host "Maximum size for $DriveLetter`: $(ConvertTo-FlooredGB -Bytes $maxSize) GB" -ForegroundColor Green
        $targetSize = $maxSize - [math]::Round($ShrinkGB * 1GB, 2)
        Write-Host "Target size after shrinking: $(ConvertTo-FlooredGB -Bytes $targetSize) GB" -ForegroundColor Green
        if ($targetSize -lt $minSize) {
            Write-Host "Cannot shrink drive $DriveLetter to $(ConvertTo-FlooredGB -Bytes $targetSize) GB; Windows will not take it below $(ConvertTo-CeilingedGB -Bytes $minSize) GB." -ForegroundColor Red
            Write-Host "Exiting. Please choose a different drive or use free space mode, then run the script again." -ForegroundColor Yellow
            exit 1
        }

        Write-Host "Resizing Partition $($partitionInfo.PartitionNumber) of disk $diskNum to $(ConvertTo-FlooredGB -Bytes $targetSize) GB ..." -ForegroundColor Green
        Resize-Partition -DiskNumber $diskNum -PartitionNumber $partitionInfo.PartitionNumber -Size $targetSize -ErrorAction Stop
        $ShrunkDriveLetter = $DriveLetter
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
        $VhdxMountAdvice = Resolve-VhdxMountAdvice -VhdxPath $VhdxPath `
            -AutoAttachRequested:$VhdxAutoAttach -AutoAttachGranted:$VhdxAtBootGranted
        $adviceColour = if ($VhdxAtBootGranted) { 'Green' } else { 'Yellow' }
        foreach ($line in $VhdxMountAdvice) {
            Write-Host $line -ForegroundColor $adviceColour
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
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Dev Drive marked trusted." -ForegroundColor Green
    } else {
        # fsutil is a native tool: a failure here does not throw, so it must be read from
        # $LASTEXITCODE instead of the surrounding try/catch. The drive is still a fully
        # working Dev Drive; it only loses the Defender performance mode that trust grants.
        Write-Host "Could not mark $devLetterColon as trusted (fsutil exited with code $LASTEXITCODE)." -ForegroundColor Yellow
        Write-Host "The Dev Drive will still work, but without the Defender performance mode trust enables." -ForegroundColor Yellow
        Write-Host "Check the current state with: fsutil devdrv query $devLetterColon" -ForegroundColor Yellow
        Write-Host "Retry by hand with: fsutil devdrv trust $devLetterColon" -ForegroundColor Yellow
    }


    if ($env:USERNAME -eq "SYSTEM") {
        $user_name = Split-Path $env:USERPROFILE -Leaf
    } else {
        $user_name = $env:USERNAME
    }

    $user_name = $user_name -replace "^hpa\.", ""
    $domain_user = "$($env:USERDOMAIN)\$user_name"

    # BitLocker (conditional)
    if (-not $SkipBitLocker) {
        Write-Host "`nBitLocker setup for $devLetterColon" -ForegroundColor Cyan
        foreach ($note in $bitLockerPlan.Notes) {
            Write-Host $note -ForegroundColor Yellow
        }

        $bitLockerSuccess = $false
        $bitLockerAbandoned = $false
        $SecurePassword = $null
        $retryCount = 0
        $maxRetries = 10
        $keyBannerRule = "=" * 64
        $keyAcknowledgement = "YES"

        while (-not $bitLockerSuccess -and -not $bitLockerAbandoned -and $retryCount -lt $maxRetries) {
            # A rejection that a second read of the same volume would repeat is not worth retrying.
            $unretryable = $false
            try {
                Write-Host "Reading the current BitLocker protectors of $devLetterColon" -ForegroundColor Green
                $bitlocker_volume = Get-BitLockerVolume -MountPoint $devLetterColon -ErrorAction Stop
                $protectorPlan = Resolve-BitLockerProtectorPlan -KeyProtector $bitlocker_volume.KeyProtector -MountPoint $devLetterColon
                if ($protectorPlan.Rejection) {
                    $unretryable = $true
                    throw $protectorPlan.Message
                }

                if ($bitLockerPlan.UsePasswordProtector -and $protectorPlan.TypesToAdd -contains 'Password') {
                    Write-Host "Enter BitLocker password for the new volume. It must be a complex one." -ForegroundColor Yellow
                    $SecurePassword = Read-StrongPassword
                    Write-Host "Adding BitLockerKeyProtector PasswordProtector" -ForegroundColor Green
                    Add-BitLockerKeyProtector -MountPoint $devLetterColon -PasswordProtector -Password $SecurePassword -ErrorAction Stop
                }

                # Gated on the volume's own status: a recovery protector alone does not encrypt it.
                $volumeState = Resolve-BitLockerVolumeState -ProtectionStatus ([string]$bitlocker_volume.ProtectionStatus) `
                    -VolumeStatus ([string]$bitlocker_volume.VolumeStatus)
                if (-not $volumeState.Covered) {
                    # One call turns encryption on and creates the recovery key; adding that protector first made two.
                    Write-Host "Enabling BitLocker on $devLetterColon with a recovery key" -ForegroundColor Green
                    Enable-BitLocker -MountPoint $devLetterColon -RecoveryPasswordProtector -SkipHardwareTest -UsedSpaceOnly -ErrorAction Stop
                }

                # Shown and acknowledged before any further protector work: that work is what fails.
                Write-Host "Reading the recovery key back off $devLetterColon" -ForegroundColor Green
                $bitlocker_volume = Get-BitLockerVolume -MountPoint $devLetterColon -ErrorAction Stop
                $recoveryProtector = Resolve-BitLockerRecoveryProtector -KeyProtector $bitlocker_volume.KeyProtector -MountPoint $devLetterColon
                if ($recoveryProtector.Rejection) {
                    $unretryable = $recoveryProtector.Rejection -eq 'Multiple'
                    throw $recoveryProtector.Message
                }
                $recoveryKey = ($bitlocker_volume.KeyProtector |
                    Where-Object { $_.KeyProtectorId -eq $recoveryProtector.ProtectorId }).RecoveryPassword
                if ([string]::IsNullOrWhiteSpace($recoveryKey)) {
                    throw "Drive $devLetterColon has a recovery protector $($recoveryProtector.ProtectorId) but reports no recovery key text for it. Read it with: (Get-BitLockerVolume -MountPoint $devLetterColon).KeyProtector"
                }

                Write-Host ""
                Write-Host $keyBannerRule -ForegroundColor Cyan
                Write-Host "BITLOCKER RECOVERY KEY FOR $devLetterColon - WRITE IT DOWN NOW" -ForegroundColor Cyan
                Write-Host $recoveryKey -ForegroundColor White
                Write-Host $keyBannerRule -ForegroundColor Cyan
                Write-Host ""
                while (-not (Test-RecoveryKeyAcknowledged -Word $keyAcknowledgement `
                        -Answer (Read-Host "Type $keyAcknowledgement once you have written the recovery key down"))) {
                    Write-Host "The run continues only once the recovery key is written down." -ForegroundColor Yellow
                }

                $existingTypes = @($bitlocker_volume.KeyProtector | ForEach-Object { [string]$_.KeyProtectorType })
                $wantsAdProtector = $bitLockerPlan.UseAdAccountProtector
                if (Resolve-BitLockerAdProtectorNeed -ExistingTypes $existingTypes -Wanted:$wantsAdProtector) {
                    Write-Host "Adding BitLockerKeyProtector AdAccountOrGroupProtector for $domain_user" -ForegroundColor Green
                    Add-BitLockerKeyProtector -MountPoint $devLetterColon -AdAccountOrGroupProtector -AdAccountOrGroup $domain_user -ErrorAction Stop
                }

                if ($bitLockerPlan.UseAadBackup) {
                    Write-Host "Backing up the recovery key to Azure AD" -ForegroundColor Green
                    BackupToAAD-BitLockerKeyProtector -MountPoint $devLetterColon -KeyProtectorId $recoveryProtector.ProtectorId -ErrorAction Stop
                } else {
                    Write-Host "Not backing the recovery key up to Azure AD." -ForegroundColor Yellow
                    foreach ($note in $bitLockerPlan.AadNotes) {
                        Write-Host $note -ForegroundColor Yellow
                    }
                }

                $bitlocker_volume = Get-BitLockerVolume -MountPoint $devLetterColon -ErrorAction Stop
                $unlockPlan = Resolve-BitLockerUnlockAction -MountPoint $devLetterColon `
                    -LockStatus ([string]$bitlocker_volume.LockStatus) -HasPassword:($null -ne $SecurePassword)
                foreach ($line in $unlockPlan.Lines) {
                    Write-Host $line -ForegroundColor Yellow
                }
                if ($unlockPlan.Action -eq 'Unlock') {
                    Write-Host "Unlocking $devLetterColon" -ForegroundColor Green
                    Unlock-BitLocker -MountPoint $devLetterColon -Password $SecurePassword -ErrorAction Stop
                }

                if ($bitLockerPlan.UseAutoUnlock -and -not $unlockPlan.DeferAutoUnlock) {
                    Write-Host "Enabling BitLockerAutoUnlock" -ForegroundColor Green
                    Enable-BitLockerAutoUnlock -MountPoint $devLetterColon -ErrorAction Stop
                } elseif ($bitLockerPlan.UseAutoUnlock) {
                    Write-Host "Automatic unlocking needs the volume unlocked first, so set it up afterwards with: Enable-BitLockerAutoUnlock -MountPoint $devLetterColon" -ForegroundColor Yellow
                }

                $finalState = Get-BitLockerProtectionState -MountPoint $devLetterColon
                if ($finalState.Covered) {
                    Write-Host "BitLocker has been enabled for $devLetterColon and its recovery key is written down." -ForegroundColor Green
                } else {
                    Write-Host "BitLocker setup finished, but $devLetterColon does not report itself as protected or encrypting." -ForegroundColor Yellow
                    Write-Host "Check it with: Get-BitLockerVolume -MountPoint $devLetterColon" -ForegroundColor Yellow
                }
                $bitLockerSuccess = $true
            }
            catch {
                $failure = $_
                $retryCount++
                $failureState = (Get-BitLockerProtectionState -MountPoint $devLetterColon).Label
                $passwordAsked = $bitLockerPlan.UsePasswordProtector
                $verdict = Resolve-BitLockerFailure -Message $failure.Exception.Message -RetryCount $retryCount `
                    -MaxRetries $maxRetries -VolumeState $failureState -Unretryable:$unretryable -PasswordAsked:$passwordAsked
                foreach ($line in $verdict.Lines) {
                    Write-Host $line -ForegroundColor Red
                }

                if ($verdict.Kind -eq 'Password' -and $verdict.CanRetry) {
                    Write-Host ""
                } elseif ($verdict.Kind -eq 'Password' -and -not $verdict.CanRetry) {
                    throw "BitLocker password complexity requirements not met after $retryCount attempts."
                } else {
                    # The drive already exists, so this must not end the run unless the user says so.
                    $canRetry = $verdict.CanRetry
                    $choice = Request-BitLockerFailureChoice -AllowRetry:$canRetry
                    if ($choice -eq "Continue") {
                        $bitLockerAbandoned = $true
                    } elseif ($choice -eq "Stop") {
                        throw $failure
                    }
                }
            }
        }

        # Reached whether the user chose to carry on or the attempts ran out; the drive exists either way.
        if (-not $bitLockerSuccess) {
            $abandonedState = (Get-BitLockerProtectionState -MountPoint $devLetterColon).Label
            foreach ($line in (Resolve-BitLockerAbandonedAdvice -MountPoint $devLetterColon -VolumeState $abandonedState)) {
                Write-Host $line -ForegroundColor Yellow
            }
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
            Days              = $DedupDailyDays
            Duration          = New-TimeSpan -Hours $DedupDailyDurationHours
            CpuPercentage     = $DedupDailyCpuPercent
        }

        # Add compression parameters only if not Dedup-only mode
        if ($DedupMode -ne 'Dedup') {
            $baseScheduleParams.CompressionFormat = $CompressionFormat
            if ($CompressionFormat -eq 'ZSTD') {
                $baseScheduleParams.CompressionLevel = [uint16]$CompressionLevel
            }
        }

        foreach ($time in $DedupStartTimes) {
            $scheduleParams = $baseScheduleParams.Clone()
            $scheduleParams.Start = $time

            Write-Host "Scheduling deduplication job at $time (${DedupDailyDurationHours}h)" -ForegroundColor Green
            Set-ReFSDedupSchedule @scheduleParams -ErrorAction Stop
        }

        Write-Host "Scheduled daily dedup jobs" -ForegroundColor Green

        # Configure deduplication tasks to run only on AC power
        Write-Host "Configuring deduplication tasks to run only on AC power..." -ForegroundColor Green
        try {
            # Find all ReFS deduplication tasks
            $dedupTasks = Get-ScheduledTask | Where-Object {$_.TaskPath -Like $DedupTaskPath -And $_.TaskName -ne "Initialization" -And $_.State -ne "Disabled"}

            $configuredTasks = 0
            $taskFailures = @()
            foreach ($task in $dedupTasks) {
                try {
                    $task.Settings.DisallowStartIfOnBatteries = $true
                    $task.Settings.StopIfGoingOnBatteries = $true
                    $task | Set-ScheduledTask -ErrorAction Stop | Out-Null
                    $configuredTasks++
                }
                catch {
                    # One task's failure must not stop the others, but it must not pass unseen either.
                    $taskFailures += "Could not configure $($task.TaskName) to run only on AC power: $($_.Exception.Message)"
                }
            }

            if ($configuredTasks -gt 0) {
                Write-Host "Successfully configured $configuredTasks deduplication task(s) to run only on AC power" -ForegroundColor Green
            }
            foreach ($failure in $taskFailures) {
                Write-Host $failure -ForegroundColor Yellow
            }
            if (-not $dedupTasks) {
                Write-Host "No deduplication tasks were found to configure. Tasks will run on any power source." -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "Could not configure AC power condition for deduplication tasks: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "Tasks will run on any power source." -ForegroundColor Yellow
        }

        Write-Host "Scheduling deduplication scrub jobs" -ForegroundColor Green
        Set-ReFSDedupScrubSchedule -Volume "$devLetterColon" -Days $ScrubDays -Start $ScrubStart -WeeksInterval $ScrubWeeksInterval -ErrorAction Stop
        Write-Host "Scheduled weekly scrub job on $ScrubDays at $ScrubStart" -ForegroundColor Green

        Write-Host ""
        foreach ($line in (Resolve-DedupScheduleReminder -DailyTimes $DedupStartTimes `
                    -WeeklyDay $ScrubDays -WeeklyStart $ScrubStart -TaskTreePath $DedupTaskTreePath)) {
            Write-Host $line -ForegroundColor Cyan
        }
        Write-Host ""

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
    if (-not $VhdxAtBootGranted -and $VhdxMountAdvice) {
        Write-Host ""
        foreach ($line in $VhdxMountAdvice) {
            Write-Host $line -ForegroundColor Yellow
        }
    }
}
catch {
    Write-Host "An error occurred during Dev Drive creation:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow

    # A .vhdx created before the failure stays attached, and may already be set to attach at startup.
    if ($mode -eq "Vhdx" -and $VhdxPath -and (Test-Path -LiteralPath $VhdxPath)) {
        Write-Host "Left behind: $VhdxPath, still attached." -ForegroundColor Yellow
        if ($VhdxAtBootGranted) {
            Write-Host "It is also registered to attach on every startup. Dismounting clears that." -ForegroundColor Yellow
        }
        Write-Host "To remove it: Dismount-DiskImage -ImagePath '$VhdxPath'; Remove-Item -LiteralPath '$VhdxPath'" -ForegroundColor Yellow
    }

    foreach ($line in (Resolve-RerunAdvice -ShrunkDriveLetter $ShrunkDriveLetter)) {
        Write-Host $line -ForegroundColor Yellow
    }
    exit 1
}
