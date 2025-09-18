#Requires -RunAsAdministrator

<#
.SYNOPSIS
 Creates a Dev Drive from existing free space on a physical drive or by shrinking a logical drive, and enables ReFS deduplication + compression.

.PARAMETER DiskNumber
 Physical disk number to use for creating the Dev Drive from free space.

.PARAMETER DriveLetter
 Drive letter to shrink (A-Z) for creating the Dev Drive.

.PARAMETER SizeGB
 Size in GB for the new Dev Drive.

.PARAMETER ShrinkGB
 Amount in GB to shrink from the selected drive (alternative to SizeGB).

.PARAMETER Interactive
 Show interactive drive selection menu.

.PARAMETER DedupMode
 'Dedup', 'Compress', or 'DedupAndCompress'.

.PARAMETER CompressionFormat
 'LZ4' (default) or 'ZSTD'.

.PARAMETER CompressionLevel
 Integer 1–9 (for ZSTD), ignored for LZ4.

.PARAMETER RunInitialJob
 Boolean: run initial optimization/dedup job immediately (defaults to True).

.PARAMETER SkipWindowsVersionCheck
 Skip Windows version check (use at your own risk).

.PARAMETER SkipBitLocker
 Skip BitLocker encryption setup.
#>
param(
    [int]    $DiskNumber,
    [string] $DriveLetter,
    [int]    $SizeGB,
    [int]    $ShrinkGB,
    [switch] $Interactive,
    [ValidateSet('Dedup','Compress','DedupAndCompress')]
    $DedupMode = 'Dedup',
    [ValidateSet('LZ4','ZSTD')]
    $CompressionFormat = 'LZ4',
    [ValidateRange(1,9)][int] $CompressionLevel = 5,
    [bool]   $RunInitialJob = $true,
    [switch]$Debug,
    [switch]$SkipWindowsVersionCheck,
    [switch]$SkipBitLocker
)

function Show-Usage {
    Write-Host "Usage:"
    Write-Host "  Interactive mode: .\dev_drive.ps1 -Interactive"
    Write-Host "  Free space mode: .\dev_drive.ps1 -DiskNumber <0-9> -SizeGB <GB> [-DedupMode <...>]"
    Write-Host "  Shrink mode: .\dev_drive.ps1 -DriveLetter <A-Z> -ShrinkGB <GB> [-DedupMode <...>]"
    Write-Host "  [-CompressionFormat <LZ4|ZSTD>] [-CompressionLevel <1-9>] [-RunInitialJob <$true|$false>] [-SkipBitLocker]"
    exit 1
}

