<#
.SYNOPSIS
    Automated Git workflow: branch, grouped commits, push and pull request, powered by GigaChat.

.DESCRIPTION
    The script splits working tree changes into logical commits and writes commit messages
    and a pull request description with the GigaChat API.

    Division of responsibilities:
      * Grouping of files is deterministic (rules by file type and directory), done by the script.
      * The language model only writes short texts: a commit subject per group and a PR summary.

    Steps: analysis -> plan -> confirmation -> branch -> commits -> push -> pull request (GitHub CLI).

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

.PARAMETER NoProxy
    Ignore the system proxy settings. Helps when a stale proxy is left behind by a VPN client.

.EXAMPLE
    .\ai-flow.ps1
    .\ai-flow.ps1 -Branch feat/home-swiper -Lang ru -Draft
    .\ai-flow.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$Branch,
    [string]$Base,
    [string]$Remote = 'origin',
    [string]$Model = 'GigaChat-2',
    [string]$PrModel = 'GigaChat-2-Pro',
    [ValidateSet('en', 'ru')][string]$Lang = 'en',
    [ValidateRange(2, 10)][int]$MaxCodeGroups = 5,
    [ValidateRange(500, 20000)][int]$MaxDiffChars = 6000,
    [switch]$NoPush,
    [switch]$NoPr,
    [switch]$Draft,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$SkipCertCheck,
    [switch]$NoProxy
)

$ErrorActionPreference = 'Stop'

$script:AuthUrl      = 'https://ngw.devices.sberbank.ru:9443/api/v2/oauth'
$script:ChatUrl      = 'https://gigachat.devices.sberbank.ru/api/v1/chat/completions'
$script:Scope        = 'GIGACHAT_API_PERS'
$script:AuthKey      = $null
$script:Token        = $null
$script:TokenExpires = [datetime]::MinValue
$script:Utf8NoBom    = New-Object System.Text.UTF8Encoding($false)

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
                    $hint = ' Если включён или оставался VPN либо прокси, повторите запуск с параметром -NoProxy.'
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
        Write-Info 'Чтобы сохранить ключ навсегда: [Environment]::SetEnvironmentVariable(''GIGACHAT_AUTH_KEY'', ''<ключ>'', ''User'')'
        $secure = Read-Host 'Authorization key GigaChat' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
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
        'Use the imperative mood, start with a lowercase letter, no trailing period.',
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
    return '{0}: {1}' -f $prefix, $subject
}

# ---------------------------------------------------------------------------
# Branch, base and pull request
# ---------------------------------------------------------------------------

function Resolve-BranchName {
    param([string]$Requested)
    $name = $Requested
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = Read-Host 'Имя новой ветки (например, feat/home-swiper)'
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'Имя ветки не указано. Операция отменена.' }
        }
        $name = $name.Trim()

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
# Main
# ---------------------------------------------------------------------------

function Start-AiFlow {
    $console = $script:Utf8NoBom
    try { [Console]::OutputEncoding = $console } catch { }
    $global:OutputEncoding = $console
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    if ($NoProxy) {
        [System.Net.WebRequest]::DefaultWebProxy = $null
        Write-Info 'Системный прокси отключён для этого запуска.'
    }
    if ($SkipCertCheck) {
        Enable-InsecureCertificates
        Write-Warn 'Проверка TLS-сертификатов отключена.'
    }

    Write-Host ''
    Write-Host 'AI Git Flow' -ForegroundColor Cyan
    Write-Host 'Ветка, коммиты и pull request на основе GigaChat' -ForegroundColor DarkGray

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git не найден в PATH.' }
    $inside = Invoke-Git -GitArgs @('rev-parse', '--is-inside-work-tree')
    if ($inside.ExitCode -ne 0) { throw 'Текущая папка не является Git-репозиторием.' }

    $root = (Invoke-GitChecked -GitArgs @('rev-parse', '--show-toplevel')).Out.Trim()
    Push-Location -LiteralPath $root
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
        $branchName = Resolve-BranchName -Requested $Branch
        Invoke-GitChecked -GitArgs @('switch', '-c', $branchName) | Out-Null
        Write-Ok ('Создана ветка {0}' -f $branchName)

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

            if (-not $NoPr) {
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

try {
    $exitCode = Start-AiFlow | Select-Object -Last 1
    if ($null -eq $exitCode) { $exitCode = 0 }
}
catch {
    Write-Err $_.Exception.Message
    $exitCode = 1
}
exit ([int]$exitCode)
