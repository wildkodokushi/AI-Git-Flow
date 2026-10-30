<#
.SYNOPSIS
    Installs AI Git Flow as the "aiflow" command available from any terminal.

.DESCRIPTION
    Copies ai-flow.ps1 to a per-user folder, creates a small aiflow.cmd launcher and adds the
    folder to the user PATH. No administrator rights are required.
    Run the script again to update an existing installation.

.PARAMETER InstallDir
    Target folder. Default: %LOCALAPPDATA%\Programs\ai-flow

.PARAMETER InstallCertificate
    Download and install the Russian root CA certificate into the current user store.
    Needed once, because GigaChat servers use certificates signed by it.

.PARAMETER Uninstall
    Remove the installed files and the PATH entry.

.EXAMPLE
    .\install.ps1
    .\install.ps1 -InstallCertificate
    .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\ai-flow'),
    [switch]$InstallCertificate,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$commandName = 'aiflow'

function Write-Info { param([string]$Message) Write-Host '[INFO]  ' -NoNewline -ForegroundColor DarkGray; Write-Host $Message }
function Write-Ok { param([string]$Message) Write-Host '[OK]    ' -NoNewline -ForegroundColor Green; Write-Host $Message }
function Write-Warn { param([string]$Message) Write-Host '[WARN]  ' -NoNewline -ForegroundColor Yellow; Write-Host $Message }
function Write-Err { param([string]$Message) Write-Host '[ERROR] ' -NoNewline -ForegroundColor Red; Write-Host $Message }

function ConvertTo-PathKey {
    param([string]$Path)
    return $Path.Trim().TrimEnd('\').ToLowerInvariant()
}

function Get-UserPathEntries {
    $raw = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrEmpty($raw)) { return @() }
    return @($raw -split ';' | Where-Object { $_ })
}

function Add-ToUserPath {
    param([string]$Directory)
    $entries = Get-UserPathEntries
    $key = ConvertTo-PathKey -Path $Directory
    foreach ($entry in $entries) {
        if ((ConvertTo-PathKey -Path $entry) -eq $key) { return $false }
    }
    $updated = (@($entries) + $Directory) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
    return $true
}

function Remove-FromUserPath {
    param([string]$Directory)
    $entries = Get-UserPathEntries
    $key = ConvertTo-PathKey -Path $Directory
    $kept = @($entries | Where-Object { (ConvertTo-PathKey -Path $_) -ne $key })
    if ($kept.Count -eq $entries.Count) { return $false }
    [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
    return $true
}

function Install-RussianRootCertificate {
    $url = 'https://gu-st.ru/content/Other/doc/russian_trusted_root_ca.cer'
    $file = Join-Path $env:TEMP 'russian_trusted_root_ca.cer'
    [System.Net.WebRequest]::DefaultWebProxy = $null
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    Write-Info 'Загрузка корневого сертификата НУЦ Минцифры...'
    Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing
    Write-Info 'Windows покажет окно подтверждения установки сертификата. Нажмите "Да".'
    Import-Certificate -FilePath $file -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    Write-Ok 'Сертификат установлен.'
}

try {
    Write-Host ''
    Write-Host 'AI Git Flow: установка' -ForegroundColor Cyan
    Write-Host ''

    if ($Uninstall) {
        $removedPath = Remove-FromUserPath -Directory $InstallDir
        if (Test-Path -LiteralPath $InstallDir) {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force
            Write-Ok ('Папка удалена: {0}' -f $InstallDir)
        }
        else {
            Write-Info 'Папка установки не найдена.'
        }
        if ($removedPath) { Write-Ok 'Запись удалена из PATH.' }
        Write-Info 'Ключ GIGACHAT_AUTH_KEY и файл настроек не затронуты. Удалить ключ: [Environment]::SetEnvironmentVariable(''GIGACHAT_AUTH_KEY'', $null, ''User'')'
        exit 0
    }

    $source = Join-Path $PSScriptRoot 'ai-flow.ps1'
    if (-not (Test-Path -LiteralPath $source)) {
        throw ('Файл ai-flow.ps1 не найден рядом с установщиком ({0}).' -f $PSScriptRoot)
    }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

    $target = Join-Path $InstallDir 'ai-flow.ps1'
    if ((Resolve-Path -LiteralPath $source).Path -ne $target) {
        Copy-Item -LiteralPath $source -Destination $target -Force
    }
    Unblock-File -LiteralPath $target -ErrorAction SilentlyContinue
    Write-Ok ('Скрипт установлен: {0}' -f $target)

    # The launcher bypasses the execution policy, so no manual Set-ExecutionPolicy is needed.
    $launcher = @(
        '@echo off',
        'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ai-flow.ps1" %*',
        'exit /b %ERRORLEVEL%'
    ) -join "`r`n"
    $launcherPath = Join-Path $InstallDir ($commandName + '.cmd')
    [System.IO.File]::WriteAllText($launcherPath, $launcher + "`r`n", [System.Text.Encoding]::ASCII)
    Write-Ok ('Команда создана: {0}' -f $commandName)

    if (Add-ToUserPath -Directory $InstallDir) {
        Write-Ok 'Папка добавлена в PATH пользователя.'
    }
    else {
        Write-Info 'Папка уже есть в PATH.'
    }
    $env:Path = $env:Path + ';' + $InstallDir

    if ($InstallCertificate) {
        try { Install-RussianRootCertificate }
        catch { Write-Warn ('Не удалось установить сертификат автоматически: {0}' -f $_.Exception.Message) }
    }

    Write-Host ''
    Write-Host 'Дальнейшие шаги' -ForegroundColor Cyan
    Write-Host '---------------' -ForegroundColor DarkGray
    Write-Host '1. Закройте терминал и откройте новый. В VS Code закройте окно целиком.'
    Write-Host '2. Сохраните ключ GigaChat:   aiflow -SetKey'
    Write-Host '3. Проверьте установку:       aiflow -Help'
    Write-Host '4. В папке репозитория:       aiflow -DryRun'
    if (-not $InstallCertificate) {
        Write-Host ''
        Write-Info 'Если при запуске появится ошибка TLS-сертификата, выполните: .\install.ps1 -InstallCertificate'
    }
    Write-Host ''
    exit 0
}
catch {
    Write-Err $_.Exception.Message
    exit 1
}
