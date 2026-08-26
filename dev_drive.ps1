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

function Get-DiskLargestFreeExtent {
    <#
        The largest unbroken block of free space, which is the only thing New-Partition can fill.
        Disk size minus the partitions counts system and recovery partitions as free, and cannot see
        a gap split in two. A disk that does not report it answers 0, and says so on the warning stream.
    #>
    param([Parameter(Mandatory)]$Disk)

    $extent = $Disk.PSObject.Properties['LargestFreeExtent']
    if ($null -eq $extent -or $null -eq $extent.Value) {
        Write-Warning "Windows did not report a largest free extent for this disk, so it is being read as having no room."
        return 0
    }
    return [double]$extent.Value
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

function ConvertTo-ByteCount {
    # The other direction: a GB figure the user typed, as whole bytes for the storage cmdlets.
    param([Parameter(Mandatory)][decimal]$GB)
    return [uint64][math]::Round($GB * 1GB)
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
    param(
        [switch]$VhdxMode,
        [string[]]$Notes
    )

    Write-Host "`nDo you want to enable BitLocker encryption for the Dev Drive?" -ForegroundColor Cyan
    Write-Host "BitLocker provides security but may impact performance." -ForegroundColor White
    if ($VhdxMode) {
        Write-Host "If the volume hosting the .vhdx file is itself encrypted, its contents are already" -ForegroundColor Yellow
        Write-Host "covered, and Microsoft does not recommend encrypting the virtual disk as well." -ForegroundColor Yellow
    }
    # Printed before the menu, so a machine that makes encryption mandatory says so before the answer.
    foreach ($note in $Notes) {
        Write-Host $note -ForegroundColor Yellow
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

function Resolve-AutomationBanner {
    <#
        The warning printed before any check, so a run about to be refused still says up front
        what this script assumes of the person running it. Wording is agreed and must not drift.
    #>
    return @(
        "This script AUTOMATES work you are expected to be able to do by hand."
        ""
        "It assumes you understand what it touches - partitions, ReFS, BitLocker and scheduled"
        "tasks - and that you can carry out every step it takes, and reverse it, yourself. It"
        "does not resume after a failure, and it undoes nothing for you."
        ""
        "This is not a tool for learning any of that."
    )
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

function Get-BitLockerAutoUnlockState {
    <# Asks the volume whether automatic unlocking is really on; one that cannot answer says Unknown. #>
    param([Parameter(Mandatory)][string]$MountPoint)

    try {
        $volume = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
        if ($volume.AutoUnlockEnabled) { return 'Enabled' }
        return 'Disabled'
    }
    catch {
        return 'Unknown'
    }
}

function Get-FixedDriveWritePolicy {
    <# Reads FDVDenyWriteAccess where it takes effect, whatever channel delivered it. Absent means
       not set; Unknown means the read did not succeed, or answered something unreadable. #>
    param([string]$Path = $script:FixedDriveWritePolicyPath)

    try {
        if (-not (Test-Path -Path $Path -ErrorAction Stop)) { return 'Allow' }
        $key = Get-ItemProperty -Path $Path -ErrorAction Stop
        if ($null -eq $key.PSObject.Properties['FDVDenyWriteAccess']) { return 'Allow' }

        # A value of another type is an answer this cannot read, not an answer of "not set".
        $value = $key.FDVDenyWriteAccess
        if ($value -isnot [int] -and $value -isnot [long]) { return 'Unknown' }
        if ($value -eq 1) { return 'Deny' }
        return 'Allow'
    }
    catch {
        return 'Unknown'
    }
}

function Resolve-WriteAccessPolicyAdvice {
    <# What the setting means for this run: without BitLocker such a machine mounts the Dev Drive
       read-only. -Skipping is for the plan, where the answer is already known. #>
    param(
        [Parameter(Mandatory)][ValidateSet('Deny', 'Allow', 'Unknown')][string]$Policy,
        [string]$PolicyPath = $script:FixedDriveWritePolicyPath,
        [switch]$Skipping
    )

    if ($Policy -eq 'Allow') {
        return @()
    }

    if ($Policy -eq 'Unknown') {
        $lines = @("This machine's setting on unencrypted fixed drives could not be read, so it is not known whether the Dev Drive will accept writes without BitLocker.")
        $lines += "Read it with: Get-ItemProperty '$PolicyPath' -Name FDVDenyWriteAccess -ErrorAction SilentlyContinue"
        return $lines
    }

    $lines = @("This machine denies write access to fixed drives that BitLocker does not protect (FDVDenyWriteAccess is 1).")
    if ($Skipping) {
        $lines += "So this Dev Drive will mount read-only, and nothing can be written to it."
        $lines += "The run will stop at the write check once the drive exists. Enable BitLocker, or change that setting first."
    } else {
        $lines += "So a Dev Drive without BitLocker would mount read-only here, with nothing able to be written to it."
    }
    return $lines
}

function Resolve-BitLockerSetupPlan {
    <# Decides which protectors this machine can carry, and the lines explaining why. #>
    param(
        [switch]$DomainJoined,
        [switch]$EntraJoined,
        [switch]$VhdxMode,
        [switch]$OsDriveProtected,
        [ValidateSet('Deny', 'Allow', 'Unknown')][string]$WritePolicy = 'Allow'
    )

    $notes = @()

    # Warned on Unknown too: a read that failed is not evidence that the setting is off.
    if ($WritePolicy -eq 'Deny') {
        $notes += "Until this finishes the drive is read-only, because this machine denies writes to fixed drives BitLocker does not protect."
    }
    if ($WritePolicy -ne 'Allow') {
        $notes += "Windows may put up its own prompt to encrypt the drive while this runs. Leave it alone - this run is already encrypting, and answering it only produces an error."
    }

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

    # @() first: a $null argument reaches the filter as one $null item, and strict mode refuses to
    # read a property off it.
    $recovery = @(@($KeyProtector) | Where-Object { $null -ne $_ -and $_.KeyProtectorType -eq 'RecoveryPassword' })
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

function Format-DevDriveStateAfterFailure {
    <# What the drive is once BitLocker has failed. -RunEnding adds the next step for a run that
       stops here, where nothing further will be printed to offer one. #>
    param(
        [ValidateSet('Encrypted', 'Clear', 'Unknown')][string]$VolumeState = 'Unknown',
        [switch]$RunEnding
    )

    if ($VolumeState -eq 'Encrypted') {
        $lines = @("The Dev Drive is created and formatted, and BitLocker has already started encrypting it.")
        if ($RunEnding) {
            $lines += "Its recovery key is the way back into it. Read it with: (Get-BitLockerVolume -MountPoint <drive>).KeyProtector"
        }
        return $lines
    }
    if ($VolumeState -eq 'Clear') {
        return "The Dev Drive itself is created and formatted, and works without BitLocker."
    }
    return "The Dev Drive is created and formatted, but its BitLocker state could not be read. Check it with Get-BitLockerVolume before assuming it is unencrypted."
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
        [int]$HResult = 0,
        [switch]$Unretryable,
        [switch]$PasswordAsked
    )

    $exhausted = $RetryCount -ge $MaxRetries
    $canRetry = -not $exhausted -and -not $Unretryable

    # The number, not only the rendering of it: .NET puts the code in the message text too, but that
    # is one formatting choice away from being absent, and the exception carries it either way.
    $searchable = $Message
    if ($HResult -ne 0) {
        # 0xFFFFFFFFL, not 0xFFFFFFFF: the second is Int32 -1 and masks nothing off a negative code.
        $searchable += ' 0x{0:X8}' -f [uint32]($HResult -band 0xFFFFFFFFL)
    }

    # Both sets are matched by code, because the sentence around each comes from a localized
    # message resource. Policy refusals: no recovery key, no password, FIPS forbids passwords.
    $policyRefusal = $searchable -match '0x8031005E|0x8031006A|0x8031006C'
    if ($policyRefusal) {
        $canRetry = $false
    }

    # Password refusals: too short, too simple, not printable ASCII, over 256 characters.
    $passwordRefusal = $searchable -match '0x80310080|0x80310081|0x803100A4|0x803100AA'

    # Only a run that asked for a password can be failing on one, whatever the message carries.
    if (-not $policyRefusal -and $PasswordAsked -and $passwordRefusal) {
        # Quoted, not diagnosed: three of those four refusals are about something else.
        $lines = @("BitLocker did not accept that password. Windows reported: $Message")
        if ($canRetry) {
            $lines += "Please try a different password. Attempt $RetryCount of $MaxRetries."
        } else {
            # The run ends here, so it must say what the drive is, as every other failure path does.
            $lines += "Maximum retry attempts reached. BitLocker setup failed."
            $lines += Format-DevDriveStateAfterFailure -VolumeState $VolumeState -RunEnding
        }
        return [PSCustomObject]@{ Kind = 'Password'; Exhausted = $exhausted; CanRetry = $canRetry; Lines = $lines }
    }

    $lines = @("BitLocker setup did not finish. Windows reported: $Message")
    if ($policyRefusal) {
        # Not named: two of those three codes are group policy and one is FIPS, and the line above
        # already quotes which. Naming the wrong setting sends someone to the wrong place.
        $lines += "This machine refuses it, so trying again meets the same refusal."
    }
    $lines += Format-DevDriveStateAfterFailure -VolumeState $VolumeState

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

function Resolve-BitLockerAutoUnlockReport {
    <#
        What to say about automatic unlocking once the volume itself has been asked. Its absence is
        a convenience lost, not a failed setup, and it costs a manual unlock after every restart.
    #>
    param(
        [Parameter(Mandatory)][string]$MountPoint,
        [Parameter(Mandatory)][ValidateSet('Enabled', 'Failed', 'Unconfirmed', 'Deferred', 'NotOffered')][string]$Outcome,
        [AllowNull()][AllowEmptyString()][string]$Message
    )

    # Built once: every outcome but success ends in the same consequence, worded the same way.
    $byHand = "drive $MountPoint has to be unlocked by hand after every restart"
    $command = "Enable-BitLockerAutoUnlock -MountPoint $MountPoint"

    switch ($Outcome) {
        'Enabled' {
            return @("Drive $MountPoint unlocks automatically, and the volume confirms it.")
        }
        'Failed' {
            # Says nothing about the encryption: the line above this one read that off the volume.
            return @(
                "Automatic unlocking could not be set up on drive $MountPoint."
                "Windows reported: $Message"
                "So $byHand."
                "Set it up later, if this machine allows it, with: $command"
            )
        }
        'Unconfirmed' {
            return @(
                "Automatic unlocking was set up on $MountPoint without an error, but the volume does not confirm it is on."
                "Check it with: (Get-BitLockerVolume -MountPoint $MountPoint).AutoUnlockEnabled"
                "Until that answers True, assume $byHand."
            )
        }
        'Deferred' {
            return @(
                "Automatic unlocking needs the volume unlocked first, so set it up afterwards with: $command"
                "Until then, $byHand."
            )
        }
        'NotOffered' {
            return @("The operating system drive is not BitLocker-protected, so automatic unlocking was skipped and $byHand.")
        }
        default {
            throw "No wording for the automatic unlocking outcome '$Outcome'."
        }
    }
}

function Resolve-DevDriveTrustReport {
    <#
        What to say after marking a volume trusted. Only fsutil's own words answer whether it is:
        measured, the exit code is 0 for every real volume, the persistent volume flags read back
        as zero, and no CIM property carries it. Those words are localized, so an answer this
        script cannot read is shown, never judged.
    #>
    param(
        [Parameter(Mandatory)][string]$MountPoint,
        [Parameter(Mandatory)][int]$TrustExitCode,
        [AllowNull()][AllowEmptyString()][string]$QueryOutput
    )

    if ($TrustExitCode -eq 0 -and $QueryOutput -match '(?im)^\s*This is a trusted developer volume') {
        return [PSCustomObject]@{
            Outcome = 'Trusted'
            Lines   = @("Dev Drive $MountPoint reports itself trusted, which is the signal for Microsoft Defender to run in performance mode.")
        }
    }

    $said = @($QueryOutput -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($TrustExitCode -eq 0) {
        # This is what a successful run looks like on a Windows that is not in English, so it must
        # not read as a fault. Nothing else on the machine can be asked instead - see the notes on
        # the English phrase above.
        $lines = @("Marked $MountPoint as trusted. Reading it back only works in English, and this machine answers in its own language, so the run cannot confirm it here.")
        $lines += "fsutil devdrv query $MountPoint said:"
        $lines += if ($said.Count -gt 0) { $said | ForEach-Object { "  $($_.Trim())" } } else { "  (nothing)" }
        $lines += "If that says the volume is a trusted developer volume, everything is as it should be."
        return [PSCustomObject]@{ Outcome = 'Unconfirmed'; Lines = $lines }
    }

    $lines = @("Could not mark $MountPoint as trusted (fsutil exited with code $TrustExitCode).")
    if ($said.Count -gt 0) {
        $lines += "fsutil devdrv query $MountPoint said:"
        $lines += $said | ForEach-Object { "  $($_.Trim())" }
    } else {
        $lines += "fsutil devdrv query $MountPoint said nothing."
    }
    $lines += "The Dev Drive will still work, but without the Defender performance mode trust enables."
    $lines += "Retry by hand with: fsutil devdrv trust /f $MountPoint"
    return [PSCustomObject]@{ Outcome = 'Failed'; Lines = $lines }
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
            # This path is reached before the automatic-unlock step, so it never ran.
            "Automatic unlocking was never set up, so drive $MountPoint has to be unlocked by hand after every restart."
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
    Write-Host "`nWhat should Windows do with the data on the Dev Drive?" -ForegroundColor Cyan
    Write-Host "Deduplication finds and removes duplicate data. Compression makes what is left smaller." -ForegroundColor White
    Write-Host "1. Deduplicate only (recommended for most users)" -ForegroundColor White
    Write-Host "2. Deduplicate and compress (saves the most space)" -ForegroundColor White
    Write-Host "3. Compress only, without looking for duplicates" -ForegroundColor White
    Write-Host "4. Neither (maximum performance, less space saved)" -ForegroundColor White
    Write-Host ""

    $answers = @{ '1' = 'Dedup'; '2' = 'DedupAndCompress'; '3' = 'Compress'; '4' = 'None' }
    while ($true) {
        $choice = Read-Host "Enter your choice (1, 2, 3 or 4)"
        if ($answers.ContainsKey([string]$choice)) {
            return $answers[[string]$choice]
        }
        Write-Host "Invalid choice. Please enter 1, 2, 3 or 4." -ForegroundColor Red
    }
}

function Format-DedupModeChoice {
    <# Names what a mode does, and the compression only where there is any. #>
    param(
        [Parameter(Mandatory)][ValidateSet('Dedup', 'DedupAndCompress', 'Compress')][string]$Mode,
        [AllowNull()][AllowEmptyString()][string]$Format,
        [Nullable[int]]$Level
    )

    if ($Mode -eq 'Dedup') {
        return "deduplication only, without compression"
    }

    $compression = Format-CompressionChoice -Format $Format -Level $Level
    if ($Mode -eq 'Compress') {
        return "$compression, without deduplication"
    }
    return "deduplication and $compression"
}

function Request-CompressionFormat {
    Write-Host "`nChoose compression format:" -ForegroundColor Cyan
    Write-Host "1. LZ4: Fast compression with good balance of speed and compression ratio" -ForegroundColor White
    Write-Host "2. ZSTD: Better compression ratio but uses more CPU" -ForegroundColor White
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

function Request-Compression {
    <# The format and the level together, so a chosen format is never left waiting for a level. #>
    Write-Host "`nChoose compression:" -ForegroundColor Cyan
    Write-Host "1. Fast - LZ4, at the level Windows picks" -ForegroundColor White
    Write-Host "2. Balanced - ZSTD, at the level Windows picks" -ForegroundColor White
    Write-Host "3. Pick the format and level yourself" -ForegroundColor White
    Write-Host ""

    $shortcuts = @{ '1' = 'LZ4'; '2' = 'ZSTD' }
    while ($true) {
        $choice = Read-Host "Enter your choice (1, 2 or 3)"
        if ($shortcuts.ContainsKey([string]$choice)) {
            return [PSCustomObject]@{ Format = $shortcuts[[string]$choice]; Level = $null }
        }
        if ([string]$choice -eq '3') {
            $format = Request-CompressionFormat
            return [PSCustomObject]@{ Format = $format; Level = Request-CompressionLevel -Format $format }
        }
        Write-Host "Invalid choice. Please enter 1, 2 or 3." -ForegroundColor Red
    }
}

function Get-CompressionLevelRange {
    <# The levels each format takes, per the refsutil compression reference. LZ4 skips 2. #>
    param([Parameter(Mandatory)][ValidateSet('LZ4', 'ZSTD')][string]$Format)

    if ($Format -eq 'LZ4') {
        return [PSCustomObject]@{ Allowed = @(1) + (3..12); Label = 'level 1, or 3 to 12' }
    }
    return [PSCustomObject]@{ Allowed = 1..22; Label = 'levels 1 to 22' }
}

function Resolve-CompressionLevelInput {
    <#
        Decides what one typed compression level means. An empty answer is the documented way to
        leave the level to Windows, and comes back as no level rather than as a number.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('LZ4', 'ZSTD')][string]$Format,
        [AllowNull()][AllowEmptyString()][string]$Answer
    )

    $result = [PSCustomObject]@{ Rejection = $null; Level = $null }

    if ([string]::IsNullOrWhiteSpace($Answer)) {
        return $result
    }

    # [0-9] not \d, which also matches other alphabets' digits; the length cap keeps a long run of
    # digits from overflowing the cast below.
    $trimmed = $Answer.Trim()
    if ($trimmed -notmatch '^[0-9]+$' -or $trimmed.Length -gt 2) {
        $result.Rejection = 'NotANumber'
        return $result
    }

    # Zero is what the documentation calls "use the default", which here is said by answering nothing.
    $level = [int]$trimmed
    if ($level -eq 0) {
        return $result
    }

    if ((Get-CompressionLevelRange -Format $Format).Allowed -notcontains $level) {
        $result.Rejection = 'OutOfRange'
        return $result
    }

    $result.Level = $level
    return $result
}

function Request-CompressionLevel {
    param([Parameter(Mandatory)][ValidateSet('LZ4', 'ZSTD')][string]$Format)

    $range = Get-CompressionLevelRange -Format $Format
    Write-Host "`nChoose the $Format compression level:" -ForegroundColor Cyan
    Write-Host "$Format accepts $($range.Label)." -ForegroundColor White
    if ($Format -eq 'LZ4') {
        Write-Host "Levels 3 and above use the LZ4HC algorithm: smaller, and slower to compress." -ForegroundColor White
    } else {
        Write-Host "Higher levels compress smaller and slower, and levels 20 and above can need noticeably more memory." -ForegroundColor White
    }
    Write-Host "Decompression is the same speed whichever level you pick." -ForegroundColor White
    Write-Host ""

    while ($true) {
        $answer = Read-Host "Enter a level, or press Enter for the level Windows picks"
        $parsed = Resolve-CompressionLevelInput -Format $Format -Answer $answer
        if (-not $parsed.Rejection) {
            return $parsed.Level
        }
        if ($parsed.Rejection -eq 'NotANumber') {
            Write-Host "That is not a level. Enter a plain number, or nothing at all to leave it to Windows." -ForegroundColor Red
        } else {
            Write-Host "$Format accepts $($range.Label). Enter one of those, or nothing at all to leave it to Windows." -ForegroundColor Red
        }
    }
}

function Format-CompressionChoice {
    <# Names the format, and a level only when one was chosen; an unset level is Windows' own. #>
    param(
        [Parameter(Mandatory)][ValidateSet('LZ4', 'ZSTD')][string]$Format,
        [Nullable[int]]$Level
    )

    if ($null -ne $Level) {
        return "$Format compression, level $Level"
    }
    return "$Format compression"
}

function Format-DedupScheduleStart {
    <# The HH:mm a schedule reports, rendered invariantly so regional format cannot change what a
       read-back compares. Anything that is not a date and time answers empty. #>
    param([Parameter(Mandatory)][AllowNull()]$Start)

    if ($Start -is [datetime]) {
        return $Start.ToString('HH\:mm', [cultureinfo]::InvariantCulture)
    }
    return ''
}

function Get-DedupVolumeReport {
    <#
        What the volume says about its own deduplication settings, or why it could not say. A volume
        holds one schedule: Set-ReFSDedupSchedule replaces rather than adds.
    #>
    param([Parameter(Mandatory)][string]$MountPoint)

    try {
        $schedules = @(Get-ReFSDedupSchedule -Volume $MountPoint -ErrorAction Stop)
    }
    catch {
        return [PSCustomObject]@{
            Known  = $false
            Reason = "Windows said: $($_.Exception.GetBaseException().Message)"
            Mode = ''; Format = ''; Level = 0; Start = ''
        }
    }

    # An empty answer is the volume saying there is no schedule, not the volume failing to answer.
    if ($schedules.Count -eq 0) {
        return [PSCustomObject]@{
            Known  = $false
            Reason = "The volume reports no schedule at all, although one was just written to it."
            Mode = ''; Format = ''; Level = 0; Start = ''
        }
    }

    return [PSCustomObject]@{
        Known  = $true
        Reason = ''
        Mode   = [string]$schedules[0].Type
        Format = [string]$schedules[0].CompressionFormat
        Level  = [int]$schedules[0].CompressionLevel
        Start  = Format-DedupScheduleStart -Start $schedules[0].Start
    }
}

function Resolve-DedupReadBackVerdict {
    <#
        Compares what was asked for against what the volume reports. A reported level of 0 is how it
        says "the default", which is what asking for no level means.
    #>
    param(
        [Parameter(Mandatory)][string]$MountPoint,
        [Parameter(Mandatory)][ValidateSet('Dedup', 'DedupAndCompress', 'Compress')][string]$ExpectedMode,
        [AllowNull()][AllowEmptyString()][string]$ExpectedFormat,
        [Nullable[int]]$ExpectedLevel,
        [Parameter(Mandatory)][string]$ExpectedStart,
        [Parameter(Mandatory)]$Actual
    )

    if (-not $Actual.Known) {
        $lines = @("Could not confirm the deduplication settings on $MountPoint.")
        if (-not [string]::IsNullOrWhiteSpace($Actual.Reason)) {
            $lines += $Actual.Reason
        }
        $lines += "Check them by hand with: Get-ReFSDedupSchedule -Volume $MountPoint"
        return [PSCustomObject]@{ Agrees = $false; Lines = $lines }
    }

    $reportedLevel = if ($Actual.Level -eq 0) { $null } else { $Actual.Level }
    $compresses = (Resolve-DedupModeCapability -Mode $ExpectedMode).UsesCompression

    $differences = @()
    if ($Actual.Mode -ne $ExpectedMode) {
        $differences += "mode: asked for $ExpectedMode, the volume reports $($Actual.Mode)"
    }
    # The one setting a caller can silently fail to write: the cmdlet replaces the schedule.
    if ([string]::IsNullOrWhiteSpace($Actual.Start)) {
        $differences += "start time: asked for $ExpectedStart, the volume reported none that could be read"
    }
    elseif ($Actual.Start -ne $ExpectedStart) {
        $differences += "start time: asked for $ExpectedStart, the volume reports $($Actual.Start)"
    }
    if ($compresses -and $Actual.Format -ne $ExpectedFormat) {
        $differences += "compression format: asked for $ExpectedFormat, the volume reports $($Actual.Format)"
    }
    # No level asked for means any level is right, because Windows chose it.
    if ($compresses -and $null -ne $ExpectedLevel -and $Actual.Level -ne $ExpectedLevel) {
        $reported = if ($null -eq $reportedLevel) { 'the default' } else { "level $reportedLevel" }
        $differences += "compression level: asked for level $ExpectedLevel, the volume reports $reported"
    }

    if ($differences.Count -gt 0) {
        $lines = @("$MountPoint was set up, but does not report back what was asked for:")
        $lines += $differences | ForEach-Object { "  $_" }
        $lines += "The Dev Drive is created and usable. Check them by hand with: Get-ReFSDedupSchedule -Volume $MountPoint"
        return [PSCustomObject]@{ Agrees = $false; Lines = $lines }
    }

    $lines = @("$MountPoint confirms it: $(Format-DedupModeChoice -Mode $Actual.Mode -Format $Actual.Format -Level $reportedLevel).")
    if ($compresses -and $null -eq $reportedLevel) {
        $lines += "The compression level is the one Windows picks."
    }
    return [PSCustomObject]@{ Agrees = $true; Lines = $lines }
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

function Resolve-DedupModeCapability {
    <# What a mode's jobs take: a compression-only volume refuses the block deduplication
       parameters, and has no scrub schedule at all. #>
    param([Parameter(Mandatory)][ValidateSet('Dedup', 'DedupAndCompress', 'Compress')][string]$Mode)

    return [PSCustomObject]@{
        UsesCompression = $Mode -ne 'Dedup'
        UsesBlockDedup  = $Mode -ne 'Compress'
    }
}

function Format-DedupDailyJobNote {
    <# What holds the daily job back. Compression alone takes neither: the CPU share is refused,
       the duration accepted and dropped. #>
    param(
        [Parameter(Mandatory)][int]$DurationHours,
        [Parameter(Mandatory)][int]$CpuPercent,
        [switch]$BlockDedup
    )

    if ($BlockDedup) {
        return "The daily job runs on mains power only, for up to $DurationHours hours, using at most $CpuPercent% of the CPU."
    }
    return "The daily job runs on mains power only. Windows takes no time limit and no CPU share for compression."
}

function Format-DedupScheduleSummary {
    <# The lines saying when the jobs run, shown while choosing and in the plan; a volume that only
       compresses gets no weekly line. #>
    param(
        [Parameter(Mandatory)][string]$DailyTime,
        [Parameter(Mandatory)][string]$DailyDaysLabel,
        [string]$WeeklyDay,
        [string]$WeeklyStart,
        [int]$WeeksInterval = 1,
        [switch]$WeeklyJob
    )

    $lines = @("  Daily optimization : $DailyDaysLabel at $DailyTime")
    if ($WeeklyJob) {
        $weeks = if ($WeeksInterval -eq 1) { "every 1 week" } else { "every $WeeksInterval weeks" }
        $lines += "  Weekly maintenance : $WeeklyDay at $WeeklyStart, $weeks"
    }
    return $lines
}

function Resolve-DedupTaskName {
    <#
        A volume's deduplication tasks are named after the volume's own identifier: nothing else in
        the task names the drive. An identifier not shaped that way answers $null.
    #>
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$UniqueId)

    if ([string]::IsNullOrWhiteSpace($UniqueId)) { return $null }

    # Anchored on the whole volume path: a volume with no GUID answers with a device path that
    # carries a class GUID instead, and an unanchored match would name a task after that.
    $braced = [regex]::Match($UniqueId, '^\\\\\?\\Volume(\{[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\})\\?$')
    if (-not $braced.Success) { return $null }

    return $braced.Groups[1].Value.ToUpperInvariant()
}

function Resolve-OwnDedupTask {
    <#
        Which of the folder's tasks belong to this volume. Everything else there belongs to another
        drive, or to a volume that no longer exists.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Tasks,
        [Parameter(Mandatory)][string]$VolumeTaskName
    )

    # Prefix, not equality: the scrub task appends a suffix to the same name.
    return @($Tasks | Where-Object {
            $_.TaskName.StartsWith($VolumeTaskName, [System.StringComparison]::OrdinalIgnoreCase)
        })
}

function Resolve-DedupScheduleReminder {
    <#
        The lines telling the user where these schedule times live and how to change them later.
        Names the tasks that were read back out of that folder, and falls back to the times when
        none were, because then there is nothing to name.
    #>
    param(
        [Parameter(Mandatory)][string]$DailyTime,
        [string]$WeeklyDay,
        [string]$WeeklyStart,
        [Parameter(Mandatory)][string]$TaskTreePath,
        [string[]]$TaskNames,
        [string]$VolumeTaskName,
        [switch]$WeeklyJob
    )

    $chosen = "Times just chosen: $DailyTime daily"
    $chosen += if ($WeeklyJob) { ", $WeeklyDay at $WeeklyStart weekly." } else { "." }

    $lines = @(
        "The ReFS optimization runs on a schedule kept in Task Scheduler, under:"
        "  $TaskTreePath"
        ""
        $chosen
        ""
    )

    # Said whether or not the tasks could be named, because it is about the schedule, not the folder.
    $extraTriggers = @(
        ""
        "Windows keeps one daily start time per volume, which is why one is asked for. Task Scheduler"
        "will let you add further triggers to the daily task by hand, on its Triggers tab. Two things"
        "to know before you do: nothing here reports such triggers back, and the next time a schedule"
        "is written for this drive - by rerunning this script, or by Set-ReFSDedupSchedule - they are"
        "removed. Whether the optimization actually runs on a trigger added that way has not been"
        "confirmed here."
    )

    $named = @($TaskNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($named.Count -eq 0) {
        return $lines + @(
            "To change the time later, press Win+R, type taskschd.msc and press Ctrl+Shift+Enter to open"
            "it as administrator, then open that folder and find the tasks whose Triggers column matches"
            "what is named above. Edit them on the Triggers tab. Leave the Actions tab alone - that is"
            "what actually runs the optimization."
            ""
            "Other tasks in that folder may belong to Windows or to earlier runs."
        ) + $extraTriggers
    }

    $lines += "This drive's tasks, named after the volume itself:"
    foreach ($name in $named) {
        # The daily task carries the volume name alone; the scrub task adds to it.
        $lines += if ($name -eq $VolumeTaskName) { "  $name  - the daily job" }
        else { "  $name  - the weekly maintenance job" }
    }

    return $lines + @(
        ""
        "To change the time later, press Win+R, type taskschd.msc and press Ctrl+Shift+Enter to open"
        "it as administrator, then open that folder and look for those names. Edit the times on the"
        "Triggers tab. Leave the Actions tab alone - that is what actually runs the optimization."
        ""
        "The other tasks in that folder belong to Windows, to another drive, or to a volume that no"
        "longer exists."
    ) + $extraTriggers
}

function Request-DedupSchedule {
    <#
        The one question about when the jobs run, with follow-ups for a user who wants to pick the
        times. The weekly ones are asked only where a weekly job exists to run at them.
    #>
    param(
        [Parameter(Mandatory)][string]$DailyTime,
        [Parameter(Mandatory)][string]$DailyDaysLabel,
        [string]$WeeklyDay,
        [string]$WeeklyStart,
        [int]$WeeksInterval = 1,
        [Parameter(Mandatory)][int]$DailyDurationHours,
        [Parameter(Mandatory)][int]$DailyCpuPercent,
        [switch]$BlockDedup
    )

    $chosenTime = $DailyTime
    $chosenDay = $WeeklyDay
    $chosenStart = $WeeklyStart

    Write-Host "`n=== OPTIMIZATION SCHEDULE ===" -ForegroundColor Cyan
    Write-Host ""
    foreach ($line in (Format-DedupScheduleSummary -DailyTime $chosenTime -DailyDaysLabel $DailyDaysLabel `
                -WeeklyDay $chosenDay -WeeklyStart $chosenStart -WeeksInterval $WeeksInterval -WeeklyJob:$BlockDedup)) {
        Write-Host $line -ForegroundColor White
    }
    Write-Host ""
    Write-Host (Format-DedupDailyJobNote -DurationHours $DailyDurationHours -CpuPercent $DailyCpuPercent -BlockDedup:$BlockDedup) -ForegroundColor White
    Write-Host "1. Use this schedule (recommended)" -ForegroundColor White
    Write-Host "2. Change it" -ForegroundColor White
    Write-Host ""

    while ($true) {
        $choice = Read-Host "Enter your choice (1 or 2)"
        if ($choice -eq "1" -or $choice -eq "2") {
            break
        }
        Write-Host "Invalid choice. Please enter 1 or 2." -ForegroundColor Red
    }

    if ($choice -eq "2") {
        while ($true) {
            Write-Host "`nStart time for the daily optimization, one time, 24-hour HH:MM (for example 08:15)." -ForegroundColor Cyan
            $answer = Read-Host "Press Enter to keep $chosenTime"
            $verdict = Resolve-DedupTimeInput -Answer $answer -CurrentTime $chosenTime -AllowEmpty

            if ($verdict.Rejection) {
                Write-Host "Invalid time. Enter one time as HH:MM on a 24-hour clock, for example 08:15." -ForegroundColor Red
                continue
            }

            $chosenTime = $verdict.Time
            break
        }

        if ($BlockDedup) {
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
        }

        Write-Host ""
        foreach ($line in (Format-DedupScheduleSummary -DailyTime $chosenTime -DailyDaysLabel $DailyDaysLabel `
                    -WeeklyDay $chosenDay -WeeklyStart $chosenStart -WeeksInterval $WeeksInterval -WeeklyJob:$BlockDedup)) {
            Write-Host $line -ForegroundColor Green
        }
    }

    return [PSCustomObject]@{ DailyTime = $chosenTime; WeeklyDay = $chosenDay; WeeklyStart = $chosenStart }
}

function Resolve-ShrinkPlan {
    <#
        What shrinking a partition by the requested amount produces. SizeMax is the partition's size
        plus the unallocated run right behind it, so the space left free by the resize is SizeMax
        minus the new size, not the amount asked for. Rejection is $null when the numbers work.
    #>
    param(
        [Parameter(Mandatory)][uint64]$CurrentSize,
        [Parameter(Mandatory)][uint64]$MaxSize,
        [Parameter(Mandatory)][uint64]$MinSize,
        [Parameter(Mandatory)][uint64]$ShrinkBytes
    )

    $result = [PSCustomObject]@{
        Rejection = $null; TargetBytes = [uint64]0; DevDriveBytes = [uint64]0; AdjoiningBytes = [uint64]0
    }

    # Guards before the subtraction: a difference that goes negative is not a size.
    if ($MaxSize -lt $CurrentSize) { $result.Rejection = 'MaxBelowCurrent'; return $result }
    if ($ShrinkBytes -ge $CurrentSize) { $result.Rejection = 'ShrinkExceedsPartition'; return $result }

    $target = $CurrentSize - $ShrinkBytes
    if ($target -lt $MinSize) { $result.Rejection = 'TargetBelowMinimum'; return $result }

    $result.TargetBytes = $target
    $result.DevDriveBytes = $MaxSize - $target
    $result.AdjoiningBytes = $MaxSize - $CurrentSize
    return $result
}

function Resolve-AlignedPlacement {
    <#
        Where a partition can actually start in the run just freed. New-Partition refuses an offset
        that is not a whole number of megabytes, and a resize lands wherever the cluster size leaves
        it, so the start is nudged forward and the size gives back exactly what the nudge took.
    #>
    param(
        [Parameter(Mandatory)][uint64]$Offset,
        [Parameter(Mandatory)][uint64]$Size
    )

    $result = [PSCustomObject]@{ Rejection = $null; Offset = [uint64]0; Size = [uint64]0; ShiftedBy = [uint64]0 }

    # Integer arithmetic throughout: a byte offset this large loses precision as a double.
    $remainder = $Offset % 1MB
    $shift = if ($remainder -eq 0) { [uint64]0 } else { [uint64](1MB - $remainder) }
    if ($shift -ge $Size) { $result.Rejection = 'NothingLeftAfterAligning'; return $result }

    $result.Offset = $Offset + $shift
    $result.Size = $Size - $shift
    $result.ShiftedBy = $shift
    return $result
}

function Format-ShrinkRefusal {
    <# Why a shrink cannot go ahead, in the user's terms. One wording for both call sites, so
       neither drifts nor prints a rejection name. #>
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][decimal]$ShrinkGB,
        [Parameter(Mandatory)][ValidateSet('MaxBelowCurrent', 'ShrinkExceedsPartition', 'TargetBelowMinimum')][string]$Rejection,
        [Parameter(Mandatory)][decimal]$MinSizeGB,
        [Parameter(Mandatory)][decimal]$CurrentSizeGB
    )

    switch ($Rejection) {
        'TargetBelowMinimum' {
            return @("Cannot shrink drive ${DriveLetter}: by $ShrinkGB GB; Windows will not take it below $MinSizeGB GB.")
        }
        'ShrinkExceedsPartition' {
            return @("Cannot shrink drive ${DriveLetter}: by $ShrinkGB GB; the whole volume is only $CurrentSizeGB GB.")
        }
        'MaxBelowCurrent' {
            return @("Cannot plan a shrink for drive ${DriveLetter}: Windows reports a maximum size below its current size.")
        }
        # A rejection added to Resolve-ShrinkPlan must be given wording here, not inherit somebody else's.
        default { throw "Format-ShrinkRefusal has no wording for $Rejection" }
    }
}

function Format-ShrinkAdjoiningNote {
    <# The one line shown beside the shrink limits: what already sits behind the drive and joins it. #>
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][decimal]$AdjoiningGB
    )

    if ($AdjoiningGB -le 0) { return @() }
    return @("  Unallocated right behind ${DriveLetter}: $AdjoiningGB GB - it joins the new Dev Drive")
}

function Format-ShrinkSizeNote {
    <# Says the drive will come out bigger than the amount freed, and why. Nothing to say when no
       unallocated space adjoins the partition. #>
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][decimal]$ShrinkGB,
        [Parameter(Mandatory)][decimal]$DevDriveGB
    )

    # Taken as the difference between the two figures shown, so the three always add up on screen.
    $extraGB = $DevDriveGB - $ShrinkGB
    if ($extraGB -le 0) { return @() }

    return @(
        "$extraGB GB of unallocated space already sits next to drive ${DriveLetter}: and will be taken"
        "as well, so the Dev Drive comes out $DevDriveGB GB rather than the $ShrinkGB GB being freed."
    )
}

function New-PlanLine {
    <# One line of the plan: the text, and the colour the run prints it in. The colour is typed, so
       a mistyped one fails on the way in rather than halfway through printing the plan. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [System.ConsoleColor]$Colour = 'White'
    )

    return [PSCustomObject]@{ Text = $Text; Colour = $Colour }
}

function Format-CreationPlan {
    <#
        Every line of the plan the user approves, decided here so the screen that asks for consent
        can be tested. A mode's keys are present only where its branch asked the question.
    #>
    param([Parameter(Mandatory)][hashtable]$Answers)

    if ($Answers.Mode -notin @('FreeSpace', 'ShrinkDrive', 'Vhdx')) {
        throw "Format-CreationPlan has no plan for mode '$($Answers.Mode)'"
    }

    $rule = '==============================================================================='
    $lines = @(
        New-PlanLine -Text $rule -Colour Cyan
        New-PlanLine -Text '                        DEV DRIVE CREATION PLAN' -Colour Cyan
        New-PlanLine -Text $rule -Colour Cyan
        New-PlanLine -Text ''
    )

    if ($Answers.Mode -eq 'ShrinkDrive') {
        $lines += New-PlanLine -Text "* Shrink Drive $($Answers.DriveLetter) ($($Answers.DriveLabel)) by $($Answers.ShrinkGB) GB to free up space"
    }

    if ($Answers.Mode -eq 'Vhdx') {
        $lines += New-PlanLine -Text "* Create a $($Answers.SizeGB) GB $($Answers.VhdxDiskType) virtual hard disk at $($Answers.VhdxPath)"
        if ($Answers.VhdxDiskType -eq 'Fixed') {
            $lines += New-PlanLine -Text '  (a fixed size disk claims all of its space up front, which takes a while)' -Colour Gray
        }
        # Said here because the physical modes refuse an uninitialized disk instead.
        $lines += New-PlanLine -Text "* Initialize the new virtual disk with a $($Answers.PartitionStyle) partition table"
        $lines += New-PlanLine -Text '* Format the attached virtual disk as a Dev Drive using ReFS'
        $lines += if ($Answers.VhdxAutoAttach) {
            New-PlanLine -Text '* Register the virtual disk to be mounted on every Windows startup'
        } else {
            New-PlanLine -Text '* Skip automatic mounting; the Dev Drive mount point is gone after every restart until mounted by hand'
        }
    } else {
        $lines += New-PlanLine -Text "* Create $($Answers.SizeGB) GB Dev Drive on Disk $($Answers.DiskNumber) ($($Answers.DiskName)) using ReFS"
        if ($Answers.Mode -eq 'ShrinkDrive') {
            if ($null -eq $Answers.ShrinkAdjoiningGB) {
                # Windows would not say how much sits behind the drive, so the size above is a floor.
                $lines += New-PlanLine -Text '  About this much, and likely more: the drive also takes any unallocated space already' -Colour Yellow
                $lines += New-PlanLine -Text "  behind $($Answers.DriveLetter):, which could not be measured beforehand. Its real size is reported once it exists." -Colour Yellow
            }
            else {
                foreach ($note in (Format-ShrinkSizeNote -DriveLetter $Answers.DriveLetter `
                            -ShrinkGB $Answers.ShrinkGB -DevDriveGB $Answers.SizeGB)) {
                    $lines += New-PlanLine -Text "  $note" -Colour Yellow
                }
            }
        }
    }

    $lines += New-PlanLine -Text "* Name the Dev Drive $($Answers.DevDriveLabel)"

    if ($Answers.SkipBitLocker) {
        $lines += New-PlanLine -Text '* Skip BitLocker encryption'
        # Said here, before anything exists, rather than left for the write check to discover afterwards.
        foreach ($advice in (Resolve-WriteAccessPolicyAdvice -Policy $Answers.WritePolicy -Skipping)) {
            $lines += New-PlanLine -Text "  - $advice" -Colour Yellow
        }
    } else {
        $lines += New-PlanLine -Text '* Enable BitLocker encryption for the Dev Drive'
        foreach ($note in $Answers.BitLockerNotes) {
            $lines += New-PlanLine -Text "  - $note" -Colour Gray
        }
    }

    if ($Answers.SkipDeduplication) {
        $lines += New-PlanLine -Text '* Skip deduplication and compression setup'
    } else {
        $lines += New-PlanLine -Text ("* Enable ReFS " + (Format-DedupModeChoice -Mode $Answers.DedupMode `
                    -Format $Answers.CompressionFormat -Level $Answers.CompressionLevel))
        foreach ($summary in (Format-DedupScheduleSummary -DailyTime $Answers.DedupStartTime `
                    -DailyDaysLabel $Answers.DedupDailyDaysLabel -WeeklyDay $Answers.ScrubDays `
                    -WeeklyStart $Answers.ScrubStart -WeeksInterval $Answers.ScrubWeeksInterval `
                    -WeeklyJob:$Answers.DedupWeeklyJob)) {
            $lines += New-PlanLine -Text "* $($summary.Trim())"
        }
    }

    $lines += New-PlanLine -Text '* Mark Dev Drive as trusted for Windows Defender performance'
    $lines += New-PlanLine -Text '* Run initial optimization job to prepare the drive'
    $lines += New-PlanLine -Text '' -Colour Cyan
    $lines += New-PlanLine -Text $rule -Colour Cyan
    return $lines
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

function Resolve-DevDriveLabelInput {
    <# Decides what one typed answer to the name question means. Rejection is $null when the answer
       is good, and an empty answer keeps the offered name. #>
    param(
        [AllowEmptyString()][string]$Answer,
        [Parameter(Mandatory)][string]$Default,
        [int]$MaxLength = $script:DevDriveLabelMaxLength
    )

    $result = [PSCustomObject]@{ Rejection = $null; Label = $null; RejectedCharacters = ''; ControlCharacter = $false }

    if ([string]::IsNullOrWhiteSpace($Answer)) {
        $result.Label = $Default
        return $result
    }

    $label = $Answer.Trim()
    if ($label.Length -gt $MaxLength) {
        $result.Rejection = 'TooLong'
        return $result
    }

    # A proxy: Windows documents no character list for a volume label, so the file name list stands
    # in for one. It can be too permissive, which the read-back after formatting is there to catch.
    $bad = @($label.ToCharArray() | Where-Object { [System.IO.Path]::GetInvalidFileNameChars() -contains $_ })
    if ($bad.Count -gt 0) {
        $result.Rejection = 'BadCharacter'
        # Control characters are counted rather than shown: there is nothing to print for one.
        $result.RejectedCharacters = (@($bad | Where-Object { [int]$_ -ge 32 } | Select-Object -Unique) -join ' ')
        $result.ControlCharacter = [bool]@($bad | Where-Object { [int]$_ -lt 32 }).Count
        return $result
    }

    $result.Label = $label
    return $result
}

function Request-DevDriveLabel {
    <# The name the volume will carry. Enter keeps the one offered, as every other prompt here does. #>
    param(
        [Parameter(Mandatory)][string]$Default,
        [int]$MaxLength = $script:DevDriveLabelMaxLength
    )

    Write-Host "`nThe Dev Drive carries a name, which is what File Explorer shows beside its letter." -ForegroundColor Cyan

    while ($true) {
        $answer = Read-Host "Enter a name for the Dev Drive, or press Enter for $Default"
        $verdict = Resolve-DevDriveLabelInput -Answer $answer -Default $Default -MaxLength $MaxLength

        if ($verdict.Rejection -eq 'TooLong') {
            Write-Host "That name is too long. Enter at most $MaxLength characters." -ForegroundColor Red
            continue
        }
        if ($verdict.Rejection -eq 'BadCharacter') {
            # Both halves are named at once, or removing the visible ones only earns a second refusal.
            $parts = @()
            if ($verdict.RejectedCharacters) { $parts += "these characters: $($verdict.RejectedCharacters)" }
            if ($verdict.ControlCharacter) { $parts += "a control character" }
            Write-Host "That name cannot be used, because it contains $($parts -join ', and ')." -ForegroundColor Red
            continue
        }

        return $verdict.Label
    }
}

function Get-VolumeProperty {
    <# One property of a volume; a volume that cannot be read answers $null rather than throwing. #>
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][string]$Name
    )

    try {
        # @() and the count check together: reading a property off nothing throws under strict mode.
        $volume = @(Get-Volume -DriveLetter $DriveLetter -ErrorAction Stop)
        if ($volume.Count -ne 1) { return $null }
        return $volume[0].$Name
    }
    catch {
        return $null
    }
}

function Get-VolumeLabel {
    <# The name a volume answers with; one that cannot be read answers $null, not an empty name. #>
    param([Parameter(Mandatory)][string]$DriveLetter)

    return Get-VolumeProperty -DriveLetter $DriveLetter -Name 'FileSystemLabel'
}

function Resolve-DevDriveLabelReport {
    <# What to say about the name the volume came back with, read off it rather than assumed. A
       volume that could not be read is reported as unread, never as one with no name. #>
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][string]$Requested,
        [object]$Actual
    )

    $mountPoint = "$DriveLetter`:"

    if ($Actual -is [string] -and $Actual -ceq $Requested) {
        return [PSCustomObject]@{
            Matches = $true
            Lines   = @("Dev Drive created at $mountPoint, named $Requested.")
        }
    }

    if ($null -eq $Actual) {
        return [PSCustomObject]@{
            Matches = $false
            Lines   = @(
                "Dev Drive created at $mountPoint, but its name could not be read back, so it is not confirmed as $Requested."
                "Check it with: Get-Volume -DriveLetter $DriveLetter"
            )
        }
    }

    $said = if ([string]::IsNullOrWhiteSpace($Actual)) { "reports no name at all" } else { "reports itself as $Actual" }
    # Doubled, as PowerShell requires: a name may legally carry an apostrophe, and this line is
    # printed to be copied and run.
    $quoted = $Requested.Replace("'", "''")
    return [PSCustomObject]@{
        Matches = $false
        Lines   = @(
            "Dev Drive created at $mountPoint, but it $said rather than $Requested."
            "Set the name with: Set-Volume -DriveLetter $DriveLetter -NewFileSystemLabel '$quoted'"
        )
    }
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

function Resolve-UnmetPasswordRequirement {
    <# Answers the requirements this password does not meet, in the order the prompt lists them, and
       nothing when it meets them all. Every rule mirrors one BitLocker refuses by its own error
       code, so nothing obviously refusable is handed over; its policy may still ask for more. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Plain,
        [Parameter(Mandatory)][int]$MinimumLength,
        [Parameter(Mandatory)][int]$MaximumLength
    )

    # Every class is spelled out in ASCII rather than left to \d or a negated class, because both of
    # those match beyond ASCII and BitLocker refuses anything outside printable ASCII (0x803100A4).
    $unmet = @()
    if ($Plain.Length -lt $MinimumLength)          { $unmet += "at least $MinimumLength characters" }
    if ($Plain.Length -gt $MaximumLength)          { $unmet += "at most $MaximumLength characters" }
    if ($Plain -cnotmatch '\A[\x20-\x7E]*\z')      { $unmet += "printable ASCII characters only" }
    # -cnotmatch, because the case-insensitive form lets [A-Z] match a lowercase letter and vice versa.
    if ($Plain -cnotmatch '[A-Z]')                 { $unmet += "at least one uppercase letter" }
    if ($Plain -cnotmatch '[a-z]')                 { $unmet += "at least one lowercase letter" }
    if ($Plain -cnotmatch '[0-9]')                 { $unmet += "at least one digit" }
    # Printable ASCII less space and alphanumerics, which is what is left to be a special character.
    if ($Plain -cnotmatch '[\x21-\x2F\x3A-\x40\x5B-\x60\x7B-\x7E]') { $unmet += "at least one special character" }
    return $unmet
}

