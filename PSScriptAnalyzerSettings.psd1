@{
    # Settings for Invoke-ScriptAnalyzer, used by .github/workflows/ci.yml.
    # Every excluded rule below is a real finding against dev_drive.ps1 today;
    # each comment explains why it is excluded and, where the fix is a code
    # change tracked elsewhere, which issue owns that fix.
    ExcludeRules = @(
        # dev_drive.ps1 is an interactive console script the user runs directly at a
        # terminal (#Requires -RunAsAdministrator, Read-Host prompts throughout). Its
        # colored Write-Host output IS the UI, not diagnostic noise competing with a
        # caller's own output stream, so the rule's rationale does not apply here.
        'PSAvoidUsingWriteHost',

        # New-VirtualDiskFile creates a .vhdx, which the rule wants guarded by ShouldProcess.
        # The script asks for confirmation once, before any of its steps run; wiring -WhatIf
        # and -Confirm through every destructive call is tracked in issue #13.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
