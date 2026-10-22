# SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
# SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Docker,
    [switch]$Node,
    [switch]$Tunnel,
    [switch]$Stop
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-PrivateText([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, ([Text.UTF8Encoding]::new($false)))
}

function Protect-PrivatePath([string]$Path, [switch]$Directory) {
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw '私密目录和配置不能使用符号链接或目录联接。'
    }
    if ($Directory) {
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
        $acl = [Security.AccessControl.FileSecurity]::new()
        $inherit = [Security.AccessControl.InheritanceFlags]::None
    }
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($script:UserSid)
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $script:UserSid, [Security.AccessControl.FileSystemRights]::FullControl,
        $inherit, [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function New-RandomHex([int]$ByteCount) {
    $bytes = New-Object byte[] $ByteCount
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
}

function Test-NodeSQLite([string]$Executable, [string[]]$Flags) {
    # Windows PowerShell treats native stderr as error records, even on success.
    $ErrorActionPreference = 'Continue'
    $probe = "const [a,b]=process.versions.node.split('.').map(Number);if(a<22||(a===22&&b<5))process.exit(1);const db=new(require('node:sqlite').DatabaseSync)(':memory:');db.prepare('SELECT 1').get();db.close();"
    & $Executable @Flags -e $probe > $null 2> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-DockerCompose {
    $ErrorActionPreference = 'Continue'
    if (-not $script:DockerExecutable) { return $false }
    & $script:DockerExecutable compose version > $null 2> $null
    return ($LASTEXITCODE -eq 0)
}

function Require-Docker {
    if (-not (Test-DockerCompose)) {
        throw 'Docker 方式需要 Docker Desktop 和 Compose。请从 https://www.docker.com/products/docker-desktop/ 安装并启动，或安装 Node 后使用 -Node。'
    }
    $ErrorActionPreference = 'Continue'
    & $script:DockerExecutable info > $null 2> $null
    if ($LASTEXITCODE -ne 0) { throw '无法连接 Docker Desktop，请先启动它并切换到 Linux 容器。' }
}

function Invoke-Compose([string[]]$ComposeArguments) {
    $ErrorActionPreference = 'Continue'
    & $script:DockerExecutable compose --project-name tincall-local --project-directory $script:SourceDirectory --env-file $script:EnvPath -f $script:ComposePath @ComposeArguments
    if ($LASTEXITCODE -ne 0) { throw 'Docker Compose 执行失败；配置和数据均已保留，请检查上方错误后重试。' }
}

function Read-SharedLog([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = [IO.StreamReader]::new($stream)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Stop-NodeTasks {
    # Disable restart before stopping children. Match PID, executable and start
    # time so that a stale runtime file cannot kill an unrelated process.
    foreach ($kind in @('tunnel', 'connector')) {
        $taskName = 'Tincall-{0}-{1}' -f $kind, $script:UserSid.Value
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) { Disable-ScheduledTask -InputObject $task | Out-Null }
        $statePath = Join-Path $script:PrivateDirectory ($kind + '.process.json')
        if (Test-Path -LiteralPath $statePath) {
            $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
            $serviceProcessId = [int]$state.ProcessId
            if ($serviceProcessId -le 1) { throw '进程记录无效，请检查私密目录中的 process.json 文件。' }
            $process = Get-Process -Id $serviceProcessId -ErrorAction SilentlyContinue
            if ($process) {
                try {
                    $sameProcess = ($process.StartTime.ToUniversalTime().Ticks.ToString() -eq [string]$state.StartedTicks) -and
                        ($process.Path -eq [string]$state.Executable)
                    # Retain a handle to this process while checking its identity.
                    $null = $process.Handle
                    if ($sameProcess) {
                        $ErrorActionPreference = 'Continue'
                        & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID $serviceProcessId /T /F > $null 2> $null
                        $killExit = $LASTEXITCODE
                        $ErrorActionPreference = 'Stop'
                        if ($killExit -ne 0 -and -not $process.HasExited) { throw '无法停止本安装的进程，请检查当前用户权限后重试。' }
                        $process.WaitForExit()
                    } else {
                        Write-Warning '旧 pid 已被其他进程复用，未终止该进程。'
                    }
                } finally { $process.Dispose() }
            }
            Remove-Item -LiteralPath $statePath -Force
        }
        if ($task) {
            $currentTask = Get-ScheduledTask -TaskName $taskName
            if ($currentTask.State -in @('Running', 'Queued')) { Stop-ScheduledTask -InputObject $currentTask }
            Unregister-ScheduledTask -InputObject $currentTask -Confirm:$false
        }
    }
    foreach ($name in @('serve.pid', 'tunnel.pid')) {
        $path = Join-Path $script:PrivateDirectory $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}

function Start-NodeTask([string]$Kind) {
    $taskName = 'Tincall-{0}-{1}' -f $Kind, $script:UserSid.Value
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -PrivateDirectory "{1}" -Kind {2}' -f $script:RunnerPath, $script:PrivateDirectory, $Kind
    $action = New-ScheduledTaskAction -Execute $script:PowerShellExecutable -Argument $arguments -WorkingDirectory $script:SourceDirectory
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $script:UserName
    $principal = New-ScheduledTaskPrincipal -UserId $script:UserName -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $definition = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings
    Register-ScheduledTask -TaskName $taskName -InputObject $definition -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw '此脚本仅供 Windows 使用；macOS／Linux 请使用 install-local.sh。' }
    if ($Node -and $Docker) { throw '-Node 与 -Docker 只能选择一个。' }
    if ($Stop -and $Tunnel) { throw '-Stop 与 -Tunnel 不能同时使用。' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $script:UserSid = $identity.User
    $script:UserName = $identity.Name
    $script:SourceDirectory = $PSScriptRoot
    $script:RunnerPath = Join-Path $PSScriptRoot 'run-local-windows.ps1'
    $helperPath = Join-Path $PSScriptRoot 'local-service.mjs'
    $script:ComposePath = Join-Path $PSScriptRoot 'docker-compose.yml'
    if (-not $env:LOCALAPPDATA) { throw '未找到 LOCALAPPDATA，无法确定当前用户的私密配置目录。' }
    $script:PrivateDirectory = Join-Path $env:LOCALAPPDATA 'Tincall'
    $script:EnvPath = Join-Path $script:PrivateDirectory 'local.env'
    $backendPath = Join-Path $script:PrivateDirectory 'backend'
    $configPath = Join-Path $script:PrivateDirectory 'windows-services.json'
    $dockerCommand = Get-Command docker.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $script:DockerExecutable = if ($dockerCommand) { $dockerCommand.Source } else { $null }
    $script:PowerShellExecutable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $env:TINCALL_LOCAL_ENV_FILE = $script:EnvPath.Replace('\', '/')
    $previous = ''
    if (Test-Path -LiteralPath $script:PrivateDirectory) {
        Protect-PrivatePath $script:PrivateDirectory -Directory
        foreach ($path in @($script:EnvPath, $backendPath, $configPath)) {
            if (Test-Path -LiteralPath $path) { Protect-PrivatePath $path }
        }
        if (Test-Path -LiteralPath $backendPath) { $previous = [IO.File]::ReadAllText($backendPath).Trim() }
    }
    if ($previous -notin @('', 'node', 'docker')) { throw '运行方式记录无效，请检查私密目录中的 backend 文件。' }
    if ($Stop) {
        if ($previous -eq 'docker' -and (Test-Path -LiteralPath $script:EnvPath)) {
            Require-Docker
            Invoke-Compose @('--profile', 'tunnel', 'stop')
        }
        Stop-NodeTasks
        Write-Host '连接端和隧道已停止，计划任务已删除；令牌、数据库和媒体数据均已保留。'
        exit 0
    }

    $nodeExecutable = $null
    $sqliteFlags = @()
    $nodeCommand = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($nodeCommand) {
        if (Test-NodeSQLite $nodeCommand.Source @()) { $nodeExecutable = $nodeCommand.Source }
        elseif (Test-NodeSQLite $nodeCommand.Source @('--experimental-sqlite')) {
            $nodeExecutable = $nodeCommand.Source
            $sqliteFlags = @('--experimental-sqlite')
        }
    }
    $mode = if ($Docker) { 'docker' } elseif ($Node) { 'node' } elseif ($previous) { $previous } elseif ($nodeExecutable) { 'node' } elseif (Test-DockerCompose) { 'docker' } else { '' }
    if (-not $mode) { throw '未找到可用的 Node 或 Docker Desktop。推荐从 https://nodejs.org/ 安装 Node LTS（至少 22.5，且支持 node:sqlite）后重试；无需 Docker 或 npm 依赖。' }
    if ($previous -and $previous -ne $mode) { throw '已有安装使用另一种方式。为避免切换到空数据库，请先停止并迁移完整 SQLite 数据和媒体，再调整 backend 记录；脚本不会自动迁移或删除数据。' }
    if ($mode -eq 'node' -and -not $nodeExecutable) { throw 'Node 方式需要 Node 22.5 以上且 node:sqlite 可用。请从 https://nodejs.org/ 安装 Node LTS 后重试。' }
    if ($mode -eq 'docker') { Require-Docker }

    if (-not (Test-Path -LiteralPath $script:PrivateDirectory)) { New-Item -ItemType Directory -Path $script:PrivateDirectory | Out-Null }
    Protect-PrivatePath $script:PrivateDirectory -Directory
    if (-not (Test-Path -LiteralPath $script:EnvPath)) {
        $phoneToken = New-RandomHex 32
        $workerToken = New-RandomHex 32
        $ownerRaw = New-RandomHex 16
        $owner = '{0}-{1}-4{2}-8{3}-{4}' -f $ownerRaw.Substring(0,8), $ownerRaw.Substring(8,4), $ownerRaw.Substring(13,3), $ownerRaw.Substring(17,3), $ownerRaw.Substring(20,12)
        $lines = @('TINCALL_LOCAL_PORT=8787', "TINCALL_LOCAL_PHONE_TOKEN=$phoneToken",
            ('TINCALL_CLIENTS=[{{"token":"{0}","owner_id":"{1}"}}]' -f $phoneToken, $owner),
            "TINCALL_WORKER_TOKEN=$workerToken", 'TINCALL_BINDINGS=[]', 'TINCALL_ALLOWED_ORIGINS=[]')
        $temporary = Join-Path $script:PrivateDirectory ('local.env.' + [guid]::NewGuid().ToString('N'))
        try {
            Write-PrivateText $temporary (($lines -join "`n") + "`n")
            # File.Move without overwrite publishes atomically, like the sh installer.
            [IO.File]::Move($temporary, $script:EnvPath)
        } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
    } else { Write-Host '复用已有私密配置，保留令牌和数据。' }
    Protect-PrivatePath $script:EnvPath
    Write-PrivateText $backendPath ($mode + "`n")
    $envValues = @{}
    foreach ($line in [IO.File]::ReadAllLines($script:EnvPath)) {
        if ($line -match '^([A-Z_]+)=(.*)$') { $envValues[$Matches[1]] = $Matches[2] }
    }
    $phoneToken = [string]$envValues['TINCALL_LOCAL_PHONE_TOKEN']
    if ($phoneToken -cnotmatch '^[0-9a-f]{64}$') { throw '手机令牌配置不完整，请检查原私密文件，不要删除或重建令牌。' }
    $portText = if ($env:TINCALL_LOCAL_PORT) { $env:TINCALL_LOCAL_PORT } else { [string]$envValues['TINCALL_LOCAL_PORT'] }
    $localPort = 0
    if ($portText -notmatch '^\d{1,5}$' -or -not [int]::TryParse($portText, [ref]$localPort) -or $localPort -lt 1 -or $localPort -gt 65535) { throw '端口必须是 1 至 65535 的整数。' }
    $env:TINCALL_LOCAL_PORT = [string]$localPort
    $url = 'http://127.0.0.1:' + $localPort
    $useTunnel = [bool]$Tunnel

    if ($mode -eq 'node') {
        $cloudflared = $null
        if ($useTunnel) {
            $cloudCommand = Get-Command cloudflared.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cloudCommand) { $cloudflared = $cloudCommand.Source }
            else {
                Write-Host '未找到 cloudflared.exe，已跳过隧道。请按 https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/downloads/ 安装后重新运行 -Tunnel；本脚本不会安装软件。'
                $useTunnel = $false
            }
        }
        Stop-NodeTasks
        $services = @{ connector = @{ Executable = $nodeExecutable; Arguments = @($sqliteFlags) + @($helperPath, 'serve', $script:PrivateDirectory, [string]$localPort) } }
        if ($useTunnel) {
            $services.tunnel = @{ Executable = $cloudflared; Arguments = @('tunnel', '--no-autoupdate', '--protocol', 'http2', '--url', $url) }
        }
        Write-PrivateText $configPath (ConvertTo-Json -InputObject $services -Depth 5)
        # Clear old URLs before the new asynchronous task has a chance to start.
        foreach ($kind in @($services.Keys)) {
            foreach ($stream in @('stdout', 'stderr')) {
                Write-PrivateText (Join-Path $script:PrivateDirectory ("$kind.$stream.log")) ''
            }
        }
        Start-NodeTask 'connector'
        if ($useTunnel) { Start-NodeTask 'tunnel' }
        $ready = $false
        for ($attempt = 0; $attempt -lt 15; $attempt++) {
            try {
                $response = Invoke-WebRequest -Uri ($url + '/capabilities') -Headers @{ Authorization = 'Bearer ' + $phoneToken } -UseBasicParsing -TimeoutSec 2
                if ($response.StatusCode -eq 200) { $ready = $true; break }
            } catch { }
            Start-Sleep -Seconds 2
        }
        if (-not $ready) { throw ('连接端未通过启动检查，请查看 {0}\connector.stderr.log 和任务计划程序；令牌和数据已保留。' -f $script:PrivateDirectory) }
        Write-Host '已使用当前用户的计划任务后台运行：登录时自动启动，失败后每分钟重试（最多 999 次），无需管理员权限。'
        Write-Host ('Node 数据和日志目录：{0}' -f $script:PrivateDirectory)
    } else {
        if ($useTunnel) { Invoke-Compose @('--profile', 'tunnel', 'up', '-d', '--build', '--force-recreate', '--wait', '--wait-timeout', '90') }
        else {
            Invoke-Compose @('--profile', 'tunnel', 'stop', 'cloudflared')
            Invoke-Compose @('up', '-d', '--build', '--force-recreate', '--wait', '--wait-timeout', '90', 'connector')
        }
    }
    if ($useTunnel) {
        $url = ''
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            if ($mode -eq 'node') {
                $logs = ''
                foreach ($name in @('tunnel.stdout.log', 'tunnel.stderr.log')) {
                    $logPath = Join-Path $script:PrivateDirectory $name
                    if (Test-Path -LiteralPath $logPath) { $logs += Read-SharedLog $logPath }
                }
            } else { $logs = (Invoke-Compose @('--profile', 'tunnel', 'logs', '--no-color', 'cloudflared')) -join "`n" }
            $addresses = [regex]::Matches($logs, 'https://[a-z0-9-]+\.trycloudflare\.com')
            if ($addresses.Count -gt 0) { $url = $addresses[$addresses.Count - 1].Value; break }
            Start-Sleep -Seconds 2
        }
        if (-not $url) { throw '连接端已启动，但未在 60 秒内取得快速隧道地址。请检查隧道日志和网络后重新运行 -Tunnel；令牌和数据已保留。' }
    }
    Write-Host ("`n连接地址：{0}`n手机访问令牌：{1}" -f $url, $phoneToken)
    if ($useTunnel) {
        Write-Host '请将上述 HTTPS 地址和令牌填入 Tincall「连接已有服务」页。'
        Write-Host '快速隧道地址每次重启或更新都可能变化，需同步更新 App 和 AI 平台的 MCP 地址。长期使用建议绑定自己的 Cloudflare 隧道，或使用有公网地址的服务器和 HTTPS 反向代理。'
    } else {
        Write-Host '上述 HTTP 地址仅供本机访问。手机和远程 AI 平台需要 HTTPS；没有公网地址时请加 -Tunnel，有公网地址时请配置 HTTPS 反向代理，再将实际 HTTPS 地址和令牌填入 Tincall「连接已有服务」页。'
    }
    Write-Host ('私密配置：{0}，仅当前用户可读写。请勿分享令牌。' -f $script:EnvPath)
    Write-Host '电脑必须一直开机，并关闭睡眠。'
} catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