function Request-StrongPassword {
    <# Prompts until the password meets every requirement, then answers it as a SecureString. The
       pointer is freed in a finally: a throw in between would leave the plaintext in unmanaged
       memory for the life of the process. #>
    param(
        [Parameter(Mandatory)][int]$MinimumLength,
        [Parameter(Mandatory)][int]$MaximumLength
    )

    while ($true) {
        $secure = Read-Host "Enter password ($MinimumLength-$MaximumLength printable ASCII chars, incl. upper, lower, digit, special)" -AsSecureString
        # Outside the try: inside it, a throw from this call would hand the finally a stale pointer.
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            # PtrToStringBSTR takes the length from the BSTR prefix; the Auto form stops at a null.
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            # @(): an empty array arrives from a function as $null, and .Count on it throws here.
            $unmet = @(Resolve-UnmetPasswordRequirement -Plain $plain `
                    -MinimumLength $MinimumLength -MaximumLength $MaximumLength)
        }
        finally {
            # Erases the unmanaged copy. $plain is a .NET string, so it can only be released.
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            $plain = $null
        }

        if ($unmet.Count -eq 0) {
            return $secure
        }

        # The refused attempt is encrypted rather than plaintext, but nothing needs it after this.
        $secure.Dispose()
        Write-Host "Password does not meet the following requirement(s):" -ForegroundColor Red
        foreach ($requirement in $unmet) {
            Write-Host " - $requirement" -ForegroundColor Yellow
        }
    }
}

function Get-DiskPartitionStyleName {
    <# The partition style Windows reports for a disk, or an empty string when it reports none. #>
    param([Parameter(Mandatory)]$Disk)

    $style = $Disk.PSObject.Properties['PartitionStyle']
    if ($null -eq $style -or $null -eq $style.Value) { return '' }
    return "$($style.Value)"
}

function Test-DiskStyleSupported {
    <# Whether this script will create a partition on a disk with this style. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Style,
        [Parameter(Mandatory)][string[]]$Supported
    )

    return $Style -in $Supported
}

function Format-DiskStyleNote {
    <# The one line the disk list shows instead of a free-space figure, for a style this script will
       not use. It reports what Windows said and claims nothing further. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Style)

    if ([string]::IsNullOrWhiteSpace($Style)) { return 'Cannot be used: no partition style reported' }
    return "Cannot be used: partition style $Style"
}

function Resolve-UnusableDiskAdvice {
    <#
        What to say when the disk that was chosen has a style this script will not use. One message
        for every such style: what Windows reported, what is supported, and the remedy offered as a
        condition rather than as an instruction, because RAW may be a damaged table.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Style,
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][ValidateSet('GPT', 'MBR')][string]$InitializeStyle,
        [Parameter(Mandatory)][string[]]$Supported
    )

    $reported = if ([string]::IsNullOrWhiteSpace($Style)) {
        "Disk $DiskNumber did not report a partition style."
    } else {
        "Disk $DiskNumber reports its partition style as $Style."
    }

    return @(
        $reported
        "This script works with $($Supported -join ' and ') disks only, and never initializes a physical disk."
        ""
        "If you know this disk is new, you can initialize it yourself. Leave this prompt open, and in"
        "another PowerShell window run:"
        ""
        "    Initialize-Disk -Number $DiskNumber -PartitionStyle $InitializeStyle"
        ""
        "WARNING: that writes a new partition table over whatever is already there, which makes every"
        "file on the disk unreachable. Windows also reports RAW for a table it merely failed to read,"
        "so a disk that looks empty here may not be. Only run it on a disk you know is new, or whose"
        "contents you no longer need."
        ""
        "Choose a different disk, type this number again once Windows reports it as $($Supported -join ' or '),"
        "or press Ctrl+C to leave without creating anything."
    )
}

function Show-DriveSelection {
    param([Parameter(Mandatory)][string[]]$SupportedStyles)

    Write-Host "`nSelect the physical drive where you want to create your Dev Drive:`n" -ForegroundColor Cyan

    $disks = Get-Disk | Where-Object { $_.BusType -ne 'Unknown' } | Sort-Object Number

    foreach ($disk in $disks) {
        $diskNumber = $disk.Number
        $diskSizeGB = ConvertTo-FlooredGB -Bytes $disk.Size
        $style = Get-DiskPartitionStyleName -Disk $disk

        Write-Host "Disk $diskNumber`: $($disk.FriendlyName)" -ForegroundColor Yellow
        Write-Host "  Size: $diskSizeGB GB" -ForegroundColor White
        if (Test-DiskStyleSupported -Style $style -Supported $SupportedStyles) {
            # "Unallocated", not "Free": a full disk reads 0 here and must not look broken.
            $freeSpaceGB = ConvertTo-FlooredGB -Bytes (Get-DiskLargestFreeExtent -Disk $disk)
            Write-Host "  Unallocated: $freeSpaceGB GB in one unbroken block" -ForegroundColor Green
        } else {
            # A free-space figure would invite a choice this script is about to refuse.
            Write-Host "  $(Format-DiskStyleNote -Style $style)" -ForegroundColor Yellow
        }

        # By number rather than down the pipeline: the same query, and the only shape a test can pass.
        # Errors silenced: a disk with no partitions raises a record that would land mid-list.
        $driveLetters = (Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue |
                Where-Object { $_.DriveLetter } |
                Select-Object -ExpandProperty DriveLetter) -join ", "
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

function Resolve-VhdxPortabilityAdvice {
    <# What carrying the file to another machine costs: the trusted status is per machine. #>
    param([Parameter(Mandatory)][string]$VhdxPath)

    return @(
        "Microsoft does not recommend copying $VhdxPath to another machine and carrying on using it as a Dev Drive."
        "The trusted status is stored on the machine that formatted the volume and does not travel with the file:"
        "copied elsewhere it mounts as an ordinary volume, every filter attaches, and Defender scans it synchronously."
        "If you do it anyway, mark it trusted there after mounting it: fsutil devdrv trust /f <drive letter>:"
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

function Get-VolumeWriteState {
    <#
        Writes one file and removes it. A volume mounted read-only by policy looks ordinary to
        Get-Volume, so an actual write is the only answer that can be trusted.
    #>
    param([Parameter(Mandatory)][string]$MountPoint)

    $probe = Join-Path $MountPoint ".devdrive-write-test"
    try {
        [System.IO.File]::WriteAllText($probe, 'probe')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return [PSCustomObject]@{ Writable = $true; Reason = '' }
    }
    catch {
        # A .NET call wraps its own error, so only the base exception carries what Windows said.
        return [PSCustomObject]@{ Writable = $false; Reason = $_.Exception.GetBaseException().Message }
    }
}

function Resolve-WriteProtectionAdvice {
    <#
        Why a freshly created Dev Drive refuses writes. An unencrypted volume names the policy that
        mounts such drives read-only; anything else says the cause is unknown rather than guessing.
    #>
    param(
        [Parameter(Mandatory)][string]$MountPoint,
        [ValidateSet('Encrypted', 'Clear', 'Unknown')][string]$VolumeState = 'Unknown',
        [AllowNull()][AllowEmptyString()][string]$Reason,
        [ValidateSet('Deny', 'Allow', 'Unknown')][string]$WritePolicy = 'Unknown',
        [string]$PolicyPath = $script:FixedDriveWritePolicyPath
    )

    # Offered in every branch: a partition carrying the read-only flag refuses writes whatever
    # BitLocker is doing.
    $partitionCheck = "Check whether the partition itself is marked read-only: Get-Partition -DriveLetter $($MountPoint.TrimEnd(':')) | Format-List IsReadOnly, DiskNumber"

    $lines = @("Drive $MountPoint was created, but nothing can be written to it.")
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $lines += "Windows said: $Reason"
    }

    if ($VolumeState -eq 'Clear') {
        # The setting was read before the plan, so this names a likely cause instead of listing suspects.
        if ($WritePolicy -eq 'Deny') {
            $lines += "This machine denies write access to fixed drives that BitLocker does not protect, and $MountPoint is not encrypted. That is almost certainly the cause."
            $lines += "Encrypt this volume to make it writable, without creating it again: Enable-BitLocker -MountPoint $MountPoint -RecoveryPasswordProtector -UsedSpaceOnly"
        } elseif ($WritePolicy -eq 'Allow') {
            $lines += "The drive is not encrypted, but this machine does not report that setting as on, so it does not look like the cause."
        } else {
            $lines += "The drive is not encrypted, and this machine may be set to deny write access to fixed drives that BitLocker does not protect."
            $lines += "If that setting is on, Windows mounts every unencrypted fixed data drive read-only, and encrypting $MountPoint would make it writable."
            $lines += "Read it with: Get-ItemProperty '$PolicyPath' -Name FDVDenyWriteAccess -ErrorAction SilentlyContinue"
        }
        $lines += $partitionCheck
    } elseif ($VolumeState -eq 'Encrypted') {
        $lines += "The drive is encrypted, so the setting that mounts unencrypted drives read-only does not explain this."
        $lines += $partitionCheck
        $lines += "A locked volume refuses writes too: manage-bde -status $MountPoint"
    } else {
        $lines += "The encryption state of the drive could not be read, so the cause cannot be narrowed down here."
        $lines += "Start with: manage-bde -status $MountPoint"
        $lines += $partitionCheck
    }

    $lines += "Drive $MountPoint stays as it is. Nothing more can be set up on it while it refuses writes."
    return $lines
}

foreach ($line in (Resolve-AutomationBanner)) {
    Write-Host $line -ForegroundColor Yellow
}

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

# The style this script initializes its own virtual disk with, and the one it tells a user to give
# a physical disk. Kept together so the advice cannot drift from the behaviour.
$DiskPartitionStyle = 'GPT'

# The styles a physical disk may have for this script to create a partition on it. Rendered into
# the refusal as well, so the sentence cannot come to disagree with the check.
$SupportedPartitionStyles = @('GPT', 'MBR')

# Where "deny write access to fixed drives not protected by BitLocker" takes effect. PolicyManager
# was empty on the machine that reported this, so the effective path is the one to read.
$FixedDriveWritePolicyPath = 'HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FVE'

# The name offered on the Enter key.
$DevDriveDefaultLabel = "DevDrive"

# This script's own cap, at the long-standing NTFS label length: Microsoft documents none for
# Format-Volume -NewFileSystemLabel, so there is nothing to cite and nothing to read off a volume.
$DevDriveLabelMaxLength = 32

# This script's own floor for the BitLocker password; Windows applies its own policy afterwards.
$PasswordMinLength = 8

# BitLocker's own ceiling, from the refusal it answers past it: 0x803100AA, "over 256 characters".
$PasswordMaxLength = 256

# Head-room kept on the volume hosting a fixed size .vhdx, so it is never filled to the last byte.
$VhdxHostSpareBytes = 1GB

# Head-room left on a shrunk volume, so an estimate never offers to take its last free byte.
$ShrinkSpareBytes = 5GB

# Set default values for deduplication and compression settings
$DedupMode = 'Dedup'
$CompressionFormat = 'LZ4'
# Unset until a format that has levels is chosen: a number here would be printed as a setting nobody made.
$CompressionLevel = $null
$RunInitialJob = $true
$SkipBitLocker = $false
$SkipDeduplication = $false

# ReFS dedup schedule defaults, changeable by the user below. Read by both the plan summary and the
# actual calls, so the two cannot say different things about when the jobs run.
# One daily time, because a volume holds one: Set-ReFSDedupSchedule replaces the schedule it is given.
$DedupStartTime = "17:00"
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
Write-Host "No changes will be made until you confirm the plan." -ForegroundColor White
Write-Host "Press Ctrl+C at any of these questions to leave without changing anything.`n" -ForegroundColor White

# Step 1: Ask user to select the creation mode
$mode = Select-DriveMode

# Step 2: Ask user to select a physical drive. A .vhdx lives on an existing volume instead.
if ($mode -ne "Vhdx") {
    Show-DriveSelection -SupportedStyles $SupportedPartitionStyles

    Write-Host "`n=== SELECT PHYSICAL DRIVE ===" -ForegroundColor Cyan
    Write-Host "Enter the disk number you want to use for Dev Drive creation:" -ForegroundColor White
    # Said here as well as in the banner: every disk on the machine may be one this script refuses,
    # and this is the prompt a refusal comes back to.
    Write-Host "Press Ctrl+C to leave without creating anything." -ForegroundColor Gray

    while ($true) {
        $selectedDiskInput = (Read-Host "Disk number").Trim()
        if ($selectedDiskInput -match '^\d+$') {
            $selectedDiskNumber = [int]$selectedDiskInput
            # Validate that the disk exists
            $diskExists = Get-Disk -Number $selectedDiskNumber -ErrorAction SilentlyContinue
            if ($diskExists) {
                # Judged before the disk is accepted, so nothing is asked about a disk that cannot
                # hold a Dev Drive.
                $selectedStyle = Get-DiskPartitionStyleName -Disk $diskExists
                if (-not (Test-DiskStyleSupported -Style $selectedStyle -Supported $SupportedPartitionStyles)) {
                    Write-Host ""
                    foreach ($line in (Resolve-UnusableDiskAdvice -Style $selectedStyle -DiskNumber $selectedDiskNumber `
                                -InitializeStyle $DiskPartitionStyle -Supported $SupportedPartitionStyles)) {
                        Write-Host $line -ForegroundColor Red
                    }
                    Write-Host ""
                    # Back to the prompt: the disk is read again, so one initialized in another
                    # window can be chosen without starting over.
                    continue
                }

                $DiskNumber = $selectedDiskNumber
                $selectedDiskName = $diskExists.FriendlyName
                Write-Host "Selected Disk $DiskNumber`: $selectedDiskName" -ForegroundColor Green
                break
            } else {
                Write-Host "Disk $selectedDiskNumber does not exist. Please select a valid disk number." -ForegroundColor Red
            }
        } else {
            Write-Host "Invalid input. Please enter a number (0, 1, 2, etc.), or press Ctrl+C to leave." -ForegroundColor Red
        }
    }
}

# Step 3: Get mode-specific parameters
if ($mode -eq "FreeSpace") {
    # Get disk info for free space calculation
    $selectedDisk = Get-Disk -Number $DiskNumber
    $freeSpace = Get-DiskLargestFreeExtent -Disk $selectedDisk
    # Floor (not round) so the displayed/accepted maximum is never above the real free space
    $freeSpaceGB = ConvertTo-FlooredGB -Bytes $freeSpace

    # "Unbroken block", not "free space": a Dev Drive needs one, and a disk with two smaller gaps
    # has more free space than this number, none of which can be used for it.
    Write-Host "`nDisk $DiskNumber has $freeSpaceGB GB in its largest unbroken block of free space." -ForegroundColor Cyan

    if ($freeSpace -lt ($DevDriveMinSizeGB * 1GB)) {
        Write-Host "Disk $DiskNumber has $freeSpaceGB GB in its largest unbroken block, which is below the $DevDriveMinSizeGB GB minimum required for a Dev Drive." -ForegroundColor Red
        Write-Host "A Dev Drive has to fit in one block, so free space scattered between partitions does not count." -ForegroundColor Yellow
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

    # After the refusal above, never before it: naming space that joins a drive the next line
    # refuses would promise something and take it back.
    $ShrinkAdjoiningGB = $null
    if ($partitionInfo) {
        $ShrinkAdjoiningGB = ConvertTo-FlooredGB -Bytes ($supportedSizes.SizeMax - $partitionInfo.Size)
        foreach ($line in (Format-ShrinkAdjoiningNote -DriveLetter $DriveLetter -AdjoiningGB $ShrinkAdjoiningGB)) {
            Write-Host $line -ForegroundColor Cyan
        }
    }

    $ShrinkGB = Request-DevDriveSizeGB -MaxGB $realMaxShrinkableGB -Subject 'Shrink amount'

    # The drive takes the whole free run behind the partition: the amount freed plus what adjoins it.
    $SizeGB = $ShrinkGB
    if ($partitionInfo) {
        $shrinkPlan = Resolve-ShrinkPlan -CurrentSize $partitionInfo.Size -MaxSize $supportedSizes.SizeMax `
            -MinSize $supportedSizes.SizeMin -ShrinkBytes (ConvertTo-ByteCount -GB $ShrinkGB)
        if ($shrinkPlan.Rejection) {
            foreach ($line in (Format-ShrinkRefusal -DriveLetter $DriveLetter -ShrinkGB $ShrinkGB -Rejection $shrinkPlan.Rejection `
                        -MinSizeGB (ConvertTo-CeilingedGB -Bytes $supportedSizes.SizeMin) `
                        -CurrentSizeGB (ConvertTo-FlooredGB -Bytes $partitionInfo.Size))) {
                Write-Host $line -ForegroundColor Red
            }
            Write-Host "Exiting. Nothing has been changed." -ForegroundColor Yellow
            exit 1
        }
        $SizeGB = ConvertTo-FlooredGB -Bytes $shrinkPlan.DevDriveBytes
    }
} else { # Vhdx
    # Compile the interop now rather than after every question, so a machine that forbids Add-Type
    # fails before the user has answered anything.
    Initialize-VirtDiskInterop

    $VhdxPath = Request-VhdxPath
    $VhdxDiskType = Request-VhdxDiskType
    $SizeGB = Request-VhdxSize -VhdxPath $VhdxPath -DiskType $VhdxDiskType
    $VhdxAutoAttach = Request-AutoAttachChoice
}

# Asked here rather than in each mode: the name is the same question whatever created the volume.
$DevDriveLabel = Request-DevDriveLabel -Default $DevDriveDefaultLabel -MaxLength $DevDriveLabelMaxLength

# Read before the question, not after: on a machine with this setting the answer is not a preference.
$WritePolicy = Get-FixedDriveWritePolicy

# Ask about BitLocker encryption
$enableBitLocker = Request-BitLockerChoice -VhdxMode:($mode -eq "Vhdx") `
    -Notes (Resolve-WriteAccessPolicyAdvice -Policy $WritePolicy)
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
        -VhdxMode:($mode -eq "Vhdx") -OsDriveProtected:$osDriveProtected -WritePolicy $WritePolicy
}

# Ask about deduplication
$dedupChoice = Request-DeduplicationChoice
if ($dedupChoice -eq "None") {
    $SkipDeduplication = $true
} else {
    $DedupMode = $dedupChoice
    # Set from the answer, never from the default above it: a mode nobody chose describes nothing.
    $DedupCapability = Resolve-DedupModeCapability -Mode $DedupMode
    if ($DedupCapability.UsesCompression) {
        $compression = Request-Compression
        $CompressionFormat = $compression.Format
        $CompressionLevel = $compression.Level
    }
    Write-Host "Selected $(Format-DedupModeChoice -Mode $DedupMode -Format $CompressionFormat -Level $CompressionLevel)" -ForegroundColor Green
}

# Ask when the deduplication jobs should run
if (-not $SkipDeduplication) {
    $dedupSchedule = Request-DedupSchedule -DailyTime $DedupStartTime -DailyDaysLabel $DedupDailyDaysLabel `
        -WeeklyDay $ScrubDays -WeeklyStart $ScrubStart -WeeksInterval $ScrubWeeksInterval `
        -DailyDurationHours $DedupDailyDurationHours -DailyCpuPercent $DedupDailyCpuPercent `
        -BlockDedup:$DedupCapability.UsesBlockDedup
    $DedupStartTime = $dedupSchedule.DailyTime
    $ScrubDays = $dedupSchedule.WeeklyDay
    $ScrubStart = $dedupSchedule.WeeklyStart
}

# Gathered, not decided: a key exists only where its branch asked the question.
$planAnswers = @{
    Mode                = $mode
    SizeGB              = $SizeGB
    DevDriveLabel       = $DevDriveLabel
    SkipBitLocker       = $SkipBitLocker
    WritePolicy         = $WritePolicy
    SkipDeduplication   = $SkipDeduplication
}
if (-not $SkipBitLocker) { $planAnswers.BitLockerNotes = $bitLockerPlan.Notes }
if (-not $SkipDeduplication) {
    $planAnswers.DedupMode = $DedupMode
    $planAnswers.CompressionFormat = $CompressionFormat
    $planAnswers.CompressionLevel = $CompressionLevel
    $planAnswers.DedupStartTime = $DedupStartTime
    $planAnswers.DedupDailyDaysLabel = $DedupDailyDaysLabel
    $planAnswers.ScrubDays = $ScrubDays
    $planAnswers.ScrubStart = $ScrubStart
    $planAnswers.ScrubWeeksInterval = $ScrubWeeksInterval
    $planAnswers.DedupWeeklyJob = $DedupCapability.UsesBlockDedup
}
if ($mode -eq "Vhdx") {
    $planAnswers.VhdxPath = $VhdxPath
    $planAnswers.VhdxDiskType = $VhdxDiskType
    $planAnswers.VhdxAutoAttach = $VhdxAutoAttach
    $planAnswers.PartitionStyle = $DiskPartitionStyle
} else {
    $planAnswers.DiskNumber = $DiskNumber
    $planAnswers.DiskName = $selectedDiskName
}
if ($mode -eq "ShrinkDrive") {
    $planAnswers.DriveLetter = $DriveLetter
    $planAnswers.DriveLabel = $driveLabel
    $planAnswers.ShrinkGB = $ShrinkGB
    $planAnswers.ShrinkAdjoiningGB = $ShrinkAdjoiningGB
}

Write-Host "`n"
foreach ($planLine in (Format-CreationPlan -Answers $planAnswers)) {
    Write-Host $planLine.Text -ForegroundColor $planLine.Colour
}

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

        $freeSpace = Get-DiskLargestFreeExtent -Disk $disk
        $freeSpaceGB = ConvertTo-FlooredGB -Bytes $freeSpace

        Write-Host "Disk $DiskNumber total size: $(ConvertTo-FlooredGB -Bytes $disk.Size) GB" -ForegroundColor Green
        Write-Host "Disk $DiskNumber largest unbroken block of free space: $freeSpaceGB GB" -ForegroundColor Green

        # Check if requested size is available
        $requestedSizeBytes = ConvertTo-ByteCount -GB $SizeGB
        if ($freeSpace -lt $requestedSizeBytes) {
            throw "Insufficient free space on disk $DiskNumber. Requested: $SizeGB GB, largest unbroken block available: $freeSpaceGB GB"
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

        $shrinkPlan = Resolve-ShrinkPlan -CurrentSize $partitionInfo.Size -MaxSize $maxSize `
            -MinSize $minSize -ShrinkBytes (ConvertTo-ByteCount -GB $ShrinkGB)
        if ($shrinkPlan.Rejection) {
            foreach ($line in (Format-ShrinkRefusal -DriveLetter $DriveLetter -ShrinkGB $ShrinkGB -Rejection $shrinkPlan.Rejection `
                        -MinSizeGB (ConvertTo-CeilingedGB -Bytes $minSize) `
                        -CurrentSizeGB (ConvertTo-FlooredGB -Bytes $partitionInfo.Size))) {
                Write-Host $line -ForegroundColor Red
            }
            Write-Host "Exiting. Nothing has been changed." -ForegroundColor Yellow
            exit 1
        }

        Write-Host "Resizing Partition $($partitionInfo.PartitionNumber) of disk $diskNum to $(ConvertTo-FlooredGB -Bytes $shrinkPlan.TargetBytes) GB ..." -ForegroundColor Green
        Resize-Partition -DiskNumber $diskNum -PartitionNumber $partitionInfo.PartitionNumber -Size $shrinkPlan.TargetBytes -ErrorAction Stop
        $ShrunkDriveLetter = $DriveLetter

        # Read back rather than assume: alignment can leave the partition a little off the target.
        $shrunkPart = Get-Partition -DiskNumber $diskNum -PartitionNumber $partitionInfo.PartitionNumber -ErrorAction Stop
        Write-Host "Shrunk drive $DriveLetter to $(ConvertTo-FlooredGB -Bytes $shrunkPart.Size) GB" -ForegroundColor Green

        # The shrink already happened, so this subtraction decides what gets written next; a negative
        # difference would reach New-Partition as a binding error rather than as an explanation.
        if ($shrunkPart.Size -gt $maxSize) {
            throw "Drive $DriveLetter reports $(ConvertTo-FlooredGB -Bytes $shrunkPart.Size) GB after the resize, more than the $(ConvertTo-FlooredGB -Bytes $maxSize) GB Windows said it could hold. Nothing further was created."
        }

        # Placed explicitly: -UseMaximumSize takes the largest free run on the disk, which can be elsewhere.
        # Measured: an offset that is not a whole number of megabytes is refused outright, and a
        # resize lands a few hundred bytes off its target, so the start has to be nudged forward.
        $placement = Resolve-AlignedPlacement -Offset ($shrunkPart.Offset + $shrunkPart.Size) `
            -Size ($maxSize - $shrunkPart.Size)
        if ($placement.Rejection) {
            throw "Nothing usable was left behind ${DriveLetter}: after aligning the start of the new partition. The drive was shrunk; nothing was created."
        }
        $freedOffset = $placement.Offset
        $freedSize = $placement.Size

        # Judged, not merely reported: every other entry point refuses a drive below this floor.
        if ($freedSize -lt ($DevDriveMinSizeGB * 1GB)) {
            throw "The space behind ${DriveLetter}: came to $(ConvertTo-FlooredGB -Bytes $freedSize) GB, below the $DevDriveMinSizeGB GB a Dev Drive needs. The drive was shrunk; nothing was created."
        }
        if ((ConvertTo-FlooredGB -Bytes $freedSize) -ne (ConvertTo-FlooredGB -Bytes $shrinkPlan.DevDriveBytes)) {
            Write-Host "The space behind ${DriveLetter}: came to $(ConvertTo-FlooredGB -Bytes $freedSize) GB, not the $(ConvertTo-FlooredGB -Bytes $shrinkPlan.DevDriveBytes) GB the plan named." -ForegroundColor Yellow
        }
        Write-Host "Creating a $(ConvertTo-FlooredGB -Bytes $freedSize) GB partition in the space behind ${DriveLetter}: on disk $diskNum" -ForegroundColor Green
        $newPart = New-Partition -DiskNumber $diskNum -Offset $freedOffset -Size $freedSize -AssignDriveLetter -ErrorAction Stop
    } else { # Vhdx
        Write-Host "Creating a $SizeGB GB $VhdxDiskType virtual hard disk at $VhdxPath" -ForegroundColor Green
        if ($VhdxDiskType -eq 'Fixed') {
            Write-Host "Allocating the whole file up front. This may take several minutes and cannot be interrupted." -ForegroundColor Yellow
        }
        New-VirtualDiskFile -Path $VhdxPath -SizeBytes (ConvertTo-ByteCount -GB $SizeGB) -DiskType $VhdxDiskType

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

        Write-Host "Initializing disk $vhdxDiskNumber with a $DiskPartitionStyle partition table" -ForegroundColor Green
        Initialize-Disk -Number $vhdxDiskNumber -PartitionStyle $DiskPartitionStyle -ErrorAction Stop | Out-Null

        Write-Host "Creating a partition spanning the whole virtual disk" -ForegroundColor Green
        $newPart = New-Partition -DiskNumber $vhdxDiskNumber -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
    }

    $devLetter = $newPart.DriveLetter
    $devLetterColon = "$devLetter`:"
    Write-Host "Formatting the newly created partition drive $devLetterColon to a Dev Drive" -ForegroundColor Green
    Format-Volume -DriveLetter $devLetter -FileSystem ReFS -DevDrive -NewFileSystemLabel $DevDriveLabel -Confirm:$false -Force -ErrorAction Stop
    # The name is asked of the volume: a label the file system altered would otherwise go unseen.
    $actualLabel = Get-VolumeLabel -DriveLetter $devLetter
    $labelReport = Resolve-DevDriveLabelReport -DriveLetter $devLetter -Requested $DevDriveLabel -Actual $actualLabel
    $labelColour = if ($labelReport.Matches) { 'Green' } else { 'Yellow' }
    foreach ($line in $labelReport.Lines) {
        Write-Host $line -ForegroundColor $labelColour
    }

    Write-Host "Marking Dev Drive $devLetterColon as trusted for Defender performance" -ForegroundColor Green
    # /f: the designation lands through a dismount, which fsutil skips on a volume in use.
    fsutil devdrv trust /f "$devLetterColon" | Out-Null
    # fsutil does not throw, so take its exit code before the query overwrites $LASTEXITCODE.
    $trustExitCode = $LASTEXITCODE
    # Cast each record to a string first: on Windows PowerShell a redirected stderr line is an
    # ErrorRecord, and Out-String would render it as a whole error display instead of its text.
    $trustQuery = (fsutil devdrv query "$devLetterColon" 2>&1 | ForEach-Object { "$_" } | Out-String)
    $trustReport = Resolve-DevDriveTrustReport -MountPoint $devLetterColon -TrustExitCode $trustExitCode -QueryOutput $trustQuery
    # Grey, not yellow, for an answer that could not be read: on a localized Windows that is every run.
    $trustColour = switch ($trustReport.Outcome) { 'Trusted' { 'Green' } 'Unconfirmed' { 'Gray' } default { 'Yellow' } }
    foreach ($line in $trustReport.Lines) {
        Write-Host $line -ForegroundColor $trustColour
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
                    $SecurePassword = Request-StrongPassword -MinimumLength $PasswordMinLength `
                        -MaximumLength $PasswordMaxLength
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

                # Its own try: the shared catch would read a failed auto-unlock as the whole setup collapsing.
                $autoUnlockMessage = ''
                if (-not $bitLockerPlan.UseAutoUnlock) {
                    $autoUnlockOutcome = 'NotOffered'
                } elseif ($unlockPlan.DeferAutoUnlock) {
                    $autoUnlockOutcome = 'Deferred'
                } else {
                    Write-Host "Enabling BitLockerAutoUnlock" -ForegroundColor Green
                    try {
                        Enable-BitLockerAutoUnlock -MountPoint $devLetterColon -ErrorAction Stop
                        # Asked of the volume, not taken from a cmdlet that returned without complaining.
                        $autoUnlockOutcome = if ((Get-BitLockerAutoUnlockState -MountPoint $devLetterColon) -eq 'Enabled') { 'Enabled' } else { 'Unconfirmed' }
                    }
                    catch {
                        $autoUnlockOutcome = 'Failed'
                        $autoUnlockMessage = $_.Exception.Message
                    }
                }

                $finalState = Get-BitLockerProtectionState -MountPoint $devLetterColon
                if ($finalState.Covered) {
                    Write-Host "BitLocker has been enabled for $devLetterColon and its recovery key is written down." -ForegroundColor Green
                } else {
                    Write-Host "BitLocker setup finished, but $devLetterColon does not report itself as protected or encrypting." -ForegroundColor Yellow
                    Write-Host "Check it with: Get-BitLockerVolume -MountPoint $devLetterColon" -ForegroundColor Yellow
                }

                # Said last, because a drive that needs unlocking by hand is what a person has to remember.
                $autoUnlockColour = if ($autoUnlockOutcome -eq 'Enabled') { 'Green' } else { 'Yellow' }
                foreach ($line in (Resolve-BitLockerAutoUnlockReport -MountPoint $devLetterColon -Outcome $autoUnlockOutcome -Message $autoUnlockMessage)) {
                    Write-Host $line -ForegroundColor $autoUnlockColour
                }
                $bitLockerSuccess = $true
            }
            catch {
                $failure = $_
                $retryCount++
                $failureState = (Get-BitLockerProtectionState -MountPoint $devLetterColon).Label
                $passwordAsked = $bitLockerPlan.UsePasswordProtector
                $verdict = Resolve-BitLockerFailure -Message $failure.Exception.Message -RetryCount $retryCount `
                    -MaxRetries $maxRetries -VolumeState $failureState -HResult $failure.Exception.HResult `
                    -Unretryable:$unretryable -PasswordAsked:$passwordAsked
                foreach ($line in $verdict.Lines) {
                    Write-Host $line -ForegroundColor Red
                }

                if ($verdict.Kind -eq 'Password' -and $verdict.CanRetry) {
                    Write-Host ""
                } elseif ($verdict.Kind -eq 'Password' -and -not $verdict.CanRetry) {
                    throw "BitLocker did not accept the password after $retryCount attempts."
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


    # Before deduplication: on a read-only volume every cmdlet after this fails without naming the cause.
    Write-Host "Checking that $devLetterColon can be written to" -ForegroundColor Green
    $writeState = Get-VolumeWriteState -MountPoint $devLetterColon
    if ($writeState.Writable) {
        Write-Host "Drive $devLetterColon accepts writes." -ForegroundColor Green
    } else {
        $encryptionState = (Get-BitLockerProtectionState -MountPoint $devLetterColon).Label
        Write-Host ""
        foreach ($line in (Resolve-WriteProtectionAdvice -MountPoint $devLetterColon -VolumeState $encryptionState `
                    -Reason $writeState.Reason -WritePolicy $WritePolicy)) {
            Write-Host $line -ForegroundColor Red
        }
        # Thrown rather than exited: the closing advice about a shrunk drive and a left-behind .vhdx lives in the catch.
        throw "Drive $devLetterColon is read-only. See the explanation above."
    }

    # Enable Deduplication + Compression (conditional)
    if (-not $SkipDeduplication) {
        Write-Host "Enabling ReFS mode $DedupMode for $devLetterColon" -ForegroundColor Green
        Enable-ReFSDedup -Volume "$devLetterColon" -Type $DedupMode -ErrorAction Stop
        Write-Host "Enabled ReFS mode: $DedupMode" -ForegroundColor Green

        $scheduleParams = @{
            Volume            = "$devLetterColon"
            Days              = $DedupDailyDays
        }

        # A compression-only volume refuses the CPU share, and takes the duration only to drop it.
        if ($DedupCapability.UsesBlockDedup) {
            $scheduleParams.Duration = New-TimeSpan -Hours $DedupDailyDurationHours
            $scheduleParams.CpuPercentage = $DedupDailyCpuPercent
        }

        # Compression parameters only outside Dedup-only mode; an unchosen level is left out so Windows uses its own.
        if ($DedupCapability.UsesCompression) {
            $scheduleParams.CompressionFormat = $CompressionFormat
            if ($null -ne $CompressionLevel) {
                $scheduleParams.CompressionLevel = [uint16]$CompressionLevel
            }
        }

        $dailyLimit = if ($DedupCapability.UsesBlockDedup) { " (${DedupDailyDurationHours}h)" } else { "" }
        $scheduleParams.Start = $DedupStartTime

        # One call: the cmdlet replaces the volume's schedule, so a second would discard the first time.
        Write-Host "Scheduling the daily job at $DedupStartTime$dailyLimit" -ForegroundColor Green
        Set-ReFSDedupSchedule @scheduleParams -ErrorAction Stop

        # The settings are asked of the volume rather than assumed from the call that just returned.
        $dedupVerdict = Resolve-DedupReadBackVerdict -MountPoint $devLetterColon -ExpectedMode $DedupMode `
            -ExpectedFormat $CompressionFormat -ExpectedLevel $CompressionLevel -ExpectedStart $DedupStartTime `
            -Actual (Get-DedupVolumeReport -MountPoint $devLetterColon)
        $verdictColour = if ($dedupVerdict.Agrees) { 'Green' } else { 'Yellow' }
        foreach ($line in $dedupVerdict.Lines) {
            Write-Host $line -ForegroundColor $verdictColour
        }

        # Windows refuses a scrub schedule outright where nothing is deduplicated to be scrubbed.
        if ($DedupCapability.UsesBlockDedup) {
            Write-Host "Scheduling deduplication scrub jobs" -ForegroundColor Green
            Set-ReFSDedupScrubSchedule -Volume "$devLetterColon" -Days $ScrubDays -Start $ScrubStart -WeeksInterval $ScrubWeeksInterval -ErrorAction Stop
            Write-Host "Scheduled weekly scrub job on $ScrubDays at $ScrubStart" -ForegroundColor Green
        } else {
            Write-Host "No weekly scrub job: Windows has none for a volume that only compresses." -ForegroundColor Yellow
        }

        # Read once, and used both to pick the tasks and to name them to the user afterwards.
        $devTaskName = Resolve-DedupTaskName -UniqueId (Get-VolumeProperty -DriveLetter $devLetter -Name 'UniqueId')
        $ownTaskNames = @()

        # Runs after every job this pass scheduled, whichever of them there were, so it sees them all.
        Write-Host "Configuring the ReFS optimization tasks to run only on mains power..." -ForegroundColor Green
        try {
            if ([string]::IsNullOrWhiteSpace($devTaskName)) {
                # Changing tasks that cannot be shown to be this drive's is worse than changing none.
                throw "$devLetterColon did not give up the identifier its tasks are named after."
            }

            $dedupTasks = @(Resolve-OwnDedupTask -VolumeTaskName $devTaskName `
                    -Tasks @(Get-ScheduledTask -TaskPath $DedupTaskPath -ErrorAction Stop))
            $ownTaskNames = @($dedupTasks | ForEach-Object { $_.TaskName })

            $confirmedTasks = @()
            $taskFailures = @()
            foreach ($task in $dedupTasks) {
                try {
                    $task.Settings.DisallowStartIfOnBatteries = $true
                    $task.Settings.StopIfGoingOnBatteries = $true
                    # The claim below is made from what came back, not from the call having returned.
                    $saved = $task | Set-ScheduledTask -ErrorAction Stop
                    if ($saved.Settings.DisallowStartIfOnBatteries -and $saved.Settings.StopIfGoingOnBatteries) {
                        $confirmedTasks += $task.TaskName
                    }
                    else {
                        $taskFailures += "$($task.TaskName) still reports that it may start on battery."
                    }
                }
                catch {
                    # One task's failure must not stop the others, but it must not pass unseen either.
                    $taskFailures += "Could not set $($task.TaskName) to mains power only: $($_.Exception.Message)"
                }
            }

            foreach ($name in $confirmedTasks) {
                # "Is set to", not "runs on": a disabled task of this volume is configured and never runs.
                Write-Host "  $name is set to mains power only" -ForegroundColor Green
            }
            foreach ($failure in $taskFailures) {
                Write-Host $failure -ForegroundColor Yellow
            }
            if ($dedupTasks.Count -eq 0) {
                Write-Host "No task named after $devLetterColon was found, so none were changed. The optimization will run on any power source." -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "Could not set the ReFS optimization tasks to mains power only: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "Tasks will run on any power source." -ForegroundColor Yellow
        }

        Write-Host ""
        foreach ($line in (Resolve-DedupScheduleReminder -DailyTime $DedupStartTime `
                    -WeeklyDay $ScrubDays -WeeklyStart $ScrubStart -TaskTreePath $DedupTaskTreePath `
                    -TaskNames $ownTaskNames -VolumeTaskName $devTaskName `
                    -WeeklyJob:$DedupCapability.UsesBlockDedup)) {
            Write-Host $line -ForegroundColor Cyan
        }
        Write-Host ""

        if ($RunInitialJob) {
            $jobParams = @{
                Volume            = "$devLetterColon"
                Duration          = (New-TimeSpan -Hours 5)
            }

            # The same refusal as the schedule. Duration stays: this call takes it, the schedule drops it.
            if ($DedupCapability.UsesBlockDedup) {
                $jobParams.CpuPercentage = 60
            }

            # Add compression parameters only if not Dedup-only mode
            if ($DedupCapability.UsesCompression) {
                $jobParams.CompressionFormat = $CompressionFormat
                if ($null -ne $CompressionLevel) {
                    $jobParams.CompressionLevel = [uint16]$CompressionLevel
                }
            }

            Write-Host "Running the initial ReFS job for $devLetterColon" -ForegroundColor Green

            # -FullRun only where it has always been passed; the cmdlet has one parameter set, so it
            # is not excluded by the compression parameters, and this split is older than the repository.
            if (-not $DedupCapability.UsesCompression) {
                $jobParams.FullRun = $true
            }
            Start-ReFSDedupJob @jobParams -ErrorAction Stop | Out-Null
            Write-Host "Triggered the initial job: $(Format-DedupModeChoice -Mode $DedupMode -Format $CompressionFormat -Level $CompressionLevel)" -ForegroundColor Green
            Write-Host "You should wait for it to complete for the optimization to properly work" -ForegroundColor Yellow
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

    # Printed at the end only, and whatever automatic mounting did: it is about the file's future,
    # not about this run, and by here the volume really is a Dev Drive.
    if ($mode -eq "Vhdx") {
        Write-Host ""
        foreach ($line in (Resolve-VhdxPortabilityAdvice -VhdxPath $VhdxPath)) {
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
