# Windows 11 Dev Drive Creation Script

An interactive PowerShell script that guides users through creating Windows Dev Drives with customizable BitLocker encryption and ReFS deduplication settings.

This script automates work you are expected to be able to do by hand: it assumes you understand what it touches - partitions, ReFS, BitLocker and scheduled tasks - and that you can carry out and reverse every step yourself. It does not resume after a failure and undoes nothing for you, so it is not a tool for learning any of that.

## Features

- **Interactive Setup**: Step-by-step guided creation process
- **Flexible Creation Methods**: Use free space, shrink an existing drive, or create a `.vhdx` file
- **Virtual Hard Disk Mode**: Puts the Dev Drive in a `.vhdx` file that Windows can mount on every startup
- **Smart Drive Selection**: Shows detailed drive information for informed choices
- **Optional BitLocker**: Encryption that fits the machine, with the recovery key shown before the run goes on and a rejected password asked for again
- **Advanced ReFS Optimization**: Deduplicate, compress, or both - all three modes ReFS offers
- **Compression Options**: Take LZ4 or ZSTD at Windows' own level in one answer, or pick the format and level yourself
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
4. **Name**: The name the volume carries, or Enter for `DevDrive`
5. **BitLocker Setup**: Optional encryption, with the recovery key shown and acknowledged
6. **Deduplication Options**: Deduplicate only, deduplicate and compress, compress only, or neither
7. **Compression Configuration**: Take LZ4 or ZSTD at the level Windows picks, or set the format and level yourself
8. **Deduplication Schedule**: Keep the suggested times, or set them yourself