function Prompt-BitLockerChoice {
    Write-Host "`nDo you want to enable BitLocker encryption for the Dev Drive?" -ForegroundColor Cyan
    Write-Host "BitLocker provides security but may impact performance." -ForegroundColor White
    Write-Host "1. Yes, enable BitLocker encryption (recommended for security)" -ForegroundColor White
    Write-Host "2. No, skip BitLocker encryption (better performance)" -ForegroundColor White
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
    Write-Host "`n=== MODE 1: USING UNALLOCATED PHYSICAL DRIVE SPACE ===" -ForegroundColor Cyan
    Write-Host "Select a drive for Dev Drive creation:`n" -ForegroundColor White

    $disks = Get-Disk | Where-Object { $_.BusType -ne 'Unknown' } | Sort-Object Number

    foreach ($disk in $disks) {
        $diskNumber = $disk.Number
        $diskSizeGB = [math]::Round($disk.Size / 1GB, 2)

        # Calculate allocated space more accurately
        $partitions = Get-Partition -DiskNumber $diskNumber
        $allocatedSize = 0
        $hiddenPartitions = @()

        Write-Host "  Detailed partition analysis:" -ForegroundColor Gray
        foreach ($partition in $partitions) {
            $partitionInfo = "    $($partition.PartitionNumber): $($partition.Type) - $([math]::Round($partition.Size / 1GB, 2)) GB"
            if ($partition.DriveLetter) {
                $partitionInfo += " (Drive $($partition.DriveLetter):)"
                $allocatedSize += $partition.Size
            } elseif ($partition.Type -eq 'Basic' -or $partition.Type -eq 'Dynamic') {
                $partitionInfo += " (No drive letter)"
                $allocatedSize += $partition.Size
            } else {
                $partitionInfo += " (System/Reserved - excluded from free space calc)"
                $hiddenPartitions += $partition
            }
            Write-Host $partitionInfo -ForegroundColor Gray
        }

        if ($hiddenPartitions.Count -gt 0) {
            Write-Host "  System/Reserved partitions: $($hiddenPartitions.Count) found" -ForegroundColor Gray
        }

        $freeSpaceGB = [math]::Round(($disk.Size - $allocatedSize) / 1GB, 2)

        Write-Host "Disk $diskNumber`: $($disk.FriendlyName)" -ForegroundColor Yellow
        Write-Host "  Total Size: $diskSizeGB GB" -ForegroundColor White
        Write-Host "  Free Space: $freeSpaceGB GB" -ForegroundColor Green
        Write-Host "  Bus Type: $($disk.BusType)" -ForegroundColor White

        # Show partitions
        $partitions = $disk | Get-Partition | Where-Object { $_.DriveLetter }
        if ($partitions) {
            Write-Host "  Partitions:" -ForegroundColor White
            foreach ($part in $partitions) {
                $partSizeGB = [math]::Round($part.Size / 1GB, 2)
                $partLetter = $part.DriveLetter
                $partType = if ($part.Type -eq 'Basic') { 'Basic' } else { $part.Type }
                Write-Host "    $partLetter`: $partSizeGB GB ($partType)" -ForegroundColor Gray
            }
        }
        Write-Host ""
    }

    Write-Host "=== MODE 2: SHRINKING EXISTING LOGICAL DRIVES ===" -ForegroundColor Cyan
    Write-Host "Available drives for shrinking (shows free space INSIDE each drive):`n" -ForegroundColor White

    $volumes = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } | Sort-Object DriveLetter
    foreach ($vol in $volumes) {
        $letter = $vol.DriveLetter
        $sizeGB = [math]::Round($vol.Size / 1GB, 2)
        $freeGB = [math]::Round($vol.SizeRemaining / 1GB, 2)
        $usedPercent = [math]::Round((($vol.Size - $vol.SizeRemaining) / $vol.Size) * 100, 1)

        # Calculate estimated shrinkable space (accounting for system overhead and fragmentation)
        $shrinkableGB = [math]::Max(0, $freeGB - 5)  # Conservative 5GB buffer for system stability

        Write-Host "Drive $letter`: $($vol.FileSystemLabel)" -ForegroundColor Yellow
        Write-Host "  Total: $sizeGB GB | Free: $freeGB GB | Used: $usedPercent%" -ForegroundColor White
        Write-Host "  Estimated Shrinkable: $shrinkableGB GB" -ForegroundColor Green
        Write-Host "  File System: $($vol.FileSystem)" -ForegroundColor Gray
        Write-Host ""
    }
    Write-Host "The real shrinkable size may differ!" -ForegroundColor White
    Write-Host "Windows allows shrinking a logical drive onmy by the size of starting from the end of the logical drive disk space to the nearest written file block." -ForegroundColor White
    Write-Host "Disk Fragmentation can affect unmovable file parts. Try defragmenting the drive if Windows does not allow it to shrink more." -ForegroundColor White
    Write-Host "Otherwise, try using third-party tools (e.g. AOMEI)." -ForegroundColor White
    Write-Host ""
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

if (-not $SkipWindowsVersionCheck) {
    $windows_build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuild).CurrentBuild -as [int]

    if ($windows_build -ge 26100) {
        Write-Host "Windows Build $windows_build detected" -ForegroundColor Green
    } else {
        Write-Error "Your Windows build $windows_build is lower than 26100. Please update before using the script."
        Show-Usage
    }
} else {
    Write-Host "Skipping Windows version check. Note that ealier builds might not support ReFS Deduplication" -ForegroundColor Yellow
}

