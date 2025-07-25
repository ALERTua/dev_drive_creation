# Windows 11 Dev Drive Creation Script

A PowerShell script that automates the creation of Windows Dev Drives with BitLocker encryption and ReFS deduplication/compression.

## Features

- Shrinks existing drive partition to create space
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

```powershell
.\dev_drive.ps1 -DriveLetter C -ShrinkGB 100
```

### Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `DriveLetter` | String | Yes | - | Drive to shrink (A-Z) |
| `ShrinkGB` | Int | Yes | - | Amount in GB to shrink |
| `DedupMode` | String | No | DedupAndCompress | Dedup, Compress, or DedupAndCompress |
| `CompressionFormat` | String | No | LZ4 | LZ4 or ZSTD |
| `CompressionLevel` | Int | No | 5 | Compression level 1-9 (ZSTD only) |
| `RunInitialJob` | Bool | No | True | Run initial optimization immediately |
| `Debug` | Switch | No | False | Enable debug mode with pauses |

### Examples

Basic usage:
```powershell
.\dev_drive.ps1 -DriveLetter C -ShrinkGB 500
```

With custom compression:
```powershell
.\dev_drive.ps1 -DriveLetter C -ShrinkGB 500 -CompressionFormat ZSTD -CompressionLevel 7
```

Debug mode:
```powershell
.\dev_drive.ps1 -DriveLetter C -ShrinkGB 500 -Debug
```

## What It Does

1. **Partition Management**: Shrinks specified drive by requested amount
2. **Dev Drive Creation**: Creates new ReFS partition with Dev Drive features
3. **BitLocker Setup**: Enables encryption with strong password and Azure AD backup
4. **Optimization**: Configures deduplication/compression with scheduled jobs
5. **Security**: Marks drive as trusted for Defender performance

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

- Ensure sufficient free space before shrinking
- Run as Administrator
- Verify Azure AD connectivity for BitLocker backup
- Check Dev Drive support on your Windows version
