# Windows 11 Dev Drive Creation Script

A PowerShell script that automates the creation of Windows Dev Drives from existing free space on physical drives, with BitLocker encryption and ReFS deduplication/compression.

## Features

- Uses existing free space on physical drives (no partition shrinking required)
- Creates new ReFS-formatted Dev Drive
- Enables BitLocker encryption with Azure AD backup
- Configures ReFS deduplication and compression
- Sets up automated optimization schedules
- Marks drive as trusted for Windows Defender performance

## Requirements

- Windows 11 (Dev Drive support)
- Administrator privileges
- Azure AD-joined device (for BitLocker key backup)
- PowerShell 5.1 or later

## Basic Usage

### Interactive Mode (Recommended)
```powershell
.\dev_drive.ps1 -Interactive
```
This will show you all available drives and guide you through the selection process.

### Direct Usage

**Using Free Space:**
```powershell
.\dev_drive.ps1 -DiskNumber 0 -SizeGB 100
```

**Shrinking Existing Drive:**
```powershell
.\dev_drive.ps1 -DriveLetter C -ShrinkGB 100
```

### Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `Interactive` | Switch | No | False | Show interactive drive selection menu |
| `DiskNumber` | Int | Yes* | - | Physical disk number (0, 1, 2, etc.) for free space mode |
| `SizeGB` | Int | Yes* | - | Size in GB for the new Dev Drive (free space mode) |
| `DriveLetter` | String | Yes* | - | Drive letter to shrink (A-Z) for shrink mode |
| `ShrinkGB` | Int | Yes* | - | Amount in GB to shrink (shrink mode) |
| `SkipBitLocker` | Switch | No | False | Skip BitLocker encryption setup |
| `DedupMode` | String | No | Dedup | Dedup, Compress, or DedupAndCompress |
| `CompressionFormat` | String | No | LZ4 | LZ4 or ZSTD |
| `CompressionLevel` | Int | No | 5 | Compression level 1-9 (ZSTD only) |
| `RunInitialJob` | Bool | No | True | Run initial optimization immediately |
| `Debug` | Switch | No | False | Enable debug mode with pauses |

*Required for respective modes or use -Interactive

### Examples

**Interactive mode (shows drive selection):**
```powershell
.\dev_drive.ps1 -Interactive
```

**Free space mode:**
```powershell
.\dev_drive.ps1 -DiskNumber 0 -SizeGB 500
```

**Shrink mode:**
```powershell
.\dev_drive.ps1 -DriveLetter C -ShrinkGB 500
```

**With custom compression:**
```powershell
.\dev_drive.ps1 -DiskNumber 0 -SizeGB 500 -CompressionFormat ZSTD -CompressionLevel 7
```

**Skip BitLocker encryption:**
```powershell
.\dev_drive.ps1 -DiskNumber 0 -SizeGB 500 -SkipBitLocker
```

**Debug mode:**
```powershell
.\dev_drive.ps1 -DiskNumber 0 -SizeGB 500 -Debug
```

## What It Does

### Free Space Mode:
1. **Drive Analysis**: Shows detailed information about all physical drives and logical volumes
2. **Free Space Detection**: Checks available free space on the selected physical disk
3. **Dev Drive Creation**: Creates new ReFS partition from existing free space
4. **BitLocker Setup**: Enables encryption with strong password and Azure AD backup
5. **Optimization**: Configures deduplication/compression with scheduled jobs
6. **Security**: Marks drive as trusted for Defender performance

### Shrink Mode:
1. **Partition Analysis**: Analyzes the selected drive's current size and available shrink space
2. **Partition Shrinking**: Reduces the size of the selected logical drive
3. **Dev Drive Creation**: Creates new ReFS partition from the freed space
4. **BitLocker Setup**: Enables encryption with strong password and Azure AD backup
5. **Optimization**: Configures deduplication/compression with scheduled jobs
6. **Security**: Marks drive as trusted for Defender performance

### Interactive Mode:
- Displays comprehensive drive information for informed decision making
- Guides users through the selection process with clear prompts
- Validates user input and provides helpful error messages
- Supports both free space and shrink creation methods

## Security Notes

- Requires complex password (8+ chars, upper/lower/digit/special)
- BitLocker recovery key backed up to Azure AD
- Auto-unlock enabled for convenience
- Drive marked as trusted for development workloads

## Scheduled Jobs

The script creates two daily deduplication jobs:
- 11:00 AM (2 hours duration)
- 5:00 PM (2 hours duration)

Jobs run Monday-Friday with 60% CPU limit.

## Troubleshooting

- Ensure sufficient free space exists on the selected physical disk
- Run as Administrator
- Verify Azure AD connectivity for BitLocker backup
- Check Dev Drive support on your Windows version
- Use `Get-Disk` in PowerShell to identify the correct disk number

More on Dev Drive at https://learn.microsoft.com/en-us/windows/dev-drive/
