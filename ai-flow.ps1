<#
.SYNOPSIS
    Git workflow assistant powered by GigaChat: grouped commits, branches, pull requests, README, LICENSE and issues.

.DESCRIPTION
    Commands (first positional argument, default is "commit"):
      commit   Split changes into logical commits, push, optionally open a pull request.
      readme   Generate README.md from the repository contents.
      license  Create a LICENSE file (MIT, Apache-2.0, GPL-3.0 and others).
      issue    Turn a short note into a structured GitHub issue.

    Division of responsibilities: grouping of files, license texts and README structure are
    produced by the script itself; the language model only writes short descriptive texts.

.PARAMETER Branch
    Name of the branch to create. Prompted interactively when omitted.

.PARAMETER Base
    Base branch for the pull request. Detected automatically when omitted.

.PARAMETER Model
    GigaChat model for commit messages. Default: GigaChat-2.

.PARAMETER PrModel
    GigaChat model for the pull request description. Default: GigaChat-2-Pro.

.PARAMETER Lang
    Language of commit subjects and PR summary: en (default) or ru.

.PARAMETER MaxCodeGroups
    Upper limit of commit groups for source code files. Extra small groups are merged.

.PARAMETER NoPush
    Do not push the branch (also disables the pull request).

.PARAMETER NoPr
    Do not create a pull request.

.PARAMETER Draft
    Create the pull request as a draft.

.PARAMETER DryRun
    Show the plan only. Nothing is committed, no branch is created.

.PARAMETER Yes
    Skip the confirmation prompt.

.PARAMETER SkipCertCheck
    Disable TLS certificate validation (insecure). Prefer installing the Russian root CA instead.

.PARAMETER Stay
    Do not create a branch: commit and push to the current branch (no pull request).
    The same happens when "." is entered at the branch prompt or passed as -Branch.

.PARAMETER Text
    Issue command: short description of the problem or task.

.PARAMETER Type
    License command: license identifier (mit, apache-2.0, gpl-3.0, bsd-3-clause, isc, ...).

.PARAMETER Author
    License command: copyright holder. Defaults to git config user.name.

.PARAMETER Year
    License command: copyright year. Defaults to the current year.

.PARAMETER Force
    Overwrite existing LICENSE / README.md without asking.

.PARAMETER Labels
    Issue command: comma separated labels. Chosen automatically when omitted.

.PARAMETER UseSystemProxy
    Use the system proxy for GigaChat requests. By default the proxy is bypassed, because stale
    proxy entries left behind by VPN clients break direct access.

.PARAMETER SetKey
    Prompt for the GigaChat authorization key and store it in the GIGACHAT_AUTH_KEY user variable.

.PARAMETER InitConfig
    Create the default configuration file in %APPDATA%\ai-flow\config.json.

.PARAMETER Help
    Show a short usage summary.

.EXAMPLE
    aiflow
    aiflow -Branch feat/home-swiper -Lang ru -Draft
    aiflow -DryRun
    aiflow -SetKey
    aiflow -Stay
    aiflow readme -Lang ru
    aiflow license -Type mit
    aiflow issue "Кнопка входа не реагирует на нажатие"
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('commit', 'readme', 'license', 'issue', 'help')]
    [string]$Command = 'commit',
    [Parameter(Position = 1)][Alias('t', 'Title')][string]$Text,
    [Alias('b')][string]$Branch,
    [string]$Base,
    [string]$Remote = 'origin',
    [string]$Model = 'GigaChat-2',
    [string]$PrModel = 'GigaChat-2-Pro',
    [ValidateSet('en', 'ru')][string]$Lang = 'en',
    [ValidateRange(2, 10)][int]$MaxCodeGroups = 5,
    [ValidateRange(500, 20000)][int]$MaxDiffChars = 6000,
    [string]$Type,
    [string]$Author,
    [int]$Year = (Get-Date).Year,
    [string[]]$Labels,
    [Alias('here')][switch]$Stay,
    [switch]$NoPush,
    [switch]$NoPr,
    [switch]$Draft,
    [switch]$Force,
    [Alias('dry')][switch]$DryRun,
    [Alias('y')][switch]$Yes,
    [switch]$SkipCertCheck,
    [switch]$UseSystemProxy,
    [switch]$SetKey,
    [switch]$InitConfig,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

$script:AuthUrl      = 'https://ngw.devices.sberbank.ru:9443/api/v2/oauth'
$script:ChatUrl      = 'https://gigachat.devices.sberbank.ru/api/v1/chat/completions'
$script:Scope        = 'GIGACHAT_API_PERS'
$script:AuthKey      = $null
$script:Token        = $null
$script:TokenExpires = [datetime]::MinValue
$script:Utf8NoBom    = New-Object System.Text.UTF8Encoding($false)
$script:ImperativeMap = $null
$script:ConfigKeys   = @('Lang', 'Model', 'PrModel', 'Remote', 'Base', 'MaxCodeGroups', 'MaxDiffChars', 'Draft', 'NoPr', 'NoPush', 'Yes', 'Author')

$script:CategoryMeta = @{
    deps   = @{ Type = 'build'; Scope = 'deps';   Order = 10 }
    ci     = @{ Type = 'ci';    Scope = $null;    Order = 20 }
    config = @{ Type = 'chore'; Scope = 'config'; Order = 30 }
    assets = @{ Type = 'chore'; Scope = 'assets'; Order = 40 }
    code   = @{ Type = $null;   Scope = $null;    Order = 50 }
    style  = @{ Type = 'style'; Scope = $null;    Order = 60 }
    test   = @{ Type = 'test';  Scope = $null;    Order = 70 }
    docs   = @{ Type = 'docs';  Scope = $null;    Order = 80 }
}

$script:FallbackSubject = @{
    deps   = 'update project dependencies'
    ci     = 'update CI and container configuration'
    config = 'update project configuration'
    assets = 'update static assets'
    style  = 'update styles'
    test   = 'update tests'
    docs   = 'update documentation'
}

$script:LicenseCatalog = [ordered]@{
    'mit'          = @{ Description = 'Простая и самая популярная: свободное использование, нужно лишь сохранить копирайт.' }
    'apache-2.0'   = @{ Description = 'Как MIT, плюс явная патентная лицензия. Подходит для крупных проектов.' }
    'bsd-3-clause' = @{ Description = 'Близка к MIT, запрещает использовать имя автора для рекламы производных продуктов.' }
    'bsd-2-clause' = @{ Description = 'Упрощённая BSD, по смыслу близка к MIT.' }
    'isc'          = @{ Description = 'Очень короткая, по смыслу эквивалент MIT.' }
    'gpl-3.0'      = @{ Description = 'Строгий копилефт: производные работы обязаны оставаться открытыми под GPL.' }
    'agpl-3.0'     = @{ Description = 'GPL плюс требование открывать код сетевых сервисов.' }
    'lgpl-3.0'     = @{ Description = 'Слабый копилефт для библиотек: их можно подключать к закрытому коду.' }
    'mpl-2.0'      = @{ Description = 'Копилефт на уровне отдельных файлов.' }
    'unlicense'    = @{ Description = 'Общественное достояние: никаких условий.' }
}

# Short licenses are embedded so they work offline. Longer texts are downloaded from the GitHub licenses API.
$script:LicenseTemplates = @{
    'mit' = @'
MIT License

Copyright (c) [year] [fullname]

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
'@
    'bsd-3-clause' = @'
BSD 3-Clause License

Copyright (c) [year], [fullname]
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
'@
    'bsd-2-clause' = @'
BSD 2-Clause License

Copyright (c) [year], [fullname]
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
'@
    'isc' = @'
ISC License

Copyright (c) [year], [fullname]

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THIS SOFTWARE.
'@
    'unlicense' = @'
This is free and unencumbered software released into the public domain.

Anyone is free to copy, modify, publish, use, compile, sell, or
distribute this software, either in source code form or as a compiled
binary, for any purpose, commercial or non-commercial, and by any
means.

In jurisdictions that recognize copyright laws, the author or authors
of this software dedicate any and all copyright interest in the
software to the public domain. We make this dedication for the benefit
of the public at large and to the detriment of our heirs and
successors. We intend this dedication to be an overt act of
relinquishment in perpetuity of all present and future rights to this
software under copyright law.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

For more information, please refer to <https://unlicense.org>
'@
}

# ---------------------------------------------------------------------------
# Console output
# ---------------------------------------------------------------------------

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * $Title.Length) -ForegroundColor DarkGray
}

function Write-Info {
    param([string]$Message)
    Write-Host '[INFO]  ' -NoNewline -ForegroundColor DarkGray
    Write-Host $Message
}

function Write-Ok {
    param([string]$Message)
    Write-Host '[OK]    ' -NoNewline -ForegroundColor Green
    Write-Host $Message
}

function Write-Warn {
    param([string]$Message)
    Write-Host '[WARN]  ' -NoNewline -ForegroundColor Yellow
    Write-Host $Message
}

function Write-Err {
    param([string]$Message)
    Write-Host '[ERROR] ' -NoNewline -ForegroundColor Red
    Write-Host $Message
}

# ---------------------------------------------------------------------------
# Process helpers
# ---------------------------------------------------------------------------

function Invoke-Native {
    param(
        [string]$Exe,
        [string[]]$ArgList
    )
    # Native stderr must not become a terminating error (git writes warnings and progress there).
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $Exe @ArgList 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    $stdout = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    $stderr = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() })
    return [pscustomobject]@{
        ExitCode = $code
        Out      = ($stdout -join "`n")
        Err      = (($stderr -join "`n").Trim())
    }
}

function Invoke-Git {
    param([string[]]$GitArgs)
    return Invoke-Native -Exe 'git' -ArgList (@('-c', 'core.quotepath=false') + $GitArgs)
}

