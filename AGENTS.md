# AGENTS.md

## Never run `dev_drive.ps1`

It repartitions disks and formats volumes. Nothing in CI, in the pre-commit hook or in the test
suite executes it, and that is deliberate. Every storage, BitLocker and scheduling path is verified
by reasoning and by unit tests over its decision functions, never by running it.

## What this is

One interactive PowerShell script that creates a Windows 11 Dev Drive — from free space, by
shrinking a partition, or inside a `.vhdx` — then optionally sets up BitLocker, ReFS deduplication
and compression, and the recurring jobs. `dev_drive.ps1` is the whole product; `dev_drive.Tests.ps1`
is a Pester suite over it; `README.md` documents it for users.

Documentation on ReFS Deduplication/Optimization/Scrub: https://learn.microsoft.com/en-us/powershell/module/microsoft.refsdedup.commands/set-refsdedupschedule?view=windowsserver2025-ps

## The three checks

Run all three before saying anything is done. The pre-commit hook runs the same three, so a commit
fails on anything they catch.

```
pwsh -NoProfile -c "$e=$null; [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path ./dev_drive.ps1),[ref]$null,[ref]$e) | Out-Null; if($e){$e[0].Message}else{'parse OK'}"
pwsh -NoProfile -c "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"
.\run-tests.cmd
```

**The analyzer must be recursive.** `-Path ./dev_drive.ps1` misses findings in the test file, and the
hook does not.

## How the test suite reaches the code

It cannot dot-source the script, because running it starts asking questions. It lifts every function
out of the syntax tree instead, and sets `Set-StrictMode -Version Latest` to match the script.

Two consequences:

- **Only functions are testable.** Anything in the linear body can be pinned only by an assertion
  about the source text, and such an assertion is worth little unless it asserts order, count or
  adjacency. "Both strings appear somewhere in the file" proves nothing.
- **Keep decisions in pure functions** so they can be tested at all. A function that only decides
  what to say or what a typed answer means needs no mocks.

## Conventions the code follows

- **Verbs**: `Resolve-*` decides, `Request-*` asks the user, `Format-*` renders text, `Get-*`
  fetches, `Test-*` answers yes or no.
- **Comments**: about one line. Docstrings one to three. A comment states the constraint, not the
  obvious.
- **Never report success from an exit code alone.** Read the state back and report what it says: the
  BitLocker recovery key is read off the volume, the trusted designation off the volume's own flags,
  writability by writing a file, the deduplication settings with `Get-ReFSDedupSchedule`.
- **Never print a value the user did not choose.** A default assigned before a question is asked
  ends up displayed as a setting somebody made. Leave it unset.
- **Ask everything first, change nothing until the plan is confirmed.** The plan summary must say
  what will actually happen on this machine, not what usually happens.
- **A failure after the drive exists does not end the run silently.** Say what was created, what
  was left behind, and what a rerun would repeat.
- **`fsutil` and other native tools do not throw.** Take `$LASTEXITCODE` on the next line, before
  anything can overwrite it.
- **Native tools answer in the machine's language.** `fsutil` takes its strings from a message
  resource, so an English phrase cannot be matched on a localized Windows: report what it said
  rather than judging it. Values from .NET are safe — enum member names are compiled identifiers —
  but rendering any value to text uses the machine's regional settings.
- **The Dev Drive designation is the exception, because it is not text.** `FSCTL_QUERY_PERSISTENT_VOLUME_STATE`
  answers `PERSISTENT_VOLUME_STATE_DEV_VOLUME` and `PERSISTENT_VOLUME_STATE_TRUSTED_VOLUME`, which
  follow `fsutil devdrv trust` and `untrust` exactly and read the same in every language. `fsutil`
  output is read only where that call itself fails. Its exit code is worthless: `fsutil devdrv query`
  exits 0 for a trusted volume, an untrusted one and plain NTFS alike.
- **A ReFS deduplication task is named after its volume.** `Set-ReFSDedupSchedule` registers it under
  `\Microsoft\Windows\ReFsDedupSvc\` as the volume's `UniqueId` GUID, braced and upper case; the scrub
  task adds `-Scrub`. Measured on three volumes across separate disks, one of them on an MBR disk.
  Take the GUID from `Get-Volume`, never from `Get-Partition`: a partition on an MBR disk has no GUID
  of its own, while its volume does. Never identify a task by its display name, its trigger times, or
  a before-and-after listing of the folder. That folder keeps the tasks of volumes that no longer exist.
- **Two storage facts the documentation does not state, both measured.** `Get-PartitionSupportedSize`
  reports `SizeMax` as the partition's size **plus the contiguous unallocated run right behind it**, so
  a shrink target taken from it gives up less than was asked, or nothing. And
  `New-Partition -UseMaximumSize` creates the largest partition on the **whole disk**, not one in the
  space just freed, so a shrink can leave that space unused. Place such a partition with an explicit
  `-Offset` and `-Size` — and align the offset up to a whole megabyte first: any other offset is
  refused outright, and `Resize-Partition` aligns to the cluster, landing a few hundred bytes off.
- **English in the repository**, in code, comments, documentation and commit messages.

## Line endings

`.gitattributes` requires CRLF for `.ps1` and `.cmd`. Several editors and shell tools here write LF,
which leaves the working copy inconsistent with what git checks out. Normalise before committing:

```
pwsh -NoProfile -c "foreach ($f in 'dev_drive.ps1','dev_drive.Tests.ps1') { $p = Join-Path $PWD $f; $t = [IO.File]::ReadAllText($p); [IO.File]::WriteAllText($p, (($t -replace \"`r`n\", \"`n\") -replace \"`n\", \"`r`n\"), (New-Object Text.UTF8Encoding($false))) }"
```

## Git and pull requests

- One branch per issue, named `bugfix/<issue number>`, and one pull request per branch.
- **Write pull request and issue bodies to a file and pass `--body-file`.** A backtick in `--body`
  breaks the shell, and PowerShell examples are full of them.
- **`gh pr edit` fails on this repository** — the token lacks the scopes its query needs. Edit
  through the API instead: `gh api repos/ALERTua/dev_drive_creation/pulls/<n> -X PATCH --input body.json`.
- **CI runs on pull requests targeting `main`, and on pushes to `main`.** A pull request retargeted
  automatically after a dependency merges does not re-trigger it; closing and reopening does.
- **Closing keywords are read from commit messages too**, and negation is ignored. "does not close
  #32" still links it. Check with `gh pr view <n> --json closingIssuesReferences`.
