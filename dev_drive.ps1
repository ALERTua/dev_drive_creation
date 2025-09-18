# -*- coding: utf-8 -*-
#Requires -RunAsAdministrator

<#
.SYNOPSIS
 Dev Drive creation script that guides users through creating a Dev Drive with BitLocker encryption and ReFS deduplication.
#>
param()

function Prompt-BitLockerChoice {
    Write-Host "`nDo you want to enable BitLocker encryption for the Dev Drive?" -ForegroundColor Cyan
    Write-Host "BitLocker provides security but may impact performance." -ForegroundColor White
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
    Write-Host "3. Exit" -ForegroundColor White
    Write-Host ""

    while ($true) {
        $choice = Read-Host "Enter your choice (1 or 2)"
        if ($choice -eq "1") {
            return "FreeSpace"
        } elseif ($choice -eq "2") {
            return "ShrinkDrive"
        } elseif ($choice -eq "3") {
            exit 0
        } else {
            Write-Host "Invalid choice. Please enter 1, 2 or 3." -ForegroundColor Red
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

# Step 1: Show drive information and let user select a drive
Show-DriveSelection

# Step 2: Ask user to select a physical drive
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

# Step 3: Ask user to select the creation mode
$mode = Select-DriveMode

# Step 4: Get mode-specific parameters
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
    $freeSpaceGB = [math]::Round(($selectedDisk.Size - $allocatedSize) / 1GB, 2)

    Write-Host "`nDisk $DiskNumber has $freeSpaceGB GB of free space available." -ForegroundColor Cyan

    while ($true) {
        $selectedSize = Read-Host "Enter Dev Drive size in GB (max: $freeSpaceGB, press Enter for max)"
        if ([string]::IsNullOrWhiteSpace($selectedSize)) {
            # User pressed Enter, use maximum available space
            $SizeGB = [int]$freeSpaceGB
            Write-Host "Using maximum available space: $SizeGB GB" -ForegroundColor Green
            break
        } elseif ($selectedSize -match '^\d+$' -and [int]$selectedSize -ge 1 -and [int]$selectedSize -le $freeSpaceGB) {
            $SizeGB = [int]$selectedSize
            break
        } elseif ([int]$selectedSize -gt $freeSpaceGB) {
            Write-Host "Size cannot exceed available free space ($freeSpaceGB GB). Please enter a smaller size." -ForegroundColor Red
        } else {
            Write-Host "Invalid size. Please enter a positive integer." -ForegroundColor Red
        }
    }

    $creationMethod = "Use $SizeGB GB of free space from Disk $DiskNumber ($selectedDiskName)"
} else { # ShrinkDrive
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
                Write-Host "Getting Partition shrinkable size information..." -ForegroundColor Cyan
                try {
                    $partitionInfo = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
                    $supportedSizes = $partitionInfo | Get-PartitionSupportedSize -ErrorAction Stop
                    $minSizeGB = [math]::Round($supportedSizes.SizeMin / 1GB, 2)
                    $realMaxShrinkableGB = [math]::Round(($partitionInfo.Size - $supportedSizes.SizeMin) / 1GB, 2)

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
                    $realMaxShrinkableGB = [math]::Round(($driveOnDisk.SizeRemaining / 1GB), 2) - 5
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

    while ($true) {
        $selectedShrink = Read-Host "Enter amount to shrink in GB (max: $realMaxShrinkableGB GB)"
        if ($selectedShrink -match '^\d+$' -and [int]$selectedShrink -ge 1 -and [int]$selectedShrink -le $realMaxShrinkableGB) {
            $ShrinkGB = [int]$selectedShrink
            $SizeGB = $ShrinkGB  # Set the Dev Drive size to match the shrink amount
            break
        } elseif ([int]$selectedShrink -gt $realMaxShrinkableGB) {
            Write-Host "Shrink amount cannot exceed the maximum shrinkable size ($realMaxShrinkableGB GB). Please enter a smaller amount." -ForegroundColor Red
        } else {
            Write-Host "Invalid shrink amount. Please enter a positive integer." -ForegroundColor Red
        }
    }

    $creationMethod = "Shrink Drive $DriveLetter ($driveLabel) by $ShrinkGB GB to create $ShrinkGB GB Dev Drive"
}

# Ask about BitLocker encryption
$enableBitLocker = Prompt-BitLockerChoice
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
Write-Host "* Create $SizeGB GB Dev Drive on Disk $DiskNumber ($selectedDiskName) using ReFS" -ForegroundColor White

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
        $requestedSizeBytes = $SizeGB * 1GB
        if ($freeSpace -lt $requestedSizeBytes) {
            throw "Insufficient free space on disk $DiskNumber. Requested: $SizeGB GB, Available: $freeSpaceGB GB"
        }

        Write-Host "Creating Dev Drive with $SizeGB GB from free space on disk $DiskNumber" -ForegroundColor Green

        # Create Dev Drive
        Write-Host "Creating a new partition with $SizeGB GB on disk $DiskNumber" -ForegroundColor Green
        $newPart = New-Partition -DiskNumber $DiskNumber -Size $requestedSizeBytes -AssignDriveLetter -ErrorAction Stop
    } else { # ShrinkDrive
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
        $targetSize = $maxSize - ($ShrinkGB * 1GB)
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
        $maxRetries = 3

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
        }
    } else {
        Write-Host "Skipping deduplication as requested." -ForegroundColor Yellow
    }

    Write-Host "All done. Dev Drive $devLetterColon ready." -ForegroundColor Green
}
catch {
    Write-Host "An error occurred during Dev Drive creation:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    Write-Host "Please check the error message and try again." -ForegroundColor Yellow
    exit 1
}