function Invoke-GitChecked {
    param([string[]]$GitArgs)
    $result = Invoke-Git -GitArgs $GitArgs
    if ($result.ExitCode -ne 0) {
        $details = $result.Err
        if ([string]::IsNullOrWhiteSpace($details)) { $details = $result.Out }
        throw ('Команда git {0} завершилась с ошибкой: {1}' -f ($GitArgs -join ' '), $details)
    }
    return $result
}

function Add-GitPaths {
    param([string[]]$Paths)
    for ($i = 0; $i -lt $Paths.Count; $i += 100) {
        $last = [Math]::Min($i + 99, $Paths.Count - 1)
        $chunk = @($Paths[$i..$last])
        Invoke-GitChecked -GitArgs (@('add', '-A', '--') + $chunk) | Out-Null
    }
}

# ---------------------------------------------------------------------------
# GigaChat client
# ---------------------------------------------------------------------------

function Enable-InsecureCertificates {
    if (-not ('TrustAllCertsPolicy' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
'@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
}

function Invoke-HttpJson {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Body,
        [string]$ContentType = 'application/json; charset=utf-8'
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $maxAttempts = 3

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $Uri -Method Post -Headers $Headers -ContentType $ContentType `
                -Body $bytes -UseBasicParsing -TimeoutSec 90
            $text = [System.Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
            return ($text | ConvertFrom-Json)
        }
        catch {
            $ex = $_.Exception
            $status = 0
            $detail = ''

            if ($ex -is [System.Net.WebException]) {
                if ($ex.Status -eq [System.Net.WebExceptionStatus]::TrustFailure -or
                    $ex.Status -eq [System.Net.WebExceptionStatus]::SecureChannelFailure) {
                    throw ('Не удалось проверить TLS-сертификат сервера GigaChat. ' +
                           'Установите корневой сертификат НУЦ Минцифры (инструкция в README) ' +
                           'или запустите скрипт с параметром -SkipCertCheck (небезопасно).')
                }
                if ($ex.Response) {
                    $status = [int]$ex.Response.StatusCode
                    try {
                        $reader = New-Object System.IO.StreamReader($ex.Response.GetResponseStream(), [System.Text.Encoding]::UTF8)
                        $detail = $reader.ReadToEnd()
                    }
                    catch { }
                }
            }

            $retryable = ($status -eq 0) -or ($status -eq 429) -or ($status -ge 500)
            if ($retryable -and $attempt -lt $maxAttempts) {
                Start-Sleep -Seconds (2 * $attempt)
                continue
            }

            switch ($status) {
                401     { $reason = 'Авторизация отклонена (HTTP 401). Проверьте ключ авторизации и scope.' }
                402     { $reason = 'Недостаточно токенов или средств на балансе (HTTP 402).' }
                403     { $reason = 'Доступ запрещён (HTTP 403).' }
                429     { $reason = 'Превышен лимит запросов (HTTP 429). Бесплатный тариф допускает один поток.' }
                0       {
                    $inner = ''
                    if ($ex.InnerException) { $inner = ' / ' + $ex.InnerException.Message }
                    $hint = ' Проверьте интернет, VPN и антивирус. Если выход в сеть возможен только через прокси, запустите с параметром -UseSystemProxy.'
                    $reason = ('Нет соединения с сервером ({0}): {1}{2}.{3}' -f $ex.GetType().Name, $ex.Message, $inner, $hint)
                }
                default { $reason = 'Ошибка запроса (HTTP ' + $status + ').' }
            }
            if ($detail) {
                if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) }
                $reason = $reason + ' ' + $detail
            }
            throw $reason
        }
    }
}

function Get-AuthKey {
    if ($script:AuthKey) { return $script:AuthKey }

    $key = $env:GIGACHAT_AUTH_KEY
    if ([string]::IsNullOrWhiteSpace($key)) {
        Write-Warn 'Переменная окружения GIGACHAT_AUTH_KEY не задана.'
        Write-Info 'Чтобы сохранить ключ навсегда, выполните: aiflow -SetKey'
        $key = Read-Secret -Prompt 'Authorization key GigaChat'
    }
    if ([string]::IsNullOrWhiteSpace($key)) { throw 'Ключ авторизации GigaChat не указан.' }

    $script:AuthKey = $key.Trim()
    return $script:AuthKey
}

function Get-AccessToken {
    if ($script:Token -and (Get-Date) -lt $script:TokenExpires) { return $script:Token }

    $headers = @{
        Authorization = 'Basic ' + (Get-AuthKey)
        RqUID         = [guid]::NewGuid().ToString()
        Accept        = 'application/json'
    }
    $response = Invoke-HttpJson -Uri $script:AuthUrl -Headers $headers `
        -Body ('scope=' + $script:Scope) -ContentType 'application/x-www-form-urlencoded'

    if (-not $response.access_token) { throw 'GigaChat не вернул access token.' }
    $script:Token = $response.access_token
    # The token lives 30 minutes; refresh a little earlier.
    $script:TokenExpires = (Get-Date).AddMinutes(25)
    return $script:Token
}

function Invoke-GigaChat {
    param(
        [string]$SystemPrompt,
        [string]$UserPrompt,
        [string]$ModelName,
        [int]$MaxTokens = 200
    )
    $payload = @{
        model       = $ModelName
        temperature = 0.2
        max_tokens  = $MaxTokens
        messages    = @(
            @{ role = 'system'; content = $SystemPrompt },
            @{ role = 'user'; content = $UserPrompt }
        )
    }
    $body = $payload | ConvertTo-Json -Depth 6 -Compress
    $headers = @{
        Authorization = 'Bearer ' + (Get-AccessToken)
        Accept        = 'application/json'
    }
    $response = Invoke-HttpJson -Uri $script:ChatUrl -Headers $headers -Body $body
    if (-not $response.choices) { throw 'Пустой ответ от GigaChat.' }
    return [string]$response.choices[0].message.content
}

# ---------------------------------------------------------------------------
# Text helpers
# ---------------------------------------------------------------------------

function ConvertTo-Subject {
    param(
        [string]$Text,
        [int]$MaxLen = 64
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $line = @($Text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)[0]
    if (-not $line) { return $null }

    $line = $line.Trim().Trim([char]34, [char]39, [char]96).Trim()
    $line = $line -replace '^[-*]\s+', ''
    $line = $line.TrimEnd('.')

    if ($line.Length -gt $MaxLen) {
        $line = $line.Substring(0, $MaxLen)
        $cut = $line.LastIndexOf(' ')
        if ($cut -gt 20) { $line = $line.Substring(0, $cut) }
    }
    if ($line.Length -gt 1 -and $line[0] -cmatch '[A-Z]' -and $line[1] -cmatch '[a-z]') {
        $line = $line.Substring(0, 1).ToLowerInvariant() + $line.Substring(1)
    }
    return $line.Trim()
}

function Get-LanguageName {
    if ($Lang -eq 'ru') { return 'Russian' }
    return 'English'
}

# ---------------------------------------------------------------------------
# Change analysis and deterministic grouping
# ---------------------------------------------------------------------------

function Get-ChangedFiles {
    $result = Invoke-GitChecked -GitArgs @('status', '--porcelain', '-z', '--untracked-files=all')
    $entries = $result.Out.Split([char]0)
    $changes = New-Object System.Collections.Generic.List[object]

    $i = 0
    while ($i -lt $entries.Length) {
        $entry = $entries[$i]
        $i++
        if ($entry.Length -lt 4) { continue }

        $status = $entry.Substring(0, 2)
        $path = $entry.Substring(3)
        $paths = @($path)

        # Renames and copies carry the original path in the next field.
        if ($status -match '[RC]' -and $i -lt $entries.Length) {
            $paths += $entries[$i]
            $i++
        }
        $changes.Add([pscustomobject]@{ Path = $path; Paths = $paths; Status = $status })
    }
    return , $changes.ToArray()
}

function Get-FileCategory {
    param([string]$Path)

    $p = $Path.Replace('\', '/').ToLowerInvariant()
    $name = $p.Substring($p.LastIndexOf('/') + 1)

    if ($name -match '^(package\.json|package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|composer\.(json|lock)|requirements.*\.txt|pipfile(\.lock)?|poetry\.lock|pyproject\.toml|go\.(mod|sum)|cargo\.(toml|lock)|gemfile(\.lock)?|packages\.lock\.json|.*\.csproj|.*\.sln)$') { return 'deps' }
    if ($p -match '^\.github/' -or $name -match '^(\.gitlab-ci\.yml|dockerfile.*|docker-compose.*|\.dockerignore|jenkinsfile)$') { return 'ci' }
    if ($name -match '^(\.gitignore|\.gitattributes|\.editorconfig|\.env\.example|\.nvmrc|\.npmrc|\.babelrc.*|\.eslintrc.*|\.prettierrc.*|tsconfig.*\.json|jsconfig\.json|.*\.config\.(js|cjs|mjs|ts|json))$') { return 'config' }
    if ($name -match '\.(md|mdx|rst|txt)$' -or $name -match '^(license|changelog)' -or $p -match '^docs/') { return 'docs' }
    if ($p -match '(^|/)(tests?|__tests__|e2e)/' -or $name -match '\.(test|spec)\.[a-z0-9]+$') { return 'test' }
    if ($name -match '\.(css|scss|sass|less|styl)$') { return 'style' }
    if ($name -match '\.(png|jpe?g|gif|svg|webp|avif|ico|woff2?|ttf|otf|eot|mp4|webm|mp3|pdf)$') { return 'assets' }
    return 'code'
}

function Get-CodeKey {
    param([string]$Path)
    $segments = $Path.Replace('\', '/').Split('/')
    if ($segments.Length -ge 3) { return $segments[0] + '/' + $segments[1] }
    if ($segments.Length -eq 2) { return $segments[0] }
    return '.'
}

function New-Group {
    param(
        [string]$Key,
        [string]$Category,
        [string]$Scope
    )
    return [pscustomobject]@{
        Key      = $Key
        Category = $Category
        Scope    = $Scope
        Order    = $script:CategoryMeta[$Category].Order
        Files    = (New-Object 'System.Collections.Generic.List[string]')
        Paths    = (New-Object 'System.Collections.Generic.List[string]')
        Message  = $null
    }
}

function New-CommitPlan {
    param(
        [object[]]$Changes,
        [int]$CodeGroupLimit
    )
    $map = [ordered]@{}

    foreach ($change in $Changes) {
        $category = Get-FileCategory -Path $change.Path
        if ($category -eq 'code') {
            $codeKey = Get-CodeKey -Path $change.Path
            $key = 'code:' + $codeKey
            $scope = $null
            if ($codeKey -ne '.') {
                $scope = $codeKey.Split('/')[-1]
                if ($scope -eq 'src') { $scope = $null }
            }
        }
        else {
            $key = $category
            $scope = $script:CategoryMeta[$category].Scope
        }

        if (-not $map.Contains($key)) {
            $map[$key] = New-Group -Key $key -Category $category -Scope $scope
        }
        $map[$key].Files.Add($change.Path)
        foreach ($p in $change.Paths) { $map[$key].Paths.Add($p) }
    }

    $groups = @($map.Values)
    $codeGroups = @($groups | Where-Object { $_.Category -eq 'code' } | Sort-Object { $_.Files.Count } -Descending)

    # Merge the smallest code groups so the history stays readable.
    if ($codeGroups.Count -gt $CodeGroupLimit) {
        $rest = @($codeGroups[($CodeGroupLimit - 1)..($codeGroups.Count - 1)])
        $merged = New-Group -Key 'code:other' -Category 'code' -Scope $null
        foreach ($g in $rest) {
            foreach ($f in $g.Files) { $merged.Files.Add($f) }
            foreach ($p in $g.Paths) { $merged.Paths.Add($p) }
        }
        $restKeys = @($rest | ForEach-Object { $_.Key })
        $groups = @($groups | Where-Object { $restKeys -notcontains $_.Key }) + $merged
    }

    return @($groups | Sort-Object Order, Key)
}

# ---------------------------------------------------------------------------
# Commit message generation
# ---------------------------------------------------------------------------

function Get-GroupContext {
    param($Group)

    $paths = @($Group.Paths | Select-Object -First 40)
    $stat = (Invoke-Git -GitArgs (@('diff', '--cached', '--stat=100', '--') + $paths)).Out

    $lockPattern = '(^|/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|composer\.lock|poetry\.lock|Pipfile\.lock|Cargo\.lock|Gemfile\.lock|go\.sum|packages\.lock\.json)$'
    $patchPaths = @($paths | Where-Object { $_ -notmatch $lockPattern })
    if ($patchPaths.Count -eq 0) { return $stat }

    $patch = (Invoke-Git -GitArgs (@('diff', '--cached', '-U1', '--no-color', '--') + $patchPaths)).Out
    if ($patch.Length -gt $MaxDiffChars) {
        $patch = $patch.Substring(0, $MaxDiffChars) + "`n[diff truncated]"
    }
    return $stat + "`n`n" + $patch
}

function Get-FallbackMessage {
    param($Group)
    $meta = $script:CategoryMeta[$Group.Category]
    if ($Group.Category -eq 'code') {
        $label = if ($Group.Scope) { $Group.Scope } else { 'project code' }
        return 'feat: update ' + $label
    }
    $prefix = $meta.Type
    if ($meta.Scope) { $prefix = $prefix + '(' + $meta.Scope + ')' }
    return '{0}: {1}' -f $prefix, $script:FallbackSubject[$Group.Category]
}

function New-CommitMessage {
    param($Group)

    $context = Get-GroupContext -Group $Group
    $fileList = (@($Group.Files | Select-Object -First 30) | ForEach-Object { '- ' + $_ }) -join "`n"

    if ($Group.Category -eq 'code') {
        $task = @(
            'Write a one-line commit message in the format "<type>: <subject>".',
            'Allowed types: feat (new functionality), fix (bug fix), refactor (restructuring without behaviour change), perf (performance improvement).'
        )
    }
    else {
        $task = @('Write only the subject of a commit message. The type prefix is added separately, so do not include "feat:", "docs:" or similar.')
    }
    $rules = @(
        ('Subject language: {0}.' -f (Get-LanguageName)),
        'Use the imperative mood ("add", "fix", "update") and never the past tense ("added", "fixed"). Start with a lowercase letter, no trailing period.',
        'Keep the subject under 60 characters.',
        'Describe what changed, not which files were touched.',
        'Reply with a single line and nothing else.'
    )
    $userPrompt = ($task + $rules + @('', 'Changed files:', $fileList, '', 'Diff summary:', $context)) -join "`n"
    $systemPrompt = 'You are a senior software engineer who writes precise Git commit messages in the Conventional Commits style. Never add quotes, markdown or explanations.'

    $answer = $null
    try {
        $answer = Invoke-GigaChat -SystemPrompt $systemPrompt -UserPrompt $userPrompt -ModelName $Model -MaxTokens 80
    }
    catch {
        Write-Warn ('Не удалось получить сообщение для группы "{0}": {1}' -f $Group.Key, $_.Exception.Message)
    }

    $line = ConvertTo-Subject -Text $answer -MaxLen 100
    if (-not $line) { return Get-FallbackMessage -Group $Group }

    $subject = $line
    $typed = '^([a-z]+)(\([^)]*\))?!?:\s*(.+)$'

    if ($Group.Category -eq 'code') {
        $type = 'feat'
        if ($line -match $typed) {
            if (@('feat', 'fix', 'refactor', 'perf') -contains $Matches[1]) { $type = $Matches[1] }
            $subject = $Matches[3]
        }
        $prefix = $type
        if ($Group.Scope) { $prefix = $prefix + '(' + $Group.Scope + ')' }
    }
    else {
        if ($line -match $typed) { $subject = $Matches[3] }
        $meta = $script:CategoryMeta[$Group.Category]
        $prefix = $meta.Type
        if ($meta.Scope) { $prefix = $prefix + '(' + $meta.Scope + ')' }
    }

    $subject = ConvertTo-Subject -Text $subject -MaxLen 64
    if (-not $subject) { return Get-FallbackMessage -Group $Group }
    $subject = Set-ImperativeSubject -Text $subject
    return '{0}: {1}' -f $prefix, $subject
}

# ---------------------------------------------------------------------------
# Branch, base and pull request
# ---------------------------------------------------------------------------

function Resolve-BranchName {
    param([string]$Requested, [string]$CurrentBranch)
    $name = $Requested
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            Write-Host ('Текущая ветка: {0}' -f $CurrentBranch) -ForegroundColor DarkGray
            $name = Read-Host 'Имя новой ветки (например, feat/home-swiper). Напишите . чтобы остаться в текущей ветке'
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'Имя ветки не указано. Операция отменена.' }
        }
        $name = $name.Trim()
        if ($name -eq '.') { return '.' }

        $valid = Invoke-Git -GitArgs @('check-ref-format', '--branch', $name)
        if ($valid.ExitCode -ne 0) {
            Write-Warn ('Недопустимое имя ветки: {0}' -f $name)
            $name = $null
            continue
        }
        $exists = Invoke-Git -GitArgs @('show-ref', '--verify', '--quiet', ('refs/heads/' + $name))
        if ($exists.ExitCode -eq 0) {
            Write-Warn ('Ветка {0} уже существует.' -f $name)
            $name = $null
            continue
        }
        return $name
    }
}

function Get-DefaultBranch {
    param([string]$RemoteName, [string]$Fallback)

    $head = Invoke-Git -GitArgs @('symbolic-ref', '--quiet', '--short', ('refs/remotes/' + $RemoteName + '/HEAD'))
    if ($head.ExitCode -eq 0 -and $head.Out.Trim()) {
        $prefix = '^' + [regex]::Escape($RemoteName) + '/'
        return ($head.Out.Trim() -replace $prefix, '')
    }
    foreach ($candidate in @('main', 'master', 'develop')) {
        $remoteRef = Invoke-Git -GitArgs @('show-ref', '--verify', '--quiet', ('refs/remotes/' + $RemoteName + '/' + $candidate))
        if ($remoteRef.ExitCode -eq 0) { return $candidate }
        $localRef = Invoke-Git -GitArgs @('show-ref', '--verify', '--quiet', ('refs/heads/' + $candidate))
        if ($localRef.ExitCode -eq 0) { return $candidate }
    }
    return $Fallback
}

function Get-FallbackPrTitle {
    param([string]$BranchName, [string[]]$Subjects)
    if ($BranchName -match '^(feat|fix|refactor|perf|docs|style|test|build|ci|chore)/(.+)$') {
        return '{0}: {1}' -f $Matches[1], ($Matches[2] -replace '[-_]', ' ')
    }
    if ($Subjects.Count -gt 0) { return $Subjects[0] }
    return $BranchName
}

function New-PullRequest {
    param([string]$BranchName, [string]$BaseBranch)

    Write-Section 'Pull request'

    $remoteRef = Invoke-Git -GitArgs @('show-ref', '--verify', '--quiet', ('refs/remotes/' + $Remote + '/' + $BaseBranch))
    $baseRef = $BaseBranch
    if ($remoteRef.ExitCode -eq 0) { $baseRef = $Remote + '/' + $BaseBranch }

    $log = Invoke-Git -GitArgs @('log', '--reverse', '--pretty=format:%s', ($baseRef + '..' + $BranchName))
    $subjects = @($log.Out -split "`r?`n" | Where-Object { $_.Trim() })
    if ($subjects.Count -eq 0) {
        Write-Warn ('Нет коммитов относительно {0}. Pull request не создаётся.' -f $baseRef)
        return
    }
    $stat = (Invoke-Git -GitArgs @('diff', '--stat=100', ($baseRef + '...' + $BranchName))).Out

    $userPrompt = (@(
        'Write a pull request title and summary for the commits and diff summary below.',
        'Output format, plain text without markdown:',
        'Line 1: the pull request title in Conventional Commits style, at most 70 characters, no trailing period.',
        'Line 2 and onward: a summary of 2 to 4 sentences describing what changed and why it matters.',
        ('Language of the summary: {0}.' -f (Get-LanguageName)),
        'Do not invent details that are not visible in the input.',
        '',
        'Commits:'
    ) + @($subjects | ForEach-Object { '- ' + $_ }) + @('', 'Diff summary:', $stat)) -join "`n"

    $systemPrompt = 'You write concise, factual pull request descriptions for software engineers. Follow the requested output format exactly.'

    $title = $null
    $summary = ''
    try {
        $answer = Invoke-GigaChat -SystemPrompt $systemPrompt -UserPrompt $userPrompt -ModelName $PrModel -MaxTokens 400
        $lines = @($answer -split "`r?`n" | Where-Object { $_.Trim() })
        if ($lines.Count -gt 0) {
            $titleLine = $lines[0] -replace '^(?i)(title|заголовок)\s*:\s*', ''
            $title = ConvertTo-Subject -Text $titleLine -MaxLen 72
            if ($title) { $title = Set-ImperativeSubject -Text $title }
            if ($lines.Count -gt 1) {
                $summary = (@($lines | Select-Object -Skip 1) -join "`n").Trim()
                $summary = $summary -replace '^(?i)(summary|описание)\s*:\s*', ''
            }
        }
    }
    catch {
        Write-Warn ('Не удалось сгенерировать описание PR: {0}' -f $_.Exception.Message)
    }
    if (-not $title) { $title = Get-FallbackPrTitle -BranchName $BranchName -Subjects $subjects }

    $body = New-Object System.Collections.Generic.List[string]
    if ($summary) {
        $body.Add('## Summary')
        $body.Add('')
        $body.Add($summary)
        $body.Add('')
    }
    $body.Add('## Changes')
    $body.Add('')
    foreach ($s in $subjects) { $body.Add('- ' + $s) }
    $bodyText = ($body -join "`n") + "`n"

    $gh = Get-Command gh -ErrorAction SilentlyContinue
    $authenticated = $false
    if ($gh) { $authenticated = ((Invoke-Native -Exe 'gh' -ArgList @('auth', 'status')).ExitCode -eq 0) }

    if (-not $gh -or -not $authenticated) {
        if (-not $gh) { Write-Warn 'GitHub CLI (gh) не найден. Установите его: https://cli.github.com' }
        else { Write-Warn 'GitHub CLI не авторизован. Выполните: gh auth login' }
        Write-Info 'Текст pull request для ручного создания:'
        Write-Host ''
        Write-Host $title -ForegroundColor White
        Write-Host ''
        Write-Host $bodyText
        return
    }

    $bodyFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($bodyFile, $bodyText, $script:Utf8NoBom)
        $ghArgs = @('pr', 'create', '--base', $BaseBranch, '--head', $BranchName, '--title', $title, '--body-file', $bodyFile)
        if ($Draft) { $ghArgs += '--draft' }
        $created = Invoke-Native -Exe 'gh' -ArgList $ghArgs
        if ($created.ExitCode -ne 0) {
            $details = $created.Err
            if (-not $details) { $details = $created.Out }
            Write-Err ('Не удалось создать pull request: {0}' -f $details)
            return
        }
        $url = @($created.Out -split "`r?`n" | Where-Object { $_ -match '^https?://' } | Select-Object -Last 1)[0]
        if ($url) { Write-Ok ('Pull request создан: {0}' -f $url) }
        else { Write-Ok 'Pull request создан.' }
    }
    finally {
        Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Plan output
# ---------------------------------------------------------------------------

function Show-Plan {
    param([object[]]$Plan)
    Write-Section 'План коммитов'
    $index = 1
    foreach ($group in $Plan) {
        Write-Host ('{0,2}. ' -f $index) -NoNewline -ForegroundColor DarkGray
        Write-Host $group.Message -ForegroundColor White
        $shown = @($group.Files | Select-Object -First 6)
        foreach ($file in $shown) { Write-Host ('      ' + $file) -ForegroundColor DarkGray }
        if ($group.Files.Count -gt 6) {
            Write-Host ('      ... и ещё {0}' -f ($group.Files.Count - 6)) -ForegroundColor DarkGray
        }
        $index++
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Utility commands, configuration and subject normalisation
# ---------------------------------------------------------------------------

function Initialize-Console {
    try { [Console]::OutputEncoding = $script:Utf8NoBom } catch { }
    $global:OutputEncoding = $script:Utf8NoBom
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

function Get-ConfigPath {
    return (Join-Path $env:APPDATA 'ai-flow\config.json')
}

function Read-Secret {
    param([string]$Prompt)
    $secure = Read-Host $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Save-AuthKey {
    Write-Info 'Ключ будет сохранён в пользовательскую переменную окружения GIGACHAT_AUTH_KEY.'
    $key = Read-Secret -Prompt 'Authorization key GigaChat'
    if ([string]::IsNullOrWhiteSpace($key)) { throw 'Ключ не указан. Ничего не изменено.' }
    $key = $key.Trim()
    [Environment]::SetEnvironmentVariable('GIGACHAT_AUTH_KEY', $key, 'User')
    $env:GIGACHAT_AUTH_KEY = $key
    Write-Ok 'Ключ сохранён.'
    Write-Info 'Новые терминалы получат его автоматически. В VS Code перезапустите окно целиком.'
}

function Initialize-Config {
    $path = Get-ConfigPath
    if (Test-Path -LiteralPath $path) {
        Write-Info ('Файл настроек уже существует: {0}' -f $path)
        return
    }
    $dir = Split-Path -Parent $path
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $content = @(
        '{',
        '  "Lang": "en",',
        '  "Model": "GigaChat-2",',
        '  "PrModel": "GigaChat-2-Pro",',
        '  "Remote": "origin",',
        '  "MaxCodeGroups": 5,',
        '  "Draft": false',
        '}'
    ) -join "`r`n"
    [System.IO.File]::WriteAllText($path, $content + "`r`n", $script:Utf8NoBom)
    Write-Ok ('Файл настроек создан: {0}' -f $path)
    Write-Info 'Параметры командной строки всегда имеют приоритет над файлом.'
}

function Show-Help {
    Write-Host ''
    Write-Host 'AI Git Flow' -ForegroundColor Cyan
    Write-Host 'Git-ассистент на основе GigaChat'
    Write-Host ''
    Write-Host 'Использование: aiflow [команда] [параметры]' -ForegroundColor White
    Write-Host ''
    Write-Host 'Команды' -ForegroundColor Cyan
    $commands = @(
        @('commit (по умолчанию)', 'ветка, коммиты, push и pull request'),
        @('readme', 'сгенерировать README.md по содержимому репозитория'),
        @('license', 'создать файл LICENSE (MIT, Apache-2.0, GPL-3.0 и другие)'),
        @('issue "описание"', 'превратить заметку в структурированный issue на GitHub')
    )
    foreach ($row in $commands) {
        Write-Host ('  {0,-24}' -f $row[0]) -NoNewline -ForegroundColor White
        Write-Host $row[1] -ForegroundColor Gray
    }
    Write-Host ''
    Write-Host 'Параметры' -ForegroundColor Cyan
    $rows = @(
        @('-Branch, -b <имя>', 'имя новой ветки; "." оставляет текущую ветку'),
        @('-Stay, -here', 'не создавать ветку: коммит и push в текущую ветку'),
        @('-DryRun, -dry', 'показать результат, ничего не менять'),
        @('-Yes, -y', 'не спрашивать подтверждение'),
        @('-Lang en|ru', 'язык текстов (коммиты, PR, README, issue)'),
        @('-Draft', 'создать PR как черновик'),
        @('-NoPr', 'не создавать pull request'),
        @('-NoPush', 'не отправлять ветку на сервер'),
        @('-Base <ветка>', 'базовая ветка для PR'),
        @('-Type <лицензия>', 'license: mit, apache-2.0, gpl-3.0, bsd-3-clause, isc ...'),
        @('-Author, -Year', 'license: правообладатель и год'),
        @('-Labels a,b', 'issue: метки'),
        @('-Force', 'перезаписать LICENSE / README.md без вопроса'),
        @('-Model, -PrModel', 'модели GigaChat для коротких текстов и для длинных'),
        @('-UseSystemProxy', 'использовать системный прокси'),
        @('-SkipCertCheck', 'отключить проверку TLS (небезопасно)'),
        @('-SetKey', 'сохранить ключ авторизации GigaChat'),
        @('-InitConfig', 'создать файл настроек по умолчанию'),
        @('-Help', 'эта справка')
    )
    foreach ($row in $rows) {
        Write-Host ('  {0,-24}' -f $row[0]) -NoNewline -ForegroundColor White
        Write-Host $row[1] -ForegroundColor Gray
    }
    Write-Host ''
    Write-Host ('Файл настроек: {0}' -f (Get-ConfigPath)) -ForegroundColor DarkGray
    Write-Host ''
}

function Get-ImperativeMap {
    $verbs = @(
        'add', 'update', 'fix', 'remove', 'implement', 'change', 'create', 'improve', 'refactor',
        'introduce', 'move', 'rename', 'delete', 'configure', 'enable', 'disable', 'adjust', 'correct',
        'optimize', 'replace', 'resolve', 'integrate', 'simplify', 'extend', 'use', 'handle', 'apply',
        'support', 'rewrite', 'clean', 'merge', 'align', 'switch', 'restructure', 'expand', 'reorganize',
        'document', 'polish', 'tweak', 'harden', 'bump', 'upgrade', 'migrate', 'install', 'include',
        'ensure', 'prepare', 'build', 'make', 'display', 'show', 'organize', 'rework', 'extract', 'split',
        'set', 'allow', 'prevent', 'reduce', 'separate', 'initialize', 'define', 'provide', 'streamline'
    )
    $map = @{}
    foreach ($v in $verbs) {
        if ($v -match '[^aeiou]y$') {
            $stem = $v.Substring(0, $v.Length - 1)
            $past = $stem + 'ied'; $third = $stem + 'ies'; $ing = $v + 'ing'
        }
        elseif ($v -match 'e$') {
            $stem = $v.Substring(0, $v.Length - 1)
            $past = $v + 'd'; $third = $v + 's'; $ing = $stem + 'ing'
        }
        elseif ($v -match '(s|x|ch|sh)$') {
            $past = $v + 'ed'; $third = $v + 'es'; $ing = $v + 'ing'
        }
        else {
            $past = $v + 'ed'; $third = $v + 's'; $ing = $v + 'ing'
        }
        foreach ($form in @($past, $third, $ing)) {
            if (-not $map.ContainsKey($form)) { $map[$form] = $v }
        }
    }
    $map['setting'] = 'set'
    $map['splitting'] = 'split'
    $map['built'] = 'build'
    $map['made'] = 'make'
    $map['rewrote'] = 'rewrite'
    $map['rewritten'] = 'rewrite'
    return $map
}

function Set-ImperativeSubject {
    # Models often answer in the past tense ("added x"); Conventional Commits expects "add x".
    param([string]$Text)
    if ($Lang -ne 'en' -or [string]::IsNullOrWhiteSpace($Text)) { return $Text }
    if (-not $script:ImperativeMap) { $script:ImperativeMap = Get-ImperativeMap }

    $m = [regex]::Match($Text, '^((?:[a-z]+(?:\([^)]*\))?!?:\s*)?)([A-Za-z]+)(.*)$')
    if (-not $m.Success) { return $Text }

    $word = $m.Groups[2].Value.ToLowerInvariant()
    if ($script:ImperativeMap.ContainsKey($word)) {
        return $m.Groups[1].Value + $script:ImperativeMap[$word] + $m.Groups[3].Value
    }
    return $Text
}

# ---------------------------------------------------------------------------
# Repository helpers shared by all commands
# ---------------------------------------------------------------------------

function Write-Banner {
    param([string]$Subtitle)
    Write-Host ''
    Write-Host 'AI Git Flow' -ForegroundColor Cyan
    Write-Host $Subtitle -ForegroundColor DarkGray
}

function Enter-Repository {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git не найден в PATH.' }
    $inside = Invoke-Git -GitArgs @('rev-parse', '--is-inside-work-tree')
    if ($inside.ExitCode -ne 0) { throw 'Текущая папка не является Git-репозиторием.' }
    $root = (Invoke-GitChecked -GitArgs @('rev-parse', '--show-toplevel')).Out.Trim()
    Push-Location -LiteralPath $root
    return $root
}

function Confirm-Overwrite {
    param([string]$Name)
    if ($Force) { return $true }
    $answer = Read-Host ('Файл {0} уже существует. Перезаписать? [y/N]' -f $Name)
    return ($answer -match '^(y|yes|д|да)$')
}

function Get-RepositoryFiles {
    $result = Invoke-GitChecked -GitArgs @('ls-files', '--cached', '--others', '--exclude-standard', '-z')
    return @($result.Out.Split([char]0) | Where-Object { $_ })
}

function Resolve-GitUserName {
    $result = Invoke-Git -GitArgs @('config', 'user.name')
    if ($result.ExitCode -eq 0 -and $result.Out.Trim()) { return $result.Out.Trim() }
    return $null
}

# ---------------------------------------------------------------------------
# License
# ---------------------------------------------------------------------------

function Resolve-LicenseKey {
    param([string]$Requested)
    $keys = @($script:LicenseCatalog.Keys)

    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $key = $Requested.Trim().ToLowerInvariant()
        $aliases = @{
            'apache' = 'apache-2.0'; 'apache2' = 'apache-2.0'; 'gpl' = 'gpl-3.0'; 'agpl' = 'agpl-3.0'
            'lgpl' = 'lgpl-3.0'; 'mpl' = 'mpl-2.0'; 'bsd' = 'bsd-3-clause'; 'bsd-3' = 'bsd-3-clause'; 'bsd-2' = 'bsd-2-clause'
        }
        if ($aliases.ContainsKey($key)) { $key = $aliases[$key] }
        if ($keys -contains $key) { return $key }
        throw ('Неизвестный тип лицензии "{0}". Доступно: {1}' -f $Requested, ($keys -join ', '))
    }

    Write-Host ''
    $index = 1
    foreach ($key in $keys) {
        Write-Host ('{0,2}. ' -f $index) -NoNewline -ForegroundColor DarkGray
        Write-Host ('{0,-14}' -f $key) -NoNewline -ForegroundColor White
        Write-Host $script:LicenseCatalog[$key].Description -ForegroundColor Gray
        $index++
    }
    Write-Host ''
    $answer = Read-Host 'Номер лицензии'
    $number = 0
    if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt 1 -or $number -gt $keys.Count) {
        throw 'Некорректный выбор лицензии.'
    }
    return $keys[$number - 1]
}

function Get-LicenseText {
    param([string]$Key, [int]$YearValue, [string]$Holder)

    if ($script:LicenseTemplates.ContainsKey($Key)) {
        $body = $script:LicenseTemplates[$Key]
    }
    else {
        try {
            $response = Invoke-WebRequest -Uri ('https://api.github.com/licenses/' + $Key) -UserAgent 'ai-flow' `
                -Headers @{ Accept = 'application/vnd.github+json' } -UseBasicParsing -TimeoutSec 30
            $json = [System.Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray()) | ConvertFrom-Json
            $body = [string]$json.body
        }
        catch {
            throw ('Не удалось загрузить текст лицензии {0} с GitHub: {1} Попробуйте -UseSystemProxy или лицензию MIT, BSD, ISC, Unlicense (они работают офлайн).' -f $Key, $_.Exception.Message)
        }
        if ([string]::IsNullOrWhiteSpace($body)) { throw 'GitHub вернул пустой текст лицензии.' }
    }

    $body = $body.Replace('[year]', [string]$YearValue).Replace('[fullname]', $Holder)
    $body = ($body -replace "`r`n", "`n").TrimEnd() + "`n"
    return $body
}

function Start-License {
    Write-Banner -Subtitle 'Создание файла лицензии'
    $root = Enter-Repository
    try {
        $key = Resolve-LicenseKey -Requested $Type

        $holder = $Author
        if ([string]::IsNullOrWhiteSpace($holder)) { $holder = Resolve-GitUserName }
        if ([string]::IsNullOrWhiteSpace($holder)) { $holder = Read-Host 'Правообладатель (имя автора)' }
        if ([string]::IsNullOrWhiteSpace($holder)) { throw 'Правообладатель не указан.' }

        $text = Get-LicenseText -Key $key -YearValue $Year -Holder $holder.Trim()

        if ($DryRun) {
            Write-Section 'Предпросмотр (DryRun)'
            Write-Host $text
            return 0
        }

        $target = 'LICENSE'
        foreach ($candidate in @('LICENSE', 'LICENSE.md', 'LICENSE.txt')) {
            if (Test-Path -LiteralPath (Join-Path $root $candidate)) { $target = $candidate; break }
        }
        $path = Join-Path $root $target
        if ((Test-Path -LiteralPath $path) -and -not (Confirm-Overwrite -Name $target)) {
            Write-Info 'Операция отменена.'
            return 0
        }

        [System.IO.File]::WriteAllText($path, $text, $script:Utf8NoBom)
        Write-Ok ('Файл {0} создан: лицензия {1}, правообладатель {2}, год {3}' -f $target, $key, $holder.Trim(), $Year)
        Write-Info 'Закоммитить и отправить файл можно командой: aiflow'
        return 0
    }
    finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# README
# ---------------------------------------------------------------------------

function Format-ProjectTree {
    param([string[]]$Files)

    $tee = ([string][char]0x251C) + (([string][char]0x2500) * 2) + ' '
    $elbow = ([string][char]0x2514) + (([string][char]0x2500) * 2) + ' '
    $pipe = ([string][char]0x2502) + '   '

    $skip = '(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|composer\.lock|poetry\.lock|Cargo\.lock|go\.sum|\.gitattributes)$'
    $paths = @($Files | Where-Object { $_ -notmatch $skip })

    $top = [ordered]@{}
    foreach ($path in $paths) {
        $parts = $path.Split('/')
        $first = $parts[0]
        if ($parts.Length -eq 1) {
            if (-not $top.Contains($first)) { $top[$first] = $null }
            continue
        }
        if (-not $top.Contains($first) -or $null -eq $top[$first]) {
            $top[$first] = New-Object System.Collections.Specialized.OrderedDictionary
        }
        $second = $parts[1]
        if ($parts.Length -gt 2) { $second = $second + '/' }
        if (-not $top[$first].Contains($second)) { $top[$first].Add($second, $true) }
    }

    $names = @($top.Keys | Sort-Object @{ Expression = { $null -eq $top[$_] } }, @{ Expression = { $_ } })
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('.')

    $limit = 25
    $shown = @($names | Select-Object -First $limit)
    for ($i = 0; $i -lt $shown.Count; $i++) {
        $name = $shown[$i]
        $isLast = ($i -eq $shown.Count - 1) -and ($names.Count -le $limit)
        $branch = $tee
        if ($isLast) { $branch = $elbow }

        $children = $top[$name]
        if ($null -eq $children) {
            $lines.Add($branch + $name)
            continue
        }
        $lines.Add($branch + $name + '/')

        $childPrefix = $pipe
        if ($isLast) { $childPrefix = '    ' }
        $childNames = @($children.Keys | Sort-Object @{ Expression = { -not $_.EndsWith('/') } }, @{ Expression = { $_ } })
        $childShown = @($childNames | Select-Object -First 8)
        for ($j = 0; $j -lt $childShown.Count; $j++) {
            $childLast = ($j -eq $childShown.Count - 1) -and ($childNames.Count -le 8)
            $childBranch = $tee
            if ($childLast) { $childBranch = $elbow }
            $lines.Add($childPrefix + $childBranch + $childShown[$j])
        }
        if ($childNames.Count -gt 8) { $lines.Add($childPrefix + $elbow + '...') }
    }
    if ($names.Count -gt $limit) { $lines.Add($elbow + '...') }
    return ($lines -join "`n")
}

function Get-ProjectInfo {
    param([string]$Root, [string[]]$Files)

    $description = $null
    $languages = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.List[string]
    $prereqs = New-Object System.Collections.Generic.List[string]
    $install = New-Object System.Collections.Generic.List[string]
    $usage = New-Object System.Collections.Generic.List[object]

    $extMap = @{
        '.ts' = 'TypeScript'; '.tsx' = 'TypeScript'; '.js' = 'JavaScript'; '.jsx' = 'JavaScript'; '.mjs' = 'JavaScript'
        '.vue' = 'Vue'; '.py' = 'Python'; '.cs' = 'C#'; '.php' = 'PHP'; '.java' = 'Java'; '.go' = 'Go'; '.rs' = 'Rust'
        '.html' = 'HTML'; '.css' = 'CSS'; '.scss' = 'Sass'; '.sass' = 'Sass'; '.sql' = 'SQL'; '.ps1' = 'PowerShell'
    }
    $counts = @{}
    foreach ($file in $Files) {
        $ext = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
        if ($extMap.ContainsKey($ext)) {
            $lang = $extMap[$ext]
            if ($counts.ContainsKey($lang)) { $counts[$lang] = $counts[$lang] + 1 } else { $counts[$lang] = 1 }
        }
    }
    foreach ($entry in @($counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 6)) {
        $languages.Add($entry.Key)
    }

    if ($Files -contains 'package.json') {
        try {
            $pkg = Get-Content -LiteralPath (Join-Path $Root 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($pkg.description) { $description = [string]$pkg.description }

            $depNames = @()
            foreach ($section in @('dependencies', 'devDependencies')) {
                $block = $pkg.$section
                if ($block) { $depNames += @($block.PSObject.Properties.Name) }
            }
            $stackMap = [ordered]@{
                'react' = 'React'; 'vue' = 'Vue'; 'svelte' = 'Svelte'; '@angular/core' = 'Angular'; 'next' = 'Next.js'
                'nuxt' = 'Nuxt'; 'typescript' = 'TypeScript'; 'vite' = 'Vite'; 'webpack' = 'webpack'; 'express' = 'Express'
                'tailwindcss' = 'Tailwind CSS'; 'sass' = 'Sass'; 'react-router-dom' = 'React Router'; 'pinia' = 'Pinia'
                'vuex' = 'Vuex'; '@reduxjs/toolkit' = 'Redux Toolkit'; 'redux' = 'Redux'; 'axios' = 'Axios'; 'swiper' = 'Swiper'
                'three' = 'Three.js'; 'vitest' = 'Vitest'; 'jest' = 'Jest'; 'eslint' = 'ESLint'; 'prettier' = 'Prettier'
            }
            foreach ($dep in $stackMap.Keys) {
                if ($depNames -contains $dep) { $stack.Add($stackMap[$dep]) }
            }

            $pm = 'npm'
            if ($Files -contains 'yarn.lock') { $pm = 'yarn' }
            elseif ($Files -contains 'pnpm-lock.yaml') { $pm = 'pnpm' }
            $prereqs.Add('Node.js (LTS)')
            $install.Add($pm + ' install')

            $scriptNames = @()
            if ($pkg.scripts) { $scriptNames = @($pkg.scripts.PSObject.Properties.Name) }
            $wanted = @(
                @{ Label = 'Dev'; Names = @('dev', 'start', 'serve') },
                @{ Label = 'Build'; Names = @('build') },
                @{ Label = 'Test'; Names = @('test') },
                @{ Label = 'Lint'; Names = @('lint') }
            )
            foreach ($item in $wanted) {
                foreach ($scriptName in $item.Names) {
                    if ($scriptNames -contains $scriptName) {
                        if ($pm -eq 'npm') {
                            if ($scriptName -eq 'start' -or $scriptName -eq 'test') { $command = 'npm ' + $scriptName }
                            else { $command = 'npm run ' + $scriptName }
                        }
                        else { $command = $pm + ' ' + $scriptName }
                        $usage.Add([pscustomobject]@{ LabelKey = $item.Label; Command = $command })
                        break
                    }
                }
            }
        }
        catch { }
    }

    if ($Files -contains 'requirements.txt') {
        $prereqs.Add('Python 3')
        $install.Add('pip install -r requirements.txt')
    }
    foreach ($entry in @('main.py', 'app.py')) {
        if ($Files -contains $entry) {
            $usage.Add([pscustomobject]@{ LabelKey = 'Run'; Command = ('python ' + $entry) })
            break
        }
    }
    if (@($Files | Where-Object { $_ -match '\.(csproj|sln)$' }).Count -gt 0) {
        $prereqs.Add('.NET SDK')
        $install.Add('dotnet restore')
        $usage.Add([pscustomobject]@{ LabelKey = 'Build'; Command = 'dotnet build' })
        $usage.Add([pscustomobject]@{ LabelKey = 'Run'; Command = 'dotnet run' })
    }
    if ($Files -contains 'composer.json') {
        $prereqs.Add('PHP, Composer')
        $install.Add('composer install')
    }
    if ($usage.Count -eq 0 -and $install.Count -eq 0 -and ($Files -contains 'index.html')) {
        $usage.Add([pscustomobject]@{ LabelKey = 'OpenHtml'; Command = '' })
    }

    if (@($Files | Where-Object { $_ -match '(^|/)dockerfile' }).Count -gt 0) { $stack.Add('Docker') }
    if (@($Files | Where-Object { $_ -match '^\.github/workflows/' }).Count -gt 0) { $stack.Add('GitHub Actions') }

    $combined = New-Object System.Collections.Generic.List[string]
    foreach ($item in (@($languages) + @($stack))) {
        if ($combined -notcontains $item) { $combined.Add($item) }
    }

    return [pscustomobject]@{
        Name        = (Split-Path -Leaf $Root)
        Description = $description
        Stack       = @($combined | Select-Object -First 12)
        Prereqs     = @($prereqs)
        Install     = @($install)
        Usage       = @($usage)
    }
}

function Get-ProjectExcerpt {
    param([string]$Root, [string[]]$Files)
    $patterns = @('^index\.html$', '^src/main\.[a-z]+$', '^src/index\.[a-z]+$', '^src/App\.[a-z]+$', '^(main|app)\.py$', '^(index|server|app)\.js$', '^Program\.cs$')
    $chosen = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $patterns) {
        if ($chosen.Count -ge 3) { break }
        $match = @($Files | Where-Object { $_ -match $pattern } | Select-Object -First 1)
        if ($match.Count -gt 0 -and $match[0]) { $chosen.Add($match[0]) }
    }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($file in $chosen) {
        try {
            $text = (Get-Content -LiteralPath (Join-Path $Root $file) -TotalCount 60 -Encoding UTF8) -join "`n"
            if ($text.Length -gt 1500) { $text = $text.Substring(0, 1500) }
            $parts.Add('--- ' + $file + ' ---' + "`n" + $text)
        }
        catch { }
    }
    return ($parts -join "`n`n")
}

function Get-ReadmeStrings {
    if ($Lang -eq 'ru') {
        return @{
            Features = 'Возможности'; Stack = 'Стек технологий'; Start = 'Быстрый старт'; Prereq = 'Требования'
            Install = 'Установка'; Usage = 'Использование'; Structure = 'Структура проекта'; License = 'Лицензия'
            Dev = 'Запуск в режиме разработки'; Build = 'Сборка'; Test = 'Тесты'; Lint = 'Проверка кода'; Run = 'Запуск'
            OpenHtml = 'Откройте файл index.html в браузере'
            Licensed = 'Распространяется под лицензией {0}. Подробности в файле [{1}]({1}).'
            LicenseRef = 'Подробности в файле [{0}]({0}).'
            Fallback = 'Проект {0}.'
        }
    }
    return @{
        Features = 'Features'; Stack = 'Tech stack'; Start = 'Getting started'; Prereq = 'Prerequisites'
        Install = 'Installation'; Usage = 'Usage'; Structure = 'Project structure'; License = 'License'
        Dev = 'Development server'; Build = 'Build'; Test = 'Tests'; Lint = 'Linting'; Run = 'Run'
        OpenHtml = 'Open index.html in a browser'
        Licensed = 'Distributed under the {0}. See [{1}]({1}) for details.'
        LicenseRef = 'See [{0}]({0}) for details.'
        Fallback = 'The {0} project.'
    }
}

function Get-ReadmeNarrative {
    param($Info, [string]$Tree, [string]$Excerpt)

    $treeText = $Tree
    if ($treeText.Length -gt 3000) { $treeText = $treeText.Substring(0, 3000) }

    $prompt = (@(
        'Analyse the repository summary below and write two things for its README file.',
        'Output format, plain text without markdown headings:',
        'DESCRIPTION: one or two sentences describing what the project is and does.',
        'FEATURES:',
        '- three to six short bullet points describing what the project offers',
        'Rules:',
        'Describe only what is visible in the input. Do not invent features, URLs, badges, authors or installation steps.',
        'If the purpose is unclear, state what the files show (for example, a static website built with HTML and CSS) and use fewer bullet points.',
        ('Language: {0}.' -f (Get-LanguageName)),
        '',
        ('Project name: ' + $Info.Name),
        ('Technologies detected: ' + ($Info.Stack -join ', ')),
        ('Existing description: ' + $Info.Description),
        '',
        'File tree:',
        $treeText,
        '',
        'Key file excerpts:',
        $Excerpt
    )) -join "`n"

    $system = 'You write accurate, concise README content for software projects. You never invent facts.'
    try {
        $answer = Invoke-GigaChat -SystemPrompt $system -UserPrompt $prompt -ModelName $PrModel -MaxTokens 500
    }
    catch {
        Write-Warn ('Не удалось сгенерировать описание: {0}' -f $_.Exception.Message)
        return [pscustomobject]@{ Description = $null; Features = @() }
    }

    $description = $null
    if ($answer -match '(?is)DESCRIPTION:\s*(.+?)\s*(?:FEATURES:|$)') { $description = $Matches[1].Trim() }
    $features = @($answer -split "`r?`n" |
        Where-Object { $_ -match '^\s*(?:[-*]|\d+\.)\s+\S' } |
        ForEach-Object { ($_ -replace '^\s*(?:[-*]|\d+\.)\s+', '').Trim() } |
        Select-Object -First 6)
    return [pscustomobject]@{ Description = $description; Features = $features }
}

function New-ReadmeText {
    param($Info, $Narrative, [string]$Tree, [string[]]$Files, [string]$Root)

    $s = Get-ReadmeStrings
    $out = New-Object System.Collections.Generic.List[string]

    $out.Add('# ' + $Info.Name)
    $out.Add('')
    $description = $Info.Description
    if ([string]::IsNullOrWhiteSpace($description)) { $description = $Narrative.Description }
    if ([string]::IsNullOrWhiteSpace($description)) { $description = $s.Fallback -f $Info.Name }
    $out.Add($description)
    $out.Add('')

    if (@($Narrative.Features).Count -gt 0) {
        $out.Add('## ' + $s.Features)
        $out.Add('')
        foreach ($feature in $Narrative.Features) { $out.Add('- ' + $feature) }
        $out.Add('')
    }

    if (@($Info.Stack).Count -gt 0) {
        $out.Add('## ' + $s.Stack)
        $out.Add('')
        foreach ($item in $Info.Stack) { $out.Add('- ' + $item) }
        $out.Add('')
    }

    $remote = Invoke-Git -GitArgs @('remote', 'get-url', $Remote)
    $cloneUrl = $null
    if ($remote.ExitCode -eq 0 -and $remote.Out.Trim()) {
        # Never publish credentials embedded in a remote URL.
        $cloneUrl = ($remote.Out.Trim() -replace '(?<=//)[^/@]+@', '')
    }

    $hasSteps = (@($Info.Install).Count -gt 0) -or (@($Info.Usage).Count -gt 0)
    if ($hasSteps) {
        $out.Add('## ' + $s.Start)
        $out.Add('')
        if (@($Info.Prereqs).Count -gt 0) {
            $out.Add('### ' + $s.Prereq)
            $out.Add('')
            $out.Add('- Git')
            foreach ($item in $Info.Prereqs) { $out.Add('- ' + $item) }
            $out.Add('')
        }
        if ($cloneUrl -or @($Info.Install).Count -gt 0) {
            $out.Add('### ' + $s.Install)
            $out.Add('')
            $out.Add('```bash')
            if ($cloneUrl) {
                $out.Add('git clone ' + $cloneUrl)
                $out.Add('cd ' + (Split-Path -Leaf $Root))
            }
            foreach ($command in $Info.Install) { $out.Add($command) }
            $out.Add('```')
            $out.Add('')
        }
        if (@($Info.Usage).Count -gt 0) {
            $out.Add('### ' + $s.Usage)
            $out.Add('')
            foreach ($entry in $Info.Usage) {
                if ($entry.Command) { $out.Add('- ' + $s[$entry.LabelKey] + ': `' + $entry.Command + '`') }
                else { $out.Add('- ' + $s[$entry.LabelKey]) }
            }
            $out.Add('')
        }
    }

    $out.Add('## ' + $s.Structure)
    $out.Add('')
    $out.Add('```text')
    $out.Add($Tree)
    $out.Add('```')
    $out.Add('')

    $licenseFile = $null
    foreach ($candidate in @('LICENSE', 'LICENSE.md', 'LICENSE.txt')) {
        if ($Files -contains $candidate) { $licenseFile = $candidate; break }
    }
    if ($licenseFile) {
        $out.Add('## ' + $s.License)
        $out.Add('')
        $licenseName = $null
        try {
            $firstLine = @(Get-Content -LiteralPath (Join-Path $Root $licenseFile) -TotalCount 5 -Encoding UTF8 |
                Where-Object { $_.Trim() } | Select-Object -First 1)
            if ($firstLine.Count -gt 0) {
                $candidateName = $firstLine[0].Trim()
                if ($candidateName -match 'unencumbered') { $licenseName = 'Unlicense' }
                elseif ($candidateName.Length -le 60) { $licenseName = $candidateName }
            }
        }
        catch { }
        if ($licenseName) { $out.Add(($s.Licensed -f $licenseName, $licenseFile)) }
        else { $out.Add(($s.LicenseRef -f $licenseFile)) }
        $out.Add('')
    }

    return (($out -join "`n").TrimEnd() + "`n")
}

function Start-Readme {
    Write-Banner -Subtitle 'Генерация README.md'
    $root = Enter-Repository
    try {
        Write-Section '1. Анализ проекта'
        $files = @(Get-RepositoryFiles)
        if ($files.Count -eq 0) { throw 'В репозитории нет файлов для анализа.' }
        $info = Get-ProjectInfo -Root $root -Files $files
        $tree = Format-ProjectTree -Files $files
        $excerpt = Get-ProjectExcerpt -Root $root -Files $files
        Write-Info ('Файлов: {0}. Обнаружено технологий: {1}' -f $files.Count, @($info.Stack).Count)

        Write-Section '2. Генерация описания'
        Write-Info 'Авторизация в GigaChat...'
        Get-AccessToken | Out-Null
        $narrative = Get-ReadmeNarrative -Info $info -Tree $tree -Excerpt $excerpt
        $text = New-ReadmeText -Info $info -Narrative $narrative -Tree $tree -Files $files -Root $root

        if ($DryRun) {
            Write-Section 'Предпросмотр (DryRun)'
            Write-Host $text
            return 0
        }

        $path = Join-Path $root 'README.md'
        if ((Test-Path -LiteralPath $path) -and -not (Confirm-Overwrite -Name 'README.md')) {
            Write-Info 'Операция отменена. Предпросмотр можно получить с параметром -DryRun.'
            return 0
        }
        [System.IO.File]::WriteAllText($path, $text, $script:Utf8NoBom)
        Write-Ok 'Файл README.md создан.'
        Write-Info 'Проверьте текст и при необходимости отредактируйте, затем выполните: aiflow'
        return 0
    }
    finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# Issue
# ---------------------------------------------------------------------------

function Start-Issue {
    Write-Banner -Subtitle 'Создание issue на GitHub'
    $root = Enter-Repository
    try {
        $request = $Text
        if ([string]::IsNullOrWhiteSpace($request)) { $request = Read-Host 'Опишите проблему или задачу' }
        if ([string]::IsNullOrWhiteSpace($request)) { throw 'Описание не указано.' }
        $request = $request.Trim()

        Write-Info 'Авторизация в GigaChat...'
        Get-AccessToken | Out-Null

        $branchName = (Invoke-Git -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD')).Out.Trim()
        $recent = (Invoke-Git -GitArgs @('log', '-5', '--pretty=format:%s')).Out
        $topLevel = @(Get-RepositoryFiles | ForEach-Object { $_.Split('/')[0] } | Select-Object -Unique | Select-Object -First 40)

        $prompt = (@(
            'Turn the developer note below into a GitHub issue.',
            'Output format, plain text, no code fences:',
            'TYPE: one of bug, feature, task',
            'TITLE: a concise title, at most 80 characters, no trailing period',
            'BODY:',
            '<issue body in markdown>',
            'Body structure:',
            '- bug: "## Description", "## Steps to reproduce", "## Expected behavior", "## Actual behavior"',
            '- feature: "## Description", "## Motivation", "## Acceptance criteria" as a checklist',
            '- task: "## Description", "## Tasks" as a checklist, "## Acceptance criteria" as a checklist',
            'Rules:',
            'Use only facts from the note. Where details are unknown, write "To be clarified." instead of inventing them.',
            ('Language: {0}. Keep markdown headings in English.' -f (Get-LanguageName)),
            '',
            'Developer note:',
            $request,
            '',
            ('Current branch: ' + $branchName),
            'Recent commits:',
            $recent,
            ('Top-level files and folders: ' + ($topLevel -join ', '))
        )) -join "`n"

        $system = 'You are a careful engineering assistant who writes clear, factual GitHub issues.'
        $answer = $null
        try { $answer = Invoke-GigaChat -SystemPrompt $system -UserPrompt $prompt -ModelName $PrModel -MaxTokens 700 }
        catch { Write-Warn ('Не удалось сгенерировать issue: {0}' -f $_.Exception.Message) }

        $type = 'task'
        $title = $null
        $body = $null
        if ($answer) {
            if ($answer -match '(?im)^\s*TYPE:\s*(\w+)') {
                $candidateType = $Matches[1].ToLowerInvariant()
                if (@('bug', 'feature', 'task') -contains $candidateType) { $type = $candidateType }
            }
            if ($answer -match '(?im)^\s*TITLE:\s*(.+)$') { $title = $Matches[1].Trim() }

            $lines = @($answer -split "`r?`n")
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^\s*BODY:\s*(.*)$') {
                    $rest = New-Object System.Collections.Generic.List[string]
                    if ($Matches[1]) { $rest.Add($Matches[1]) }
                    foreach ($line in @($lines | Select-Object -Skip ($i + 1))) { $rest.Add($line) }
                    $body = ($rest -join "`n").Trim()
                    $body = $body -replace '^```(?:markdown|md)?\s*\n', '' -replace '\n```\s*$', ''
                    break
                }
            }
        }
        if ($title) {
            $title = $title.Trim().Trim([char]34, [char]39, [char]96).TrimEnd('.')
            if ($title.Length -gt 80) { $title = $title.Substring(0, 80).Trim() }
        }
        if (-not $title) {
            $title = $request
            if ($title.Length -gt 70) { $title = $title.Substring(0, 70).Trim() }
        }
        if ([string]::IsNullOrWhiteSpace($body)) { $body = $request }

        $labels = @()
        if ($Labels) { $labels = @($Labels | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        elseif ($type -eq 'bug') { $labels = @('bug') }
        elseif ($type -eq 'feature') { $labels = @('enhancement') }

        Write-Section 'Issue'
        Write-Host $title -ForegroundColor White
        if ($labels.Count -gt 0) { Write-Host ('Метки: ' + ($labels -join ', ')) -ForegroundColor DarkGray }
        Write-Host ''
        Write-Host $body
        Write-Host ''

        if ($DryRun) {
            Write-Info 'Режим DryRun: issue не создан.'
            return 0
        }
        if (-not $Yes) {
            $confirm = Read-Host 'Создать issue? [Y/n]'
            if ($confirm -match '^(n|no|н|нет)$') {
                Write-Info 'Операция отменена.'
                return 0
            }
        }

        $gh = Get-Command gh -ErrorAction SilentlyContinue
        $authenticated = $false
        if ($gh) { $authenticated = ((Invoke-Native -Exe 'gh' -ArgList @('auth', 'status')).ExitCode -eq 0) }
        if (-not $gh -or -not $authenticated) {
            if (-not $gh) { Write-Warn 'GitHub CLI (gh) не найден. Установите его: https://cli.github.com' }
            else { Write-Warn 'GitHub CLI не авторизован. Выполните: gh auth login' }
            Write-Info 'Текст выше можно использовать для ручного создания issue.'
            return 0
        }

        $bodyFile = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllText($bodyFile, ($body + "`n"), $script:Utf8NoBom)
            $ghArgs = @('issue', 'create', '--title', $title, '--body-file', $bodyFile)
            foreach ($label in $labels) { $ghArgs += @('--label', $label) }
            $created = Invoke-Native -Exe 'gh' -ArgList $ghArgs

            if ($created.ExitCode -ne 0 -and $labels.Count -gt 0 -and (($created.Err + $created.Out) -match 'label')) {
                Write-Warn 'Метки отсутствуют в репозитории. Повторная попытка без меток.'
                $ghArgs = @('issue', 'create', '--title', $title, '--body-file', $bodyFile)
                $created = Invoke-Native -Exe 'gh' -ArgList $ghArgs
            }
            if ($created.ExitCode -ne 0) {
                $details = $created.Err
                if (-not $details) { $details = $created.Out }
                throw ('Не удалось создать issue: {0}' -f $details)
            }
            $url = @($created.Out -split "`r?`n" | Where-Object { $_ -match '^https?://' } | Select-Object -Last 1)[0]
            if ($url) { Write-Ok ('Issue создан: {0}' -f $url) } else { Write-Ok 'Issue создан.' }
        }
        finally {
            Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
        }
        return 0
    }
    finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Start-AiFlow {
    if (-not $UseSystemProxy) {
        # Stale proxy entries left by VPN clients break direct access to GigaChat.
        [System.Net.WebRequest]::DefaultWebProxy = $null
    }
    if ($SkipCertCheck) {
        Enable-InsecureCertificates
        Write-Warn 'Проверка TLS-сертификатов отключена.'
    }

    Write-Host ''
    Write-Host 'AI Git Flow' -ForegroundColor Cyan
    Write-Host 'Ветка, коммиты и pull request на основе GigaChat' -ForegroundColor DarkGray

    $root = Enter-Repository
    try {
        # 1. Analysis
        Write-Section '1. Анализ изменений'
        $changes = Get-ChangedFiles
        if ($changes.Count -eq 0) {
            Write-Ok 'Нет изменений для коммита.'
            return 0
        }
        Write-Info ('Изменённых файлов: {0}' -f $changes.Count)

        $startBranch = (Invoke-Git -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD')).Out.Trim()
        $baseBranch = $Base
        if ([string]::IsNullOrWhiteSpace($baseBranch)) {
            $baseBranch = Get-DefaultBranch -RemoteName $Remote -Fallback $startBranch
        }

        Write-Info 'Авторизация в GigaChat...'
        Get-AccessToken | Out-Null
        Write-Ok 'Токен доступа получен.'

        # 2. Plan
        Write-Section '2. Формирование плана'
        $plan = @(New-CommitPlan -Changes $changes -CodeGroupLimit $MaxCodeGroups)
        Write-Info ('Групп: {0}. Модель: {1}' -f $plan.Count, $Model)

        # The index is rebuilt per group during execution; here it only serves diff generation.
        Invoke-GitChecked -GitArgs @('reset', '-q') | Out-Null
        Invoke-GitChecked -GitArgs @('add', '-A') | Out-Null
        try {
            $number = 1
            foreach ($group in $plan) {
                Write-Info ('Сообщение {0} из {1}: {2}' -f $number, $plan.Count, $group.Key)
                $group.Message = New-CommitMessage -Group $group
                $number++
            }
        }
        finally {
            Invoke-Git -GitArgs @('reset', '-q') | Out-Null
        }

        Show-Plan -Plan $plan

        if ($DryRun) {
            Write-Info 'Режим DryRun: изменения не внесены.'
            return 0
        }
        if (-not $Yes) {
            $answer = Read-Host 'Выполнить план? [Y/n]'
            if ($answer -match '^(n|no|н|нет)$') {
                Write-Info 'Операция отменена.'
                return 0
            }
        }

        # 3. Branch
        Write-Section '3. Ветка'
        if ($Stay) { $choice = '.' }
        else { $choice = Resolve-BranchName -Requested $Branch -CurrentBranch $startBranch }

        $stayOnBranch = ($choice -eq '.')
        if ($stayOnBranch) {
            if ($startBranch -eq 'HEAD') { throw 'Репозиторий в состоянии detached HEAD. Перейдите на ветку или создайте новую.' }
            $branchName = $startBranch
            Write-Info ('Остаёмся в ветке {0}, новая ветка не создаётся.' -f $branchName)
        }
        else {
            $branchName = $choice
            Invoke-GitChecked -GitArgs @('switch', '-c', $branchName) | Out-Null
            Write-Ok ('Создана ветка {0}' -f $branchName)
        }

        # 4. Commits
        Write-Section '4. Коммиты'
        $created = 0
        foreach ($group in $plan) {
            Add-GitPaths -Paths @($group.Paths)

            $messageFile = [System.IO.Path]::GetTempFileName()
            try {
                [System.IO.File]::WriteAllText($messageFile, ($group.Message + "`n"), $script:Utf8NoBom)
                $commit = Invoke-Git -GitArgs @('commit', '-q', '-F', $messageFile)
            }
            finally {
                Remove-Item -LiteralPath $messageFile -Force -ErrorAction SilentlyContinue
            }

            if ($commit.ExitCode -ne 0) {
                $text = $commit.Out + "`n" + $commit.Err
                if ($text -match 'nothing (added )?to commit|no changes added') {
                    Write-Warn ('Пропущено (нет изменений): {0}' -f $group.Message)
                    continue
                }
                throw ('Не удалось создать коммит "{0}": {1}' -f $group.Message, $text.Trim())
            }
            $created++
            Write-Ok $group.Message
        }

        $left = Get-ChangedFiles
        if ($left.Count -gt 0) {
            Write-Warn ('Остались незафиксированные файлы: {0}. Проверьте git status.' -f $left.Count)
        }

        # 5. Push
        $remoteExists = ((Invoke-Git -GitArgs @('remote', 'get-url', $Remote)).ExitCode -eq 0)
        if ($NoPush) {
            Write-Info 'Отправка пропущена (параметр -NoPush).'
        }
        elseif (-not $remoteExists) {
            Write-Warn ('Удалённый репозиторий "{0}" не настроен. Отправка пропущена.' -f $Remote)
        }
        else {
            Write-Section '5. Отправка'
            Invoke-GitChecked -GitArgs @('push', '-u', $Remote, $branchName) | Out-Null
            Write-Ok ('Ветка {0} отправлена в {1}' -f $branchName, $Remote)

            if ($stayOnBranch) {
                Write-Info 'Pull request не создаётся при работе в текущей ветке.'
            }
            elseif (-not $NoPr) {
                New-PullRequest -BranchName $branchName -BaseBranch $baseBranch
            }
        }

        Write-Section 'Итог'
        Write-Info ('Ветка: {0}' -f $branchName)
        Write-Info ('Создано коммитов: {0}' -f $created)
        return 0
    }
    finally {
        Pop-Location
    }
}

Initialize-Console

# Defaults from the configuration file; command line parameters always win.
$configPath = Get-ConfigPath
if (Test-Path -LiteralPath $configPath) {
    try {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($property in $config.PSObject.Properties) {
            if ($script:ConfigKeys -contains $property.Name -and -not $PSBoundParameters.ContainsKey($property.Name)) {
                Set-Variable -Name $property.Name -Value $property.Value
            }
        }
    }
    catch {
        Write-Warn ('Не удалось прочитать файл настроек {0}: {1}' -f $configPath, $_.Exception.Message)
    }
}

try {
    if ($Help -or $Command -eq 'help') { Show-Help; exit 0 }
    if ($SetKey) { Save-AuthKey; exit 0 }
    if ($InitConfig) { Initialize-Config; exit 0 }

    if (-not $UseSystemProxy) { [System.Net.WebRequest]::DefaultWebProxy = $null }
    if ($SkipCertCheck -and $Command -ne 'commit') { Enable-InsecureCertificates }

    switch ($Command) {
        'readme'  { $exitCode = Start-Readme | Select-Object -Last 1 }
        'license' { $exitCode = Start-License | Select-Object -Last 1 }
        'issue'   { $exitCode = Start-Issue | Select-Object -Last 1 }
        default   { $exitCode = Start-AiFlow | Select-Object -Last 1 }
    }
    if ($null -eq $exitCode) { $exitCode = 0 }
}
catch {
    Write-Err $_.Exception.Message
    $exitCode = 1
}
exit ([int]$exitCode)
