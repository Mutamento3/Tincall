#Requires -Version 5.1
# Task Scheduler runs this wrapper for the current user. It waits for the child
# and returns its exit code, allowing the task's restart policy to work.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PrivateDirectory,
    [Parameter(Mandatory=$true)][ValidateSet('connector', 'tunnel')][string]$Kind
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$statePath = Join-Path $PrivateDirectory ($Kind + '.process.json')
$process = $null
try {
    $config = [IO.File]::ReadAllText((Join-Path $PrivateDirectory 'windows-services.json')) | ConvertFrom-Json
    $service = $config.$Kind
    # Start-Process joins ArgumentList; quote each argument for Windows argv.
    $arguments = foreach ($argument in $service.Arguments) {
        $escaped = [regex]::Replace([string]$argument, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        '"' + $escaped + '"'
    }
    $stdoutPath = Join-Path $PrivateDirectory ($Kind + '.stdout.log')
    $stderrPath = Join-Path $PrivateDirectory ($Kind + '.stderr.log')
    $process = Start-Process -FilePath $service.Executable -ArgumentList ($arguments -join ' ') -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $null = $process.Handle
    $state = @{ ProcessId = $process.Id; StartedTicks = $process.StartTime.ToUniversalTime().Ticks.ToString(); Executable = $process.Path }
    [IO.File]::WriteAllText($statePath, (ConvertTo-Json -InputObject $state), ([Text.UTF8Encoding]::new($false)))
    $process.WaitForExit()
    $code = $process.ExitCode
    if ($null -eq $code) { $code = 1 }
    exit $code
} catch {
    # If recording the child fails, do not leave an untracked child behind.
    if ($process -and -not $process.HasExited) {
        $ErrorActionPreference = 'Continue'
        & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID $process.Id /T /F > $null 2> $null
    }
    [IO.File]::AppendAllText((Join-Path $PrivateDirectory ($Kind + '.stderr.log')), "tincall_windows_service_failed`r`n")
    exit 1
} finally {
    if ($process) {
        if ($process.HasExited -and (Test-Path -LiteralPath $statePath)) { Remove-Item -LiteralPath $statePath -Force }
        $process.Dispose()
    }
}
