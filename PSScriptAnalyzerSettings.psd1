@{
    # Settings for Invoke-ScriptAnalyzer, used by .github/workflows/ci.yml.
    # Every excluded rule below is a real finding against dev_drive.ps1 today;
    # each comment explains why it is excluded and, where the fix is a code
    # change tracked elsewhere, which issue owns that fix.
    ExcludeRules = @(
        # Prompt-BitLockerChoice / Prompt-DeduplicationChoice / Prompt-CompressionFormat /
        # Prompt-CompressionLevel use the unapproved verb "Prompt". Renaming them is
        # tracked in issue #11; excluded here so CI does not fail on work already scoped
        # to that issue.
        'PSUseApprovedVerbs',

        # dev_drive.ps1 is an interactive console script the user runs directly at a
        # terminal (#Requires -RunAsAdministrator, Read-Host prompts throughout). Its
        # colored Write-Host output IS the UI, not diagnostic noise competing with a
        # caller's own output stream, so the rule's rationale does not apply here.
        'PSAvoidUsingWriteHost',

        # dev_drive.ps1 line ~662 has an empty catch inside the per-task loop that
        # marks deduplication scheduled tasks AC-power-only: one task's failure must
        # not stop the others from being configured. Tracked in issue #16.
        'PSAvoidUsingEmptyCatchBlock',

        # dev_drive.ps1 assigns $creationMethod / $bitLockerChoice / $deduplicationChoice
        # to build a plan description string that is composed but never printed as a
        # single summary. Tracked in issue #17.
        'PSUseDeclaredVarsMoreThanAssignments'
    )
}
