# Windows 11 Dev Drive Creation Script

An interactive PowerShell script that guides users through creating Windows Dev Drives with customizable BitLocker encryption and ReFS deduplication settings.

## Features

- **Interactive Setup**: Step-by-step guided creation process
- **Flexible Creation Methods**: Use free space, shrink an existing drive, or create a `.vhdx` file
- **Virtual Hard Disk Mode**: Puts the Dev Drive in a `.vhdx` file that Windows can mount on every startup
- **Smart Drive Selection**: Shows detailed drive information for informed choices
- **Optional BitLocker**: Encryption that fits the machine, with the recovery key shown before the run goes on and a rejected password asked for again
- **Advanced Deduplication**: Configure deduplication with optional compression
- **Compression Options**: Choose LZ4 or ZSTD with customizable compression levels
- **Real Size Limits**: Shows actual Windows shrinkable limits, not estimates
- **Power-Aware Scheduling**: Deduplication jobs run only on AC power to preserve battery
- **Smart Defaults**: Press Enter for maximum partition sizes, sensible defaults throughout
- **Robust Error Handling**: Comprehensive validation and user-friendly error messages

https://github.com/user-attachments/assets/e5e97018-6966-4c64-8aaf-08764670f31f

## Requirements

- **Windows 11 26100 or newer**
- **Administrator privileges** - Script must be run as administrator (elevated)
- **50 GB minimum** - The selected disk's free space, the drive's shrinkable space, or the requested `.vhdx` size must be at least 50 GB, the documented Dev Drive minimum. The script stops when a disk or drive cannot offer that much, and re-asks when a size you type is too small

## Basic Usage

```powershell
.\dev_drive.ps1
```
This script runs in interactive mode and will guide you through the entire Dev Drive creation process.

**Important**: The script performs disk operations and must be run with administrator privileges. Right-click the script and select "Run as administrator" or use an elevated PowerShell session.

### What the Interactive Process Includes:

1. **Creation Method**: Free space on a disk, shrinking an existing drive, or a `.vhdx` file
2. **Drive Selection**: Shows all physical drives with size and free space information
3. **Size Configuration**: Enter Dev Drive size (minimum 50 GB; in free-space mode press Enter for the maximum)
4. **BitLocker Setup**: Optional encryption, with the recovery key shown and acknowledged
5. **Deduplication Options**: Choose deduplication level and compression settings
6. **Compression Configuration**: Select format (LZ4/ZSTD) and level (1-9 for ZSTD)