In virtual hard disk mode, step 2 is skipped; instead you are asked for the file path, the disk type, the size and whether to mount the file automatically on startup. There is no press-Enter-for-maximum there, and the size has a 50 GB floor. See [Virtual hard disk mode](#virtual-hard-disk-mode).

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
    Total: 3613.28 GB | Free: 842.78 GB | Shrinkable: ~837.78 GB
  Drive V: dev
    Total: 112.69 GB | Free: 76.89 GB | Shrinkable: ~71.89 GB
Enter drive letter to shrink: D
Selected Drive D: ALERT (842.78 GB free)
Getting Partition shrinkable size information (this may take ~30 seconds)...
Shrinkable size information:
  Current partition size: 3613.28 GB                                                                         
  Minimum partition size: 2796.92 GB                                                                         
  Maximum shrinkable: 816.36 GB                                                                              
                                                                                                             
Note: Windows allows shrinking by the size of starting from the end of the drive disk space to the nearest written file block. Disk Fragmentation can affect this. If Windows does not allow for a drive to be shrunk, please use third-party tools (e.g. AOMEI).                                                                      
                                                                                                             
Enter Shrink amount in GB (min: 50, max: 816.36): 199                                                

The Dev Drive carries a name, which is what File Explorer shows beside its letter.
Enter a name for the Dev Drive, or press Enter for DevDrive: Projects

Do you want to enable BitLocker encryption for the Dev Drive?                                                
BitLocker provides security but may impact performance.
1. Yes, enable BitLocker encryption
2. No, skip BitLocker encryption

Enter your choice (1 or 2): 2

What should Windows do with the data on the Dev Drive?                                                       
Deduplication finds and removes duplicate data. Compression makes what is left smaller.
1. Deduplicate only (recommended for most users)
2. Deduplicate and compress (saves the most space)
3. Compress only, without looking for duplicates
4. Neither (maximum performance, less space saved)

Enter your choice (1, 2, 3 or 4): 2

Choose compression:                                                                                          
1. Fast - LZ4, at the level Windows picks
2. Balanced - ZSTD, at the level Windows picks
3. Pick the format and level yourself

Enter your choice (1, 2 or 3): 3

Choose compression format:                                                                                   
1. LZ4: Fast compression with good balance of speed and compression ratio
2. ZSTD: Better compression ratio but uses more CPU

Enter your choice (1 or 2): 2

Choose the ZSTD compression level:                                                                           
ZSTD accepts levels 1 to 22.
Higher levels compress smaller and slower, and levels 20 and above can need noticeably more memory.
Decompression is the same speed whichever level you pick.

Enter a level, or press Enter for the level Windows picks: 2
Selected deduplication and ZSTD compression, level 2


===============================================================================
                        DEV DRIVE CREATION PLAN
===============================================================================

* Shrink Drive D (ALERT) by 199 GB to free up space
* Create 199 GB Dev Drive on Disk 1 (CT4000P3PSSD8) using ReFS
* Name the Dev Drive Projects
* Skip BitLocker encryption
* Enable ReFS deduplication and ZSTD compression, level 2
* Daily optimization : Monday-Friday at 11:00 and 17:00
* Weekly maintenance : Monday at 17:30, every 1 week
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

Dev Drive created at E:, named Projects.
Marking Dev Drive E: as trusted for Defender performance
Dev Drive E: reports itself trusted, which is the signal for Microsoft Defender to run in performance mode.
Skipping BitLocker encryption as requested.
Enabling ReFS mode DedupAndCompress for E:
Enabled ReFS mode: DedupAndCompress
Scheduling the daily job at 11:00 (2h)
Scheduling the daily job at 17:00 (2h)
Scheduled the daily jobs
E: confirms it: deduplication and ZSTD compression, level 2.
Scheduling deduplication scrub jobs
Scheduled weekly scrub job on Monday at 17:30
Configuring the ReFS optimization tasks to run only on AC power...
Successfully configured 1 ReFS optimization task(s) to run only on AC power

The ReFS optimization runs on a schedule kept in Task Scheduler, under:
  Task Scheduler Library > Microsoft > Windows > ReFsDedupSvc

Times just chosen: 11:00 and 17:00 daily, Monday at 17:30 weekly.

To change the times later, press Win+R, type taskschd.msc and press Ctrl+Shift+Enter to open
it as administrator, then open that folder and find the tasks whose Triggers column matches
the times above. Edit them on the Triggers tab. Leave the Actions tab alone - that is what
actually runs the optimization.

Other tasks in that folder may belong to Windows or to earlier runs.

Running the initial ReFS job for E:
Triggered the initial job: deduplication and ZSTD compression, level 2
All done. Dev Drive E: ready.
DriveLetter FriendlyName FileSystemType DriveType HealthStatus OperationalStatus SizeRemaining   Size
----------- ------------ -------------- --------- ------------ ----------------- -------------   ----
E           Projects     ReFS           Fixed     Healthy      OK                    196.25 GB 199 GB

```

## What It Does

### Interactive Dev Drive Creation Process:

1. **Creation Method Selection**
   - **Free Space Mode**: Uses unallocated space on a physical drive
   - **Shrink Mode**: Shrinks an existing logical drive to create space
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

4. **Name**
   - Asks what the volume should be called, with `DevDrive` on the Enter key, so two Dev Drives need not share a name
   - Asked before anything is created, and repeated in the plan, so the name is confirmed with everything else
   - Refuses a name longer than 32 characters, and one carrying a character Windows rejects in a file name. Both are caught at the prompt, not by `Format-Volume` once the partition exists
   - Neither rule is quoted from Microsoft, because neither is documented: `Format-Volume -NewFileSystemLabel` states no length, and no character list for a volume label could be found. The 32 is this script's own cap at the long-standing NTFS label length, and the character list stands in for one it cannot get
   - So the name is read back off the volume after formatting and reported. A volume that came out named something else is named, with the command to rename it; one that could not be read is said to be unconfirmed rather than reported as having no name

5. **Security Configuration**
   - Optional BitLocker encryption, enabled together with its recovery key in one step
   - The recovery key is printed and has to be acknowledged before the run continues
   - A password is asked for in virtual hard disk mode only, and asked for again if BitLocker rejects it
   - The domain account protector is added only on a machine joined to an Active Directory domain
   - The recovery key goes to Azure AD only on a device joined to Entra ID
   - Automatic unlocking is set only when the operating system drive is BitLocker-protected
   - The volume is then asked whether automatic unlocking really is on, rather than the call being taken at its word
   - Where automatic unlocking cannot be set up, the encryption is finished all the same: the run gives the reason in the words Windows used, and says the drive will need unlocking by hand after every restart
   - What the machine can actually do is checked before the plan is shown, and listed in it
   - A BitLocker failure offers a choice: retry, carry on without it, or stop - except a refusal by group policy, which is not offered a retry that would meet the same refusal

6. **Storage Optimization Setup**
   - Choose what happens to the data: deduplicate only, deduplicate and compress, compress only, or neither
   - Choose compression in one answer: LZ4 at Windows' own level, ZSTD at Windows' own level, or set both yourself
   - Setting them yourself asks for the format (LZ4 for speed, ZSTD for a better ratio) and then the level, where Enter still leaves it to Windows: LZ4 takes 1, or 3 to 12 where 3 and above use LZ4HC; ZSTD takes 1 to 22. The defaults are Microsoft's own and documented as subject to change, so an empty answer passes no level at all
   - Keep the suggested schedule, or set the fields yourself: the daily start times (comma separated, 24-hour HH:MM, up to four), and - where there is a weekly job - the weekly maintenance day and its start time
   - Each field takes Enter to keep the value shown; choosing your own times gets the result repeated back, taking the defaults does not
   - The daily job's days, its AC-power condition and, where they apply, its two-hour limit and 60% CPU share are fixed and are not asked about
   - **Compress only takes none of that**: Windows creates no weekly maintenance job for such a volume, refuses a CPU share for its daily job, and accepts a duration only to drop it. So the run asks for the daily times alone, promises neither limit, and says during creation that no weekly job is being made. The AC-power condition still applies
   - After the jobs are created the script asks the volume what it actually stored and prints that, rather than reporting success because no command failed. A setting that came back different is named, and the run carries on: the Dev Drive exists and works either way
   - After the jobs are created the script says where to change the times later, in Task Scheduler under Microsoft > Windows > ReFsDedupSvc
   - The daily jobs are automatically scheduled to run only on AC power

7. **Dev Drive Creation & Setup**
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

Instead of repartitioning a physical disk, this mode puts the Dev Drive inside a `.vhdx` file on a volume you already have. It is the same thing Windows Settings offers as **Create new VHD**, which is useful when the Settings app is not an option — for example on machines where elevation comes from a tool that cannot launch Settings elevated.

The script asks for four things:

- **Path** of the `.vhdx` file. The folder must already exist, the file must not, and the volume hosting it must be a fixed disk — Windows does not support a Dev Drive inside a `.vhdx` on a removable disk. A per-user directory keeps the Dev Drive from being shared unintentionally.
- **Disk type**. *Dynamically expanding* grows as data is written and is what Microsoft recommends. *Fixed size* claims the whole file up front, which takes minutes rather than seconds and cannot be interrupted once started.
- **Size**, at least 50 GB. That is Microsoft's documented minimum for any Dev Drive. For a fixed size disk the size cannot exceed the host volume's free space less 1 GB of head-room; for a dynamically expanding one a larger limit is allowed with a warning.
- **Automatic mounting** on startup.

The file is created and attached through `virtdisk.dll` directly, not with `diskpart` or `Mount-DiskImage`. The reason is automatic mounting, described below. Everything after that — ReFS formatting, the trusted flag, BitLocker, deduplication — is identical to the other two modes.

### Automatic mounting

A `.vhdx` attached the ordinary way does not survive a restart, and no PowerShell cmdlet can change that. Automatic mounting has to be requested when the disk is attached, by passing `ATTACH_VIRTUAL_DISK_FLAG_AT_BOOT` to [`AttachVirtualDisk`](https://learn.microsoft.com/en-us/windows/win32/api/virtdisk/nf-virtdisk-attachvirtualdisk). Neither `diskpart` nor `Mount-DiskImage` passes it; until now only the Windows Settings **Disks & volumes** page did, which is why a Dev Drive created there comes back after a restart and one created from a script does not.

The script calls that API itself. Windows then records the file under `HKLM\SYSTEM\CurrentControlSet\Control\AutoAttachVirtualDisks` on its own and reattaches it on every startup, with the same drive letter and its trusted Dev Drive status intact. That registry entry is Windows's own bookkeeping — writing it by hand does not enable anything.

Older Windows builds may reject the flag. If that happens the script says so, attaches the disk anyway, and you get a working Dev Drive that needs mounting by hand after each restart.

Whenever the disk will not be mounted for you — because Windows refused the flag, or because you declined automatic mounting — the script prints the command, once when the disk is attached and again at the end so it does not scroll away:

```powershell
Mount-DiskImage -ImagePath 'D:\DevDrive.vhdx' -StorageType VHDX -Access ReadWrite
```

Run it from a PowerShell started as administrator. Microsoft's [`Mount-DiskImage` reference](https://learn.microsoft.com/en-us/powershell/module/storage/mount-diskimage) states that mounting a virtual hard disk requires administrator privileges, unlike mounting an `.iso` file.

### Carrying the file to another machine

Microsoft's [Dev Drive documentation](https://learn.microsoft.com/en-us/windows/dev-drive/) advises against it: when a virtual hard disk is hosted on a fixed disk — which this mode requires — it is not recommended to copy it, move it to a different machine and carry on using it as a Dev Drive.

The reason is that the designation, trust status included, is stored per machine and does not travel with the file. Mounted somewhere else, the `.vhdx` comes up as an ordinary ReFS volume: every filter attaches and Microsoft Defender scans it synchronously. Nothing announces this — the drive works, it is simply slower than the one you left behind.

If you move it anyway, mount it on the new machine and mark it trusted there:

```powershell
fsutil devdrv trust /f D:
```

The script prints the same advice at the end of every run that creates a `.vhdx`.

### BitLocker inside a virtual hard disk

Microsoft's documentation states that a `.vhdx` is already covered by BitLocker on the volume that hosts it, and that enabling BitLocker on the mounted virtual disk is unnecessary. The script says so before asking, but leaves the choice to you.

### Deduplication inside a virtual hard disk

Deduplication works on the ReFS volume inside the file and frees space there as it does on a partition. The `.vhdx` file itself does **not** shrink — it keeps the largest size it has ever reached, and a deduplication run adds a little to it for its own bookkeeping.

Reclaiming that space on the host means compacting the file, and there are reports of data corruption when compacting a `.vhdx` whose contents are deduplicated. Do not run `compact vdisk` against a deduplicated Dev Drive without a backup.

## Security Notes

- Requires a complex password (8+ chars, upper/lower/digit/special) where one is asked for
- BitLocker recovery key printed for you to write down, and backed up to Azure AD on an Entra ID device
- On a device outside Entra ID the key exists only on the volume and on your paper copy, so keep it
- Auto-unlock enabled where Windows allows it, meaning the operating system drive is protected too; where it is not allowed, the drive has to be unlocked by hand after every restart
- Without an Active Directory domain the drive is still encrypted and still has its recovery key
- Drive marked as trusted for development workloads

## Scheduled Jobs

By default the script creates two daily deduplication jobs and one weekly maintenance job:
- 11:00 AM and 5:00 PM daily, Monday-Friday, **only on AC power** (2 hours duration, 60% CPU limit each)
- Monday at 5:30 PM weekly (maintenance pass, every week)

The daily start times, the weekly maintenance day and its start time are asked for during the run, so there is no need to edit the script to move them. Everything else about the jobs is fixed.

In compress-only mode there is no weekly maintenance job and no duration or CPU limit on the daily one: Windows refuses those settings on a volume that only compresses, and accepts a duration only to drop it. The run creates the daily jobs on AC power and says the weekly one is being skipped.

## Development

Run `install-hooks.cmd` once to turn on a tracked `git` pre-commit hook (`.githooks/pre-commit`). It runs the same three checks as `.github/workflows/ci.yml` against your working tree before each commit - parsing `dev_drive.ps1`, PSScriptAnalyzer with `PSScriptAnalyzerSettings.psd1`, and the Pester suite - and refuses the commit if any of them fails, saying which one and why. A single commit can still skip it with `git commit --no-verify`; to remove the hook entirely, run `git config --unset core.hooksPath`. Unlike CI, it uses whichever PSScriptAnalyzer/Pester versions are already installed locally rather than CI's pinned ones.

## Troubleshooting

- Ensure sufficient free space exists on the selected physical disk
- Run as Administrator
- Verify Azure AD connectivity for BitLocker backup
- Check Dev Drive support on your Windows version

More on Dev Drive at https://learn.microsoft.com/en-us/windows/dev-drive/
