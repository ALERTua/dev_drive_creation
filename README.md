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

<iframe width="560" height="315" src="https://www.youtube.com/embed/7WqRmNFrXiE?si=XEJHNscr0wEUzxPj" title="YouTube video player" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" referrerpolicy="strict-origin-when-cross-origin" allowfullscreen></iframe>

## Requirements

- **Windows 11 26100 or newer**
- **Administrator privileges** - Script must be run as administrator (elevated)

## Basic Usage

```powershell
.\dev_drive.ps1
```
This script runs in interactive mode and will guide you through the entire Dev Drive creation process.

**Important**: The script performs disk operations and must be run with administrator privileges. Right-click the script and select "Run as administrator" or use an elevated PowerShell session.

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

=== GATHERING CONFIGURATION ===                                                                              
Let's collect all the information needed to create your Dev Drive.
No changes will be made until you confirm the plan.
                                                                                                             

Select the physical drive where you want to create your Dev Drive:                                           
                                                                                                             
Disk 0: Samsung SSD 990 PRO 1TB
  Size: 931.51 GB
  Free Space: 2.22 GB
  Drives: C

Disk 1: CT4000P3PSSD8
  Size: 3726.02 GB
  Free Space: 0.02 GB
  Drives: D, V


=== SELECT PHYSICAL DRIVE ===                                                                                
Enter the disk number you want to use for Dev Drive creation:
Disk number: 1
Selected Disk 1: CT4000P3PSSD8

Choose Dev Drive creation method:                                                                            
1. Use UNALLOCATED FREE SPACE on a physical drive
2. SHRINK an existing logical drive to create space
3. Exit

Enter your choice (1 or 2): 2

=== SELECT DRIVE TO SHRINK ===                                                                               
Available drives on Disk 1 for shrinking:
  Drive D: ALERT
    Total: 3613.28 GB | Free: 842.78 GB | Shrinkable: ~838 GB
  Drive V: dev
    Total: 112.69 GB | Free: 76.89 GB | Shrinkable: ~72 GB
Enter drive letter to shrink: D
Selected Drive D: ALERT (842.78 GB free)
Getting Partition information...
Shrinkable size information:
  Current partition size: 3613.28 GB                                                                         
  Minimum partition size: 2796.92 GB                                                                         
  Maximum shrinkable: 816.36 GB                                                                              
                                                                                                             
Note: Windows allows shrinking by the size of starting from the end of the drive disk space to the nearest written file block. Disk Fragmentation can affect this. If Windows does not allow for a drive to be shrunk, please use third-party tools (e.g. AOMEI).                                                                      
                                                                                                             
Enter amount to shrink in GB (max: 816.36 GB): 199                                                           
                                                                                                             
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

Enter your choice (1, 2 or 3): 2

Choose compression format:                                                                                   
1. LZ4: Fast compression with good balance of speed and compression ratio
2. ZSTD: Better compression ratio but uses more CPU (allows custom compression level)

Enter your choice (1 or 2): 2

Choose ZSTD compression level (1-9):                                                                         
Lower levels (1-3): Faster compression, less CPU usage
Medium levels (4-6): Balanced speed and compression
Higher levels (7-9): Better compression, more CPU usage

Enter compression level (1-9): 2
Selected ZSTD compression with level 2


===============================================================================
                        DEV DRIVE CREATION PLAN
===============================================================================

* Shrink Drive D (ALERT) by 199 GB to free up space
* Create 199 GB Dev Drive on Disk 1 (CT4000P3PSSD8) using ReFS
* Enable ReFS deduplication with ZSTD compression (level 2)
* Schedule daily optimization jobs at 11:00 and 17:00 (AC power only)
* Schedule weekly maintenance job every Monday at 17:30
* Mark Dev Drive as trusted for Windows Defender performance
* Run initial optimization job to prepare the drive

===============================================================================

WARNING: This will make permanent changes to your disk configuration.                                        
   Make sure you have backups of important data before proceeding.
                                                                                                             
Are you ready to proceed with Dev Drive creation? (yes/no): y

Starting Dev Drive creation...                                                                               
Using previously retrieved partition information for drive D
Maximum size for D: 3613.28 GB
Target size after shrinking: 3414.28 GB
Resizing Partition 2 of disk 1 to 3414.28 GB ...
Shrunk drive D by 199 GB
Creating a new partition from the freed space on disk 1
Formatting the newly created partition drive E: to a Dev Drive

Dev Drive created at E:
Marking Dev Drive E: as trusted for Defender performance
Dev Drive marked trusted.
Skipping BitLocker encryption as requested.
Enabling Deduplication mode DedupAndCompress for E:
Enabled ReFS Dedup mode: DedupAndCompress
Scheduling deduplication job at 11:00 (2h)
Scheduling deduplication job at 17:00 (2h)
Scheduled daily dedup jobs
Configuring deduplication tasks to run only on AC power...
Successfully configured 1 deduplication task(s) to run only on AC power
Scheduling deduplication scrub jobs
Scheduled weekly scrub job on Monday at 12:00 (4h)
Running initial Deduplication Job for E:
Triggered initial dedup job: Format=ZSTD, Level=2
All done. Dev Drive E: ready.
DriveLetter FriendlyName FileSystemType DriveType HealthStatus OperationalStatus SizeRemaining   Size
----------- ------------ -------------- --------- ------------ ----------------- -------------   ----
E           DevDrive     ReFS           Fixed     Healthy      OK                    196.25 GB 199 GB

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
