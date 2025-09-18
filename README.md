# Windows 11 Dev Drive Creation Script

An interactive PowerShell script that guides users through creating Windows Dev Drives with customizable BitLocker encryption and ReFS deduplication settings.

## Features

- **Interactive Setup**: Step-by-step guided creation process
- **Flexible Creation Methods**: Use free space or shrink existing drives
- **Smart Drive Selection**: Shows detailed drive information for informed choices
- **Optional BitLocker**: Choose encryption with automatic retry on password rejection
- **Advanced Deduplication**: Configure deduplication with optional compression
- **Compression Options**: Choose LZ4 or ZSTD with customizable compression levels
- **Real Size Limits**: Shows actual Windows shrinkable limits, not estimates
- **Power-Aware Scheduling**: Deduplication jobs run only on AC power to preserve battery
- **Smart Defaults**: Press Enter for maximum sizes, sensible defaults throughout
- **Robust Error Handling**: Comprehensive validation and user-friendly error messages

## Requirements

- Windows 11 (Dev Drive support)
- Administrator privileges
- Azure AD-joined device (for BitLocker key backup)
- PowerShell 5.1 or later

## Basic Usage

```powershell
.\dev_drive.ps1
```
This script runs in interactive mode and will guide you through the entire Dev Drive creation process.

### What the Interactive Process Includes:

1. **Drive Selection**: Shows all physical drives with size and free space information
2. **Creation Method**: Choose between using free space or shrinking an existing drive
3. **Size Configuration**: Enter Dev Drive size (press Enter for maximum available)
4. **BitLocker Setup**: Optional encryption with automatic password retry
5. **Deduplication Options**: Choose deduplication level and compression settings
6. **Compression Configuration**: Select format (LZ4/ZSTD) and level (1-9 for ZSTD)

### Interactive Flow:

```
Dev Drive creation script with BitLocker encryption and ReFS deduplication.
Windows Build 26100 is OK

Select the physical drive where you want to create your Dev Drive:                                       
                                                                                                         
Disk 0: Samsung SSD 990 PRO 1TB
  Size: 931.51 GB
  Free Space: 2.22 GB
  Drives: C

Disk 1: CT1234P3PSSD8
  Size: 3726.02 GB
  Free Space: 100.02 GB
  Drives: D, V


=== SELECT PHYSICAL DRIVE ===                                                                            
Enter the disk number you want to use for Dev Drive creation:
Disk number: 1
Selected Disk 1: CT4000P3PSSD8

Choose Dev Drive creation method:                                                                        
1. Use UNALLOCATED FREE SPACE on a physical drive
2. SHRINK an existing logical drive to create space
3. Exit

Enter your choice (1 or 2): 1

Disk 1 has 100.02 GB of free space available.                                                            
Enter Dev Drive size in GB (max: 100.02, press Enter for max): 
Using maximum available space: 100 GB

Do you want to enable BitLocker encryption for the Dev Drive?                                            
BitLocker provides security but may impact performance.
1. Yes, enable BitLocker encryption
2. No, skip BitLocker encryption

Enter your choice (1 or 2): 2

Do you want to enable ReFS deduplication for the Dev Drive?                                              
Deduplication saves disk space by eliminating duplicate data.
1. Yes, enable deduplication only (recommended for most users)
2. Yes, enable deduplication + compression (configure compression settings)
3. No, skip deduplication (maximum performance, less space savings)

Enter your choice (1, 2 or 3): 1
Selected deduplication only (no compression)
Checking disk 1 for available free space...
Disk 1 total size: 3726.02 GB
Disk 1 allocated space: 3626.01 GB
Disk 1 free space: 100.02 GB
Creating Dev Drive with 100 GB from free space on disk 1
Creating a new partition with 100 GB on disk 1
Formatting the newly created partition drive E: to a Dev Drive

Dev Drive created at E:
Marking Dev Drive E: as trusted for Defender performance
Dev Drive marked trusted.
Skipping BitLocker encryption as requested.
Enabling Deduplication mode Dedup for E:
Enabled ReFS Dedup mode: Dedup
Scheduling deduplication job at 11:00 (2h)
Scheduling deduplication job at 17:00 (2h)
Scheduled daily dedup jobs
Configuring deduplication tasks to run only on AC power...
Successfully configured 15 deduplication task(s) to run only on AC power
Scheduling deduplication scrub jobs
Scheduled weekly scrub job on Monday at 12:00 (4h)
Running initial Deduplication Job for E:
Triggered initial dedup job (deduplication only)
All done. Dev Drive E: ready.
```

## What It Does

### Interactive Dev Drive Creation Process:

1. **Drive Discovery & Selection**
   - Scans all physical drives and shows size, free space, and existing partitions
   - User selects target physical drive for Dev Drive creation
   - Displays real Windows partition limits (not estimates)

2. **Creation Method Selection**
   - **Free Space Mode**: Uses unallocated space on the selected drive
   - **Shrink Mode**: Shrinks an existing logical drive to create space
   - Shows available options based on selected drive

3. **Size Configuration**
   - Prompts for Dev Drive size with real limits shown
   - Press Enter to use maximum available space
   - Validates input against actual Windows constraints

4. **Security Configuration**
   - Optional BitLocker encryption with strong password requirements
   - Automatic retry if password is rejected by BitLocker
   - Azure AD backup for recovery keys

5. **Storage Optimization Setup**
   - Choose deduplication level (none, deduplication-only, or with compression)
   - Select compression format (LZ4 for speed, ZSTD for better compression)
   - Configure compression level (1-9 for ZSTD, affects CPU usage)
   - Jobs automatically scheduled to run only on AC power

6. **Dev Drive Creation & Setup**
   - Creates ReFS-formatted Dev Drive with selected size
   - Applies all chosen security and optimization settings
   - Marks drive as trusted for Windows Defender performance
   - Runs initial optimization job to prepare the drive

### Advanced Features:

- **Real-Time Validation**: Shows actual Windows limits, not estimates
- **Smart Defaults**: Sensible defaults with easy override options
- **Power Management**: Deduplication jobs only run on AC power
- **Error Recovery**: Handles password rejection and API failures gracefully
- **User-Friendly**: Clear prompts with helpful explanations throughout

## Security Notes

- Requires complex password (8+ chars, upper/lower/digit/special)
- BitLocker recovery key backed up to Azure AD
- Auto-unlock enabled for convenience
- Drive marked as trusted for development workloads

## Scheduled Jobs

The script creates two daily deduplication jobs that run **only on AC power**:
- 11:00 AM (2 hours duration)
- 5:00 PM (2 hours duration)

Jobs run Monday-Friday with 60% CPU limit to preserve battery life on laptops.

## Troubleshooting

- Ensure sufficient free space exists on the selected physical disk
- Run as Administrator
- Verify Azure AD connectivity for BitLocker backup
- Check Dev Drive support on your Windows version

More on Dev Drive at https://learn.microsoft.com/en-us/windows/dev-drive/