In virtual hard disk mode, step 2 is skipped; instead you are asked for the file path, the disk
type, the size and whether to mount the file automatically on startup. There is no press-Enter-for-
maximum there, and the size has a 50 GB floor.
See [Virtual hard disk mode](#virtual-hard-disk-mode).

### Interactive Flow:

```
Dev Drive creation script with BitLocker encryption and ReFS deduplication.
Windows Build 26100 is OK

=== GATHERING CONFIGURATION ===                                                                              
Let's collect all the information needed to create your Dev Drive.
No changes will be made until you confirm the plan.
                                                                                                             

Choose Dev Drive creation method:                                                                            
1. Use UNALLOCATED FREE SPACE on a physical drive
2. SHRINK an existing logical drive to create space
3. Create a VIRTUAL HARD DISK (.vhdx file) on an existing drive
4. Exit

Enter your choice (1, 2, 3 or 4): 2

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

=== SELECT DRIVE TO SHRINK ===                                                                               
Available drives on Disk 1 for shrinking:
  Drive D: ALERT
    Total: 3613.28 GB | Free: 842.78 GB | Shrinkable: ~838 GB
  Drive V: dev
    Total: 112.69 GB | Free: 76.89 GB | Shrinkable: ~72 GB
Enter drive letter to shrink: D
Selected Drive D: ALERT (842.78 GB free)
Getting Partition shrinkable size information (this may take ~30 seconds)...
Shrinkable size information:
  Current partition size: 3613.28 GB                                                                         
  Smallest size Windows allows: 2797 GB                                                                      
  Maximum shrinkable: 816.28 GB                                                                              
                                                                                                             
Note: Windows allows shrinking by the size of starting from the end of the drive disk space to the nearest written file block. Disk Fragmentation can affect this. If Windows does not allow for a drive to be shrunk, please use third-party tools (e.g. AOMEI).                                                                      
                                                                                                             
Drive D: is 3613.28 GB now.                                                                          
Enter the size drive D: should end up as in GB (min: 2797, max: 3563.28): 3414.28                    
                                                                                                             
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

* Shrink Drive D (ALERT) from 3613.28 GB to 3414.28 GB, freeing 199.00 GB
* Create 199.00 GB Dev Drive on Disk 1 (CT4000P3PSSD8) using ReFS
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
Shrunk drive D to 3414.28 GB, freeing 199.00 GB
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

1. **Creation Method Selection**
   - **Free Space Mode**: Uses unallocated space on a physical drive
   - **Shrink Mode**: Shrinks an existing logical drive to create space. You are asked for the
     size the drive should end up as, not for an amount to take off it, so answering with the
     same size again after a failed run leaves the drive alone instead of shrinking it twice
   - **Virtual Hard Disk Mode**: Creates a `.vhdx` file on an existing volume

2. **Drive Discovery & Selection**
   - Scans all physical drives and shows size, free space, and existing partitions
   - User selects target physical drive for Dev Drive creation
   - Displays real Windows partition limits (not estimates)
   - Skipped in virtual hard disk mode, which asks for a file path instead

3. **Size Configuration**
   - Prompts for Dev Drive size with real limits shown
   - Press Enter to use the maximum, in free-space mode only
   - Validates input against actual Windows constraints, including the 50 GB Dev Drive minimum

4. **Security Configuration**
   - Optional BitLocker encryption, enabled together with its recovery key in one step
   - The recovery key is printed and has to be acknowledged before the run continues
   - A password is asked for in virtual hard disk mode only, and asked for again if BitLocker rejects it
   - The domain account protector is added only on a machine joined to an Active Directory domain
   - The recovery key goes to Azure AD only on a device joined to Entra ID
   - Automatic unlocking is set only when the operating system drive is BitLocker-protected
   - What the machine can actually do is checked before the plan is shown, and listed in it
   - A BitLocker failure offers a choice: retry, carry on without it, or stop

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

## Virtual hard disk mode

Instead of repartitioning a physical disk, this mode puts the Dev Drive inside a `.vhdx` file on a
volume you already have. It is the same thing Windows Settings offers as **Create new VHD**, which
is useful when the Settings app is not an option — for example on machines where elevation comes
from a tool that cannot launch Settings elevated.

The script asks for four things:

- **Path** of the `.vhdx` file. The folder must already exist, the file must not, and the volume
  hosting it must be a fixed disk — Windows does not support a Dev Drive inside a `.vhdx` on a
  removable disk. A per-user directory keeps the Dev Drive from being shared unintentionally.
- **Disk type**. *Dynamically expanding* grows as data is written and is what Microsoft recommends.
  *Fixed size* claims the whole file up front, which takes minutes rather than seconds and cannot be
  interrupted once started.
- **Size**, at least 50 GB. That is Microsoft's documented minimum for any Dev Drive. For a fixed
  size disk the size cannot exceed the host volume's free space less 1 GB of head-room; for a dynamically expanding
  one a larger limit is allowed with a warning.
- **Automatic mounting** on startup.

The file is created and attached through `virtdisk.dll` directly, not with `diskpart` or
`Mount-DiskImage`. The reason is automatic mounting, described below. Everything after that — ReFS
formatting, the trusted flag, BitLocker, deduplication — is identical to the other two modes.

### Automatic mounting

A `.vhdx` attached the ordinary way does not survive a restart, and no PowerShell cmdlet can change
that. Automatic mounting has to be requested when the disk is attached, by passing
`ATTACH_VIRTUAL_DISK_FLAG_AT_BOOT` to
[`AttachVirtualDisk`](https://learn.microsoft.com/en-us/windows/win32/api/virtdisk/nf-virtdisk-attachvirtualdisk).
Neither `diskpart` nor `Mount-DiskImage` passes it; until now only the Windows Settings **Disks &
volumes** page did, which is why a Dev Drive created there comes back after a restart and one
created from a script does not.

The script calls that API itself. Windows then records the file under
`HKLM\SYSTEM\CurrentControlSet\Control\AutoAttachVirtualDisks` on its own and reattaches it on every
startup, with the same drive letter and its trusted Dev Drive status intact. That registry entry is
Windows's own bookkeeping — writing it by hand does not enable anything.

Older Windows builds may reject the flag. If that happens the script says so, attaches the disk
anyway, and you get a working Dev Drive that needs mounting by hand after each restart.

Whenever the disk will not be mounted for you — because Windows refused the flag, or because you
declined automatic mounting — the script prints the command, once when the disk is attached and
again at the end so it does not scroll away:

```powershell
Mount-DiskImage -ImagePath 'D:\DevDrive.vhdx' -StorageType VHDX -Access ReadWrite
```

Run it from a PowerShell started as administrator. Microsoft's
[`Mount-DiskImage` reference](https://learn.microsoft.com/en-us/powershell/module/storage/mount-diskimage)
states that mounting a virtual hard disk requires administrator privileges, unlike mounting an
`.iso` file.

### BitLocker inside a virtual hard disk

Microsoft's documentation states that a `.vhdx` is already covered by BitLocker on the volume that
hosts it, and that enabling BitLocker on the mounted virtual disk is unnecessary. The script says so
before asking, but leaves the choice to you.

### Deduplication inside a virtual hard disk

Deduplication works on the ReFS volume inside the file and frees space there as it does on a
partition. The `.vhdx` file itself does **not** shrink — it keeps the largest size it has ever
reached, and a deduplication run adds a little to it for its own bookkeeping.

Reclaiming that space on the host means compacting the file, and there are reports of data
corruption when compacting a `.vhdx` whose contents are deduplicated. Do not run `compact vdisk`
against a deduplicated Dev Drive without a backup.

## Security Notes

- Requires a complex password (8+ chars, upper/lower/digit/special) where one is asked for
- BitLocker recovery key printed for you to write down, and backed up to Azure AD on an Entra ID device
- On a device outside Entra ID the key exists only on the volume and on your paper copy, so keep it
- Auto-unlock enabled where Windows allows it, meaning the operating system drive is protected too
- Without an Active Directory domain the drive is still encrypted and still has its recovery key
- Drive marked as trusted for development workloads

## Scheduled Jobs

The script creates two daily deduplication jobs that run **only on AC power**:
- 11:00 AM (2 hours duration)
- 5:00 PM (2 hours duration)

Jobs run Monday-Friday with 60% CPU limit to preserve battery life on laptops.

## Development

Run `install-hooks.cmd` once to turn on a tracked `git` pre-commit hook (`.githooks/pre-commit`).
It runs the same three checks as `.github/workflows/ci.yml` against your working tree before each
commit - parsing `dev_drive.ps1`, PSScriptAnalyzer with `PSScriptAnalyzerSettings.psd1`, and the
Pester suite - and refuses the commit if any of them fails, saying which one and why. A single
commit can still skip it with `git commit --no-verify`; to remove the hook entirely, run
`git config --unset core.hooksPath`. Unlike CI, it uses whichever PSScriptAnalyzer/Pester versions
are already installed locally rather than CI's pinned ones.

## Troubleshooting

- Ensure sufficient free space exists on the selected physical disk
- Run as Administrator
- Verify Azure AD connectivity for BitLocker backup
- Check Dev Drive support on your Windows version

More on Dev Drive at https://learn.microsoft.com/en-us/windows/dev-drive/