# Interactive mode or parameter validation
if ($Interactive) {
    Show-DriveSelection
    $mode = Select-DriveMode

    if ($mode -eq "FreeSpace") {
        while ($true) {
            $selectedDisk = Read-Host "Enter disk number for free space creation"
            if ($selectedDisk -match '^\d+$' -and [int]$selectedDisk -ge 0) {
                $DiskNumber = [int]$selectedDisk
                break
            } else {
                Write-Host "Invalid disk number. Please enter a non-negative integer." -ForegroundColor Red
            }
        }

        while ($true) {
            $selectedSize = Read-Host "Enter Dev Drive size in GB"
            if ($selectedSize -match '^\d+$' -and [int]$selectedSize -ge 1) {
                $SizeGB = [int]$selectedSize
                break
            } else {
                Write-Host "Invalid size. Please enter a positive integer." -ForegroundColor Red
            }
        }
    } else { # ShrinkDrive
        while ($true) {
            $selectedDrive = Read-Host "Enter drive letter to shrink (A-Z)"
            if ($selectedDrive -match '^[A-Z]$') {
                $DriveLetter = $selectedDrive
                break
            } else {
                Write-Host "Invalid drive letter. Please enter a single letter A-Z." -ForegroundColor Red
            }
        }

        while ($true) {
            $selectedShrink = Read-Host "Enter amount to shrink in GB"
            if ($selectedShrink -match '^\d+$' -and [int]$selectedShrink -ge 1) {
                $ShrinkGB = [int]$selectedShrink
                break
            } else {
                Write-Host "Invalid shrink amount. Please enter a positive integer." -ForegroundColor Red
            }
        }
    }

    # Ask about BitLocker encryption
    $enableBitLocker = Prompt-BitLockerChoice
    if (-not $enableBitLocker) {
        $SkipBitLocker = $true
    }
} else {
    # Parameter validation for non-interactive mode
    $hasFreeSpaceParams = ($PSBoundParameters.ContainsKey('DiskNumber') -and $PSBoundParameters.ContainsKey('SizeGB'))
    $hasShrinkParams = ($PSBoundParameters.ContainsKey('DriveLetter') -and $PSBoundParameters.ContainsKey('ShrinkGB'))

    if (-not $hasFreeSpaceParams -and -not $hasShrinkParams) {
        Write-Error "Either specify -DiskNumber and -SizeGB for free space creation, or -DriveLetter and -ShrinkGB for shrinking, or use -Interactive for guided setup."
        Show-Usage
    }

    if ($hasFreeSpaceParams -and $hasShrinkParams) {
        Write-Error "Cannot specify both free space and shrink parameters. Choose one method."
        Show-Usage
    }

    if ($hasFreeSpaceParams) {
        if ($DiskNumber -lt 0) {
            Write-Error "Invalid DiskNumber. Must be a non-negative integer."
            Show-Usage
        }
        if (-not $SizeGB -or $SizeGB -lt 1) {
            Write-Error "Invalid SizeGB. Must be at least 1 GB."
            Show-Usage
        }
        $mode = "FreeSpace"
    } else {
        if (-not $DriveLetter -or $DriveLetter.Length -ne 1 -or $DriveLetter -notmatch '^[A-Z]$') {
            Write-Error "Invalid DriveLetter. Must be a single letter A-Z."
            Show-Usage
        }
        if (-not $ShrinkGB -or $ShrinkGB -lt 1) {
            Write-Error "Invalid ShrinkGB. Must be at least 1 GB."
            Show-Usage
        }
        $mode = "ShrinkDrive"
    }
}


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
        if ($Debug) {Write-Host "Create Dev Drive";pause}
        Write-Host "Creating a new partition with $SizeGB GB on disk $DiskNumber" -ForegroundColor Green
        $newPart = New-Partition -DiskNumber $DiskNumber -Size $requestedSizeBytes -AssignDriveLetter -ErrorAction Stop
    } else { # ShrinkDrive
        # Shrink Partition
        Write-Host "Getting partition details for drive $DriveLetter. This may take a minute." -ForegroundColor Green
        $part = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
        $diskNum = $part.DiskNumber
        $maxSize = ($part | Get-PartitionSupportedSize).SizeMax
        Write-Host "Maximum size for $DriveLetter`: $([math]::Round($maxSize / 1GB, 2)) GB"
        $targetSize = $maxSize - ($ShrinkGB * 1GB)
        Write-Host "Target size after shrinking: $([math]::Round($targetSize / 1GB, 2)) GB"
        if ($targetSize -lt 0) {
            throw "Cannot shrink drive $DriveLetter by $ShrinkGB GB; insufficient space."
        }

        Write-Host "Resizing Partition $($part.PartitionNumber) of disk $diskNum to $([math]::Round($targetSize / 1GB, 2)) GB" -ForegroundColor Green
        Resize-Partition -DiskNumber $diskNum -PartitionNumber $part.PartitionNumber -Size $targetSize -ErrorAction Stop
        Write-Host "Shrunk drive $DriveLetter by $ShrinkGB GB" -ForegroundColor Green

        # Create Dev Drive from the freed space
        if ($Debug) {Write-Host "Create Dev Drive";pause}
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
        if ($Debug) {Write-Host "Bitlocker";pause}

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
                        Write-Host "" -ForegroundColor Yellow
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
        CpuPercentage = 60
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
        if ($Debug) {Write-Host "Start-ReFSDedupJob";pause}

        if ($DedupMode -eq 'Dedup') {
            Start-ReFSDedupJob @jobParams -FullRun -ErrorAction Stop
            Write-Host "Triggered initial dedup job (deduplication only)" -ForegroundColor Green
        } else {
            Start-ReFSDedupJob @jobParams -ErrorAction Stop
            Write-Host "Triggered initial dedup job: Format=$CompressionFormat, Level=$CompressionLevel" -ForegroundColor Green
        }
    }

    Write-Host "All done. Dev Drive $devLetterColon ready." -ForegroundColor Green
    if ($Debug) {Write-Host "Done";pause}
}
catch {
    Write-Error "Error: $_"
    Show-Usage
}
