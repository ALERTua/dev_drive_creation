#Requires -RunAsAdministrator

<#
.SYNOPSIS
 Shrinks a drive, creates a Dev Drive, and enables ReFS deduplication + compression.

.PARAMETER DriveLetter
 Drive to shrink (e.g., 'C').

.PARAMETER ShrinkGB
 Amount in GB to shrink.

.PARAMETER DedupMode
 'Dedup', 'Compress', or 'DedupAndCompress'.

.PARAMETER CompressionFormat
 'LZ4' (default) or 'ZSTD'.

.PARAMETER CompressionLevel
 Integer 1–9 (for ZSTD), ignored for LZ4.

.PARAMETER RunInitialJob
 Boolean: run initial optimization/dedup job immediately (defaults to True).
#>
param(
    [string] $DriveLetter,
    [int]    $ShrinkGB,
    [ValidateSet('Dedup','Compress','DedupAndCompress')]
    $DedupMode = 'DedupAndCompress',
    [ValidateSet('LZ4','ZSTD')]
    $CompressionFormat = 'LZ4',
    [ValidateRange(1,9)][int] $CompressionLevel = 5,
    [bool]   $RunInitialJob = $true,
    [switch]$Debug
)

function Show-Usage {
    Write-Host "Usage: .\Script.ps1 -DriveLetter <A-Z> -ShrinkGB <GB> [-DedupMode <...>]"
    Write-Host "        [-CompressionFormat <LZ4|ZSTD>] [-CompressionLevel <1-9>] [-RunInitialJob <$true|$false>]"
    exit 1
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

$windows_build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuild).CurrentBuild -as [int]

if ($windows_build -ge 26100) {
    Write-Host "Windows Build $windows_build detected" -ForegroundColor Green
} else {
    Write-Error "Your Windows build $windows_build is lower than 26100. Please update before using the script."
    Show-Usage
}

# Validate DriveLetter
if (-not $DriveLetter -or $DriveLetter.Length -ne 1 -or $DriveLetter -notmatch '^[A-Z]$') {
    Write-Error "Invalid or missing -DriveLetter parameter."
    Show-Usage
}

# Validate ShrinkGB
if (-not $ShrinkGB -or $ShrinkGB -lt 1) {
    Write-Error "Invalid or missing -ShrinkGB parameter."
    Show-Usage
}


try {
    # Shrink Partition
    Write-Host "Getting partition details for $DriveLetter. This may take a minute." -ForegroundColor Green
    $part = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
    $diskNum   = $part.DiskNumber
    $maxSize   = ($part | Get-PartitionSupportedSize).SizeMax
    Write-Host "maxSize: $maxSize"
    $targetSize = $maxSize - ($ShrinkGB * 1GB)
    Write-Host "targetSize: $targetSize"
    if ($targetSize -lt 0) { throw "Cannot shrink by $ShrinkGB GB; insufficient space." }

    Write-Host "Resizing Partition $($part.PartitionNumber) of disk $diskNum to $targetSize" -ForegroundColor Green
    Resize-Partition -DiskNumber $diskNum -PartitionNumber $part.PartitionNumber -Size $targetSize -ErrorAction Stop
    Write-Host "Shrunk $DriveLetter by $ShrinkGB GB" -ForegroundColor Green

    # Create Dev Drive
    if ($Debug) {Write-Host "Create Dev Drive";pause}
    Write-Host "Creating a new partition at disk $diskNum" -ForegroundColor Green
    $newPart = New-Partition -DiskNumber $diskNum -UseMaximumSize -AssignDriveLetter -ErrorAction Stop

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

    # BitLocker
    if ($Debug) {Write-Host "Bitlocker";pause}

    Write-Host "Enter BitLocker password for the new volume. It must be a complex one." -ForegroundColor Yellow
    $SecurePassword = Read-StrongPassword

    Write-Host "Enabling BitLocker for $devLetterColon and recovery key back up to Azure AD." -ForegroundColor Green
    Write-Host "Adding BitLockerKeyProtector PasswordProtector"
    Add-BitLockerKeyProtector -MountPoint $devLetterColon -PasswordProtector -Password $SecurePassword -ErrorAction Stop
    Write-Host "Adding BitLockerKeyProtector RecoveryPasswordProtector"
    Add-BitLockerKeyProtector -MountPoint $devLetterColon -RecoveryPasswordProtector -ErrorAction Stop
    pause

    Write-Host "Enabling Bitlocker"
    Enable-BitLocker -MountPoint $devLetterColon -AdAccountOrGroup $domain_user -AdAccountOrGroupProtector -SkipHardwareTest -UsedSpaceOnly -ErrorAction Stop

    # Backup recovery key to Azure AD (works for AAD-joined devices only)
    if ($Debug) {Write-Host "Bitlocker Azure AD";pause}
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


    # Enable Deduplication + Compression
    Write-Host "Enabling Deduplication mode $DedupMode for $devLetterColon" -ForegroundColor Green
    if ($Debug) {Write-Host "Deduplication";pause}
    Enable-ReFSDedup -Volume "$devLetterColon" -Type $DedupMode -ErrorAction Stop
    Write-Host "Enabled ReFS Dedup mode: $DedupMode" -ForegroundColor Green

    # Define common schedule parameters
    $baseScheduleParams = @{
        Volume            = "$devLetterColon"
        Days              = "Monday,Tuesday,Wednesday,Thursday,Friday"
        Duration          = New-TimeSpan -Hours 2
        CompressionFormat = $CompressionFormat
        CpuPercentage = 60
    }
    if ($CompressionFormat -eq 'ZSTD') {
        $baseScheduleParams.CompressionLevel = [uint16]$CompressionLevel
    }

    # Define start times
    $startTimes = @("11:00", "17:00")

    foreach ($time in $startTimes) {
        $scheduleParams = $baseScheduleParams.Clone()
        $scheduleParams.Start = $time

        Write-Host "Scheduling deduplication job at $time (2h)" -ForegroundColor Green
        if ($Debug) {
            Write-Host "Deduplication Schedule:"
            $scheduleParams.GetEnumerator() | ForEach-Object {
               Write-Host ("  {0,-20} : {1}" -f $_.Key, $_.Value)
            }
            pause
        }

        Set-ReFSDedupSchedule @scheduleParams -ErrorAction Stop
    }

    Write-Host "Scheduled daily dedup jobs" -ForegroundColor Green

    if ($RunInitialJob) {
        $jobParams = @{
            Volume            = "$devLetterColon"
            CompressionFormat = $CompressionFormat
            Duration          = (New-TimeSpan -Hours 5)
            CpuPercentage     = 60
        }
        if ($CompressionFormat -eq 'ZSTD') {
            $jobParams.CompressionLevel = $CompressionLevel
        }
        Write-Host "Running initial Deduplication Job for $devLetterColon" -ForegroundColor Green
        if ($Debug) {Write-Host "Start-ReFSDedupJob";pause}
        Start-ReFSDedupJob @jobParams -FullRun -ErrorAction Stop
        Write-Host "Triggered initial dedup job: Format=$CompressionFormat, Level=$CompressionLevel" -ForegroundColor Green
    }

    Write-Host "All done. Dev Drive $devLetterColon ready." -ForegroundColor Green
    if ($Debug) {Write-Host "Done";pause}
}
catch {
    Write-Error "Error: $_"
    Show-Usage
}
