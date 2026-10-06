#!/bin/bash

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if ! command -v pwsh >/dev/null 2>&1; then
    echo "SKIP: pwsh not installed; Windows Codex alert tests require PowerShell"
    exit 0
fi

ps_script="$(mktemp)"
trap 'rm -f "$ps_script"' EXIT
cat > "$ps_script" <<'EOF'
param([string]$InstallerPath)
$ErrorActionPreference = "Stop"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("code-notify-codex-" + [guid]::NewGuid())
try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $env:USERPROFILE = $testRoot
    $env:CLAUDE_HOME = $null
    $env:OPENCODE = $null
    $env:OPENCODE_PID = $null
    $content = Get-Content -Raw $InstallerPath
    if ($content -notmatch '(?ms)\$mainScript = @''\r?\n(?<module>.*?)\r?\n''@') { throw "module missing" }
    $moduleScript = $Matches['module'] -replace '(?ms)\r?\nExport-ModuleMember -Function @\(.*?\)\s*$', ''
    Invoke-Expression $moduleScript
    if ($content -notmatch '(?ms)\$notifyScript = @''\r?\n(?<notify>.*?)\r?\n''@') { throw "notifier missing" }
    $notify = $Matches['notify']
    # Parse the entire generated notifier, then exercise routing without using
    # Windows toast APIs or sending real notifications.
    $parseErrors = $null
    $tokens = $null
    [void][Management.Automation.Language.Parser]::ParseInput($notify, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "notifier parse error: $parseErrors" }
    $routingPath = Join-Path $testRoot "routing.ps1"
    ($notify.Substring(0, $notify.IndexOf('# StopFailure fires')) + [Environment]::NewLine + 'Write-Output "deliver:$HookType"') | Set-Content $routingPath -Encoding UTF8
    $pwsh = (Get-Process -Id $PID).Path

    New-Item -ItemType Directory -Path $script:CodexHome, $script:NotificationsDir -Force | Out-Null
    $userHook = [pscustomobject]@{type = "command"; command = "user-approval-hook"; timeout = 123}
    $legacy = "powershell -File C:\old\notify.ps1 notification codex"
    $fixture = [pscustomobject]@{theme = "dark"; hooks = [pscustomobject]@{
        Stop = @([pscustomobject]@{hooks = @([pscustomobject]@{type = "command"; command = "user-stop-hook"})})
        PermissionRequest = @([pscustomobject]@{matcher = "Bash"; hooks = @([pscustomobject]@{type = "command"; command = $legacy}, $userHook)})
    }}
    $fixture | ConvertTo-Json -Depth 20 | Set-Content $script:CodexHooksFile
    if (-not (Update-CodexHooksFile -Path $script:CodexHooksFile -NotifyScript (Get-NotifyScript))) { throw "enable failed" }
    $settings = Get-Content $script:CodexHooksFile -Raw | ConvertFrom-Json
    $command = Get-CodexPermissionCommand -NotifyScript (Get-NotifyScript)
    if ($settings.theme -ne "dark") { throw "user settings lost" }
    if (-not (Test-HookEntriesContainCommand -Entries @($settings.hooks.PermissionRequest) -Matcher "Bash" -Command $userHook.command)) { throw "mixed user hook lost" }
    if (-not (Test-HookEntriesContainCommand -Entries @($settings.hooks.PermissionRequest) -Matcher "*" -Command $command)) { throw "stable dispatcher missing by default" }
    $originalHooks = Get-Content $script:CodexHooksFile -Raw
    $early = '{"hook_event_name":"PermissionRequest","autoAccepted":true}'
    $out = $early | & $pwsh -NoProfile -File $routingPath ApprovalRequest codex
    if ($LASTEXITCODE -ne 0 -or $out) { throw "early request notified by default" }

    Invoke-CodeNotify alerts add approval-request
    if (-not (Test-NotifyTypeEnabled approval_request)) { throw "opt-in not enabled" }
    if ((Get-Content $script:CodexHooksFile -Raw) -ne $originalHooks) { throw "live toggle rewrote hooks" }
    $out = $early | & $pwsh -NoProfile -File $routingPath ApprovalRequest codex
    if ($out -ne "deliver:ApprovalRequest") { throw "early opt-in did not route" }
    $out = $early | & $pwsh -NoProfile -File $routingPath notification codex
    if ($out -ne "deliver:ApprovalRequest") { throw "legacy dispatcher not retained" }

    Invoke-CodeNotify alerts remove approval_request
    $out = $early | & $pwsh -NoProfile -File $routingPath notification codex
    if ($out) { throw "removing opt-in did not take effect" }
    if ((Get-Content $script:CodexHooksFile -Raw) -ne $originalHooks) { throw "remove rewrote hooks" }

    # Upgrade an enabled install through the alert command rather than cn on.
    $settings.hooks.PermissionRequest = @($settings.hooks.PermissionRequest | Where-Object { $_.matcher -eq "Bash" })
    $settings | ConvertTo-Json -Depth 20 | Set-Content $script:CodexHooksFile
    Invoke-CodeNotify alerts add approval_request
    $settings = Get-Content $script:CodexHooksFile -Raw | ConvertFrom-Json
    if (-not (Test-HookEntriesContainCommand -Entries @($settings.hooks.PermissionRequest) -Matcher "*" -Command $command)) { throw "old install not upgraded" }
    if ($settings.theme -ne "dark" -or $settings.hooks.PermissionRequest[0].hooks[0].timeout -ne 123) { throw "upgrade lost user settings" }
    Invoke-CodeNotify alerts reset
    if (Test-NotifyTypeEnabled approval_request) { throw "reset retained opt-in" }

    if (-not (Update-CodexHooksFile -Path $script:CodexHooksFile -NotifyScript (Get-NotifyScript) -Disable)) { throw "disable failed" }
    Invoke-CodeNotify alerts add approval_request
    if (Test-NotificationsEnabled codex) { throw "changing alert re-enabled disabled tool" }
    $out = $early | & $pwsh -NoProfile -File $routingPath ApprovalRequest codex
    if ($out) { throw "stale hook bypassed cn off codex" }
    $settings = Get-Content $script:CodexHooksFile -Raw | ConvertFrom-Json
    if ($settings.hooks.PermissionRequest[0].hooks[0].command -ne $userHook.command) { throw "disable removed user hook" }
    Write-Host "PASS: Windows Codex opt-in, live changes, upgrade and user configuration preservation"
} finally {
    Remove-Item -Recurse -Force $testRoot -ErrorAction SilentlyContinue
}
EOF
pwsh -NoProfile -File "$ps_script" -InstallerPath "$SCRIPT_DIR/../scripts/install-windows.ps1"
