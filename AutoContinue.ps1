#requires -version 5.1
<#
    OpenCode AutoContinue
    ---------------------
    Следит за чатами OpenCode и после каждого завершённого ответа бота
    автоматически отправляет ему заданный текст ("Продолжай разработку").

    - Список чатов живёт по sessionId, поэтому переименование чата ничего не ломает.
    - Новые активные чаты можно подхватывать автоматически (в настройках, по умолчанию выкл).
    - Текст сообщения и список чатов настраиваются прямо в окне и сохраняются
      в settings.json (у .exe — в %APPDATA%\OpenCodeAutoContinue).
    - Лимит запуска: по количеству итераций или до заданного времени.
    - Ошибки не заливают журнал: повторы с паузой, авто-стоп и переподключение.

    Запуск: Запустить.cmd  (или powershell -ExecutionPolicy Bypass -File AutoContinue.ps1)
#>
param(
    [string[]]$ChatTitles = @(),
    [string]$MessageText = 'Продолжай разработку',
    [int]$PollMs = 1200,
    [switch]$StartStopped
)

$ErrorActionPreference = 'Stop'
$script:AppVersion = '1.4.0'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------- service ----

function Get-ServiceInfo {
    $candidates = @(
        (Join-Path $env:USERPROFILE '.local\state\opencode\service.json'),
        (Join-Path $env:LOCALAPPDATA 'opencode\service.json')
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) {
            try { return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json) } catch { }
        }
    }
    return $null
}

function Update-ServiceInfo {
    $svc = Get-ServiceInfo
    if (-not $svc -or -not $svc.url) { return $false }
    $script:BaseUrl = ([string]$svc.url).TrimEnd('/')
    $script:Auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("opencode:$($svc.password)"))
    $script:ServiceVersion = [string]$svc.version
    return $true
}

if (-not (Update-ServiceInfo)) {
    [void][Windows.MessageBox]::Show(
        "Не найден запущенный сервис OpenCode.`n`nЗапустите OpenCode и попробуйте снова.",
        'OpenCode AutoContinue', 'OK', 'Error')
    exit 1
}
$script:ServiceVersion = if ($script:ServiceVersion) { $script:ServiceVersion } else { '' }

# ---- каталог данных: рядом со скриптом, а у .exe — в профиле ----
$exePath = ''
try { $exePath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { }
$isCompiled = ($exePath -match '\.exe$') -and ($exePath -notmatch 'powershell(_ise)?\.exe$')
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($exePath) { Split-Path -Parent $exePath } else { (Get-Location).Path }
$script:ScriptDir = $scriptDir

if ($isCompiled) {
    $appDir = Join-Path $env:APPDATA 'OpenCodeAutoContinue'
}
elseif ($PSScriptRoot) {
    $appDir = $PSScriptRoot
}
else {
    $appDir = Join-Path $env:APPDATA 'OpenCodeAutoContinue'
}
if (-not (Test-Path -LiteralPath $appDir)) {
    [void](New-Item -ItemType Directory -Path $appDir -Force)
}
$script:AppDir = $appDir
$script:SettingsPath = Join-Path $appDir 'settings.json'
$script:LogFile = Join-Path $appDir 'auto-continue.log'

# журнал не должен расти бесконечно: держим один архив и лимит 4 МБ
$script:LogWrites = 0
function Invoke-LogRotation {
    try {
        if (Test-Path -LiteralPath $script:LogFile) {
            if ((Get-Item -LiteralPath $script:LogFile).Length -gt 4MB) {
                Move-Item -LiteralPath $script:LogFile -Destination ($script:LogFile + '.1') -Force
            }
        }
        if (-not (Test-Path -LiteralPath $script:LogFile)) {
            [IO.File]::WriteAllText($script:LogFile, '', (New-Object Text.UTF8Encoding($true)))
        }
    }
    catch { }
}
Invoke-LogRotation
if (-not (Test-Path -LiteralPath $script:LogFile)) {
    try { [IO.File]::WriteAllText($script:LogFile, '', (New-Object Text.UTF8Encoding($true))) } catch { }
}

# первый запуск .exe: подхватываем settings.json, лежащий рядом с exe
if ($isCompiled -and -not (Test-Path -LiteralPath $script:SettingsPath)) {
    $nearby = Join-Path ([IO.Path]::GetDirectoryName($exePath)) 'settings.json'
    if (Test-Path -LiteralPath $nearby) {
        try { Copy-Item -LiteralPath $nearby -Destination $script:SettingsPath -Force } catch { }
    }
}

# ---- один экземпляр на систему ----
$script:AppMutex = $null
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Global\OpenCodeAutoContinue_Kuruma')
    $gotMutex = $false
    try { $gotMutex = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $gotMutex = $true }
    if (-not $gotMutex) {
        [void][Windows.MessageBox]::Show(
            "OpenCode AutoContinue уже запущен.`n`nНайдите его окно в панели задач или значок в трее.",
            'OpenCode AutoContinue', 'OK', 'Information')
        exit 0
    }
    $script:AppMutex = $mutex
}
catch { }

function Invoke-OcApi {
    param([string]$Method, [string]$Path, $Body = $null, [int]$Timeout = 20000)

    $req = [Net.HttpWebRequest]::Create($script:BaseUrl + $Path)
    $req.Method = $Method
    $req.Headers['Authorization'] = 'Basic ' + $script:Auth
    $req.Timeout = $Timeout
    $req.ReadWriteTimeout = $Timeout
    $req.UserAgent = 'OpenCode-AutoContinue/' + $script:AppVersion
    $req.KeepAlive = $false

    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Compress -Depth 5
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $req.ContentType = 'application/json; charset=utf-8'
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
    }

    try {
        $resp = $req.GetResponse()
    }
    catch [Net.WebException] {
        $ex = $_.Exception
        if ($null -ne $ex.Response) {
            $reader = New-Object IO.StreamReader($ex.Response.GetResponseStream(), [Text.Encoding]::UTF8)
            $errBody = $reader.ReadToEnd()
            $reader.Close()
            throw ('HTTP ' + [int]$ex.Response.StatusCode + ' ' + $errBody)
        }
        throw $ex.Message
    }

    $ms = New-Object IO.MemoryStream
    $resp.GetResponseStream().CopyTo($ms)
    $resp.Close()
    $text = [Text.Encoding]::UTF8.GetString($ms.ToArray())
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
}

# --------------------------------------------------------------- settings ----

$settings = @{
    message    = $MessageText
    autoAdd    = $false
    chats      = @()
    ignored    = @()
    limitMode  = 'none'
    limitCount = 50
    limitTime  = '18:00'
    topmost    = $true
    winWidth   = 400
    winHeight  = 520
}

if (Test-Path -LiteralPath $script:SettingsPath) {
    try {
        $rawText = [IO.File]::ReadAllText($script:SettingsPath, [Text.Encoding]::UTF8)
        $raw = $rawText | ConvertFrom-Json
        $schema = 0
        if ($null -ne $raw.schema) { [void][int]::TryParse([string]$raw.schema, [ref]$schema) }
        if ($null -ne $raw.message) { $settings.message = [string]$raw.message }
        # до схемы 2 автодобавление включалось по умолчанию, а не выбором пользователя —
        # новый интерфейс стартует с выключенным
        if ($schema -ge 2 -and $null -ne $raw.autoAdd) { $settings.autoAdd = [bool]$raw.autoAdd }
        if ($raw.chats) {
            $settings.chats = @($raw.chats | ForEach-Object {
                    @{ Id = [string]$_.id; Title = [string]$_.title }
                })
        }
        if ($raw.ignored) { $settings.ignored = @($raw.ignored | ForEach-Object { [string]$_ }) }
        if ([string]$raw.limitMode -in @('none', 'count', 'time')) { $settings.limitMode = [string]$raw.limitMode }
        if ($null -ne $raw.limitCount) {
            $n = 0
            if ([int]::TryParse([string]$raw.limitCount, [ref]$n) -and $n -ge 1 -and $n -le 99999) { $settings.limitCount = $n }
        }
        if ([string]$raw.limitTime -match '^(\d{1,2}):(\d{2})$') {
            $h = [int]$Matches[1]
            $m = [int]$Matches[2]
            if ($h -ge 0 -and $h -le 23 -and $m -ge 0 -and $m -le 59) {
                $settings.limitTime = ('{0:00}:{1:00}' -f $h, $m)
            }
        }
        if ($null -ne $raw.topmost) { $settings.topmost = [bool]$raw.topmost }
        # размеры окна старого интерфейса (860x880) в новый не переносим
        if ($schema -ge 2 -and $null -ne $raw.winWidth) { $settings.winWidth = [int]$raw.winWidth }
        if ($schema -ge 2 -and $null -ne $raw.winHeight) { $settings.winHeight = [int]$raw.winHeight }
    }
    catch { }
}
elseif ($ChatTitles.Count -gt 0) {
    $settings.chats = @($ChatTitles | ForEach-Object { @{ Id = ''; Title = [string]$_ } })
}

$script:Dirty = $false

function Save-Settings {
    try {
        $payload = @{
            schema     = 2
            message    = [string]$state.Message
            autoAdd    = [bool]$state.AutoAdd
            chats      = @($state.Chats | ForEach-Object { @{ id = [string]$_.Id; title = [string]$_.Title } })
            ignored    = @($state.Ignored.Keys)
            limitMode  = [string]$state.LimitMode
            limitCount = [int]$state.LimitCount
            limitTime  = [string]$state.LimitTime
            topmost    = [bool]$settings.topmost
            winWidth   = [int]$settings.winWidth
            winHeight  = [int]$settings.winHeight
        }
        $json = $payload | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText($script:SettingsPath, $json, (New-Object Text.UTF8Encoding($true)))
        $script:Dirty = $false
    }
    catch { }
}

# ------------------------------------------------------------------ state ----

$state = [hashtable]::Synchronized(@{})
$state.BaseUrl = $script:BaseUrl
$state.Auth = $script:Auth
$state.ServiceVersion = $script:ServiceVersion
$state.Message = [string]$settings.message
$state.AutoAdd = [bool]$settings.autoAdd
$state.PollMs = [Math]::Max(500, $PollMs)
$state.Stop = [bool]$StartStopped
$state.StopReason = if ($StartStopped) { 'user' } else { '' }
$state.LimitMode = [string]$settings.limitMode
$state.LimitCount = [int]$settings.limitCount
$state.LimitTime = [string]$settings.limitTime
$state.DeadlineTicks = [long]0
$state.LimitSince = [datetime]::MinValue
$state.LimitHit = ''
$state.SentThisRun = 0
$state.SentTotal = 0
$state.ErrorTotal = 0
$state.ErrorStreak = 0
$state.RunStartedAt = if ($StartStopped) { [datetime]::MinValue } else { Get-Date }
$state.StartedAt = Get-Date
$state.ApiError = ''
$state.Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$state.AddQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[hashtable]'
$state.RemoveQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$state.Ignored = [hashtable]::Synchronized(@{})
$state.Chats = @()
$state.SeedChats = @()

foreach ($ig in $settings.ignored) { if ($ig) { $state.Ignored[$ig] = $true } }

$seed = @()
foreach ($c in $settings.chats) {
    $seed += , ([hashtable]::Synchronized(@{
                Id         = [string]$c.Id
                Title      = [string]$c.Title
                Phase      = 'waiting'
                Status     = 'ожидание ответа'
                Count      = 0
                SentAt     = [datetime]::MinValue
                NextTryAt  = [datetime]::MinValue
                FailStreak = 0
                NoAnswer   = 0
                LastError  = ''
            }))
}
$state.SeedChats = $seed
$state.Chats = $seed

# ----------------------------------------------------------------- worker ----

$workerCode = @'
param($state)

$ErrorActionPreference = 'Continue'

function API {
    param([string]$Method, [string]$Path, $Body = $null, [int]$Timeout = 20000)

    $req = [Net.HttpWebRequest]::Create($state.BaseUrl + $Path)
    $req.Method = $Method
    $req.Headers['Authorization'] = 'Basic ' + $state.Auth
    $req.Timeout = $Timeout
    $req.ReadWriteTimeout = $Timeout
    $req.UserAgent = 'OpenCode-AutoContinue/1.4'
    $req.KeepAlive = $false

    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Compress -Depth 5
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $req.ContentType = 'application/json; charset=utf-8'
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
    }

    try {
        $resp = $req.GetResponse()
    }
    catch [Net.WebException] {
        $ex = $_.Exception
        if ($null -ne $ex.Response) {
            $reader = New-Object IO.StreamReader($ex.Response.GetResponseStream(), [Text.Encoding]::UTF8)
            $errBody = $reader.ReadToEnd()
            $reader.Close()
            throw ('HTTP ' + [int]$ex.Response.StatusCode + ' ' + $errBody)
        }
        throw $ex.Message
    }

    $ms = New-Object IO.MemoryStream
    $resp.GetResponseStream().CopyTo($ms)
    $resp.Close()
    $text = [Text.Encoding]::UTF8.GetString($ms.ToArray())
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
}

function Log {
    param([string]$Level, [string]$Message)
    $state.Log.Enqueue($Level + "`t" + (Get-Date).ToString('HH:mm:ss') + '  ' + $Message)
}

function Chat-Name($chat) {
    if ($chat.Title) { return [string]$chat.Title }
    return [string]$chat.Id
}

function Reload-Service {
    $paths = @(
        (Join-Path $env:USERPROFILE '.local\state\opencode\service.json'),
        (Join-Path $env:LOCALAPPDATA 'opencode\service.json')
    )
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) {
            try {
                $svc = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
                if (-not $svc.url -or -not $svc.password) { continue }
                $url = ([string]$svc.url).TrimEnd('/')
                $auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("opencode:$($svc.password)"))
                if ($url -ne $state.BaseUrl -or $auth -ne $state.Auth) {
                    $state.BaseUrl = $url
                    $state.Auth = $auth
                    if ($svc.version) { $state.ServiceVersion = [string]$svc.version }
                    return $true
                }
                return $false
            }
            catch { }
        }
    }
    return $false
}

$chats = New-Object System.Collections.ArrayList
foreach ($c in @($state.SeedChats)) { [void]$chats.Add($c) }
foreach ($c in $chats) {
    if ($c.Phase -eq 'init') {
        $c.Phase = 'waiting'
        $c.Status = 'ожидание ответа'
    }
}
$state.Chats = @($chats)

function Sync-Chats { $state.Chats = @($chats) }

function Find-Chat([string]$id) {
    foreach ($c in $chats) { if ($c.Id -eq $id) { return $c } }
    return $null
}

function Add-Chat([string]$id, [string]$title, [string]$reason) {
    if (-not $id) { return }
    if ($null -ne (Find-Chat $id)) { return }
    $chat = [hashtable]::Synchronized(@{
            Id         = $id
            Title      = $title
            Phase      = 'waiting'
            Status     = 'ожидание ответа'
            Count      = 0
            SentAt     = [datetime]::MinValue
            NextTryAt  = [datetime]::MinValue
            FailStreak = 0
            NoAnswer   = 0
            LastError  = ''
        })
    [void]$chats.Add($chat)
    Sync-Chats
    $name = if ($title) { $title } else { $id }
    Log 'info' ('+ добавлен чат «' + $name + '»' + $(if ($reason) { ' — ' + $reason } else { '' }))
}

function Remove-Chat([string]$id, [string]$why) {
    for ($i = $chats.Count - 1; $i -ge 0; $i--) {
        if ($chats[$i].Id -eq $id) {
            $name = Chat-Name $chats[$i]
            $chats.RemoveAt($i)
            Sync-Chats
            Log 'info' ('− убран чат «' + $name + '»' + $(if ($why) { ' — ' + $why } else { '' }))
        }
    }
}

function Resolve-Chat($chat) {
    if ($chat.Id) { return $true }
    try {
        $query = [uri]::EscapeDataString([string]$chat.Title)
        $r = API 'GET' ("/api/session?limit=100&search=" + $query)
        $hit = @($r.data | Where-Object { $_.title -eq $chat.Title })
        if ($hit.Count -gt 0) {
            $chat.Id = [string]$hit[0].id
            $chat.Phase = 'waiting'
            $chat.Status = 'ожидание ответа'
            Log 'info' ('[' + $chat.Title + '] найден ' + $chat.Id)
            return $true
        }
        $chat.Status = 'чат не найден'
        return $false
    }
    catch {
        $chat.Status = 'ошибка поиска'
        return $false
    }
}

function Send-Chat($chat) {
    if ([string]::IsNullOrWhiteSpace([string]$state.Message)) {
        $chat.Phase = 'waiting'
        $chat.Status = 'пустой текст сообщения'
        return
    }
    if ($chat.NextTryAt -and (Get-Date) -lt [datetime]$chat.NextTryAt) { return }

    try {
        $null = API 'POST' ("/api/session/" + $chat.Id + "/prompt") @{ text = [string]$state.Message; delivery = 'queue' }
        $chat.Count = [int]$chat.Count + 1
        $state.SentThisRun = [int]$state.SentThisRun + 1
        $state.SentTotal = [int]$state.SentTotal + 1
        $chat.SentAt = Get-Date
        $chat.Phase = 'sent'
        $chat.Status = "отправлено #$($chat.Count)"
        $chat.FailStreak = 0
        $chat.LastError = ''
        $chat.NextTryAt = [datetime]::MinValue
        Log 'info' ('[' + (Chat-Name $chat) + '] → ' + $state.Message + '  (#' + $chat.Count + ')')
    }
    catch {
        $msg = [string]$_.Exception.Message
        $state.ErrorTotal = [int]$state.ErrorTotal + 1
        if ($msg -match '^HTTP 404') {
            Log 'warn' ('[' + (Chat-Name $chat) + '] сессия не найдена — убираю из списка')
            Remove-Chat $chat.Id 'сессия удалена'
            return
        }
        if ($msg -match '^HTTP 40[13]') {
            $state.Stop = $true
            $state.StopReason = 'error'
            $state.LimitHit = ''
            Log 'err' ('Нет доступа к API OpenCode: ' + $msg + ' — пауза')
            return
        }
        $chat.FailStreak = [int]$chat.FailStreak + 1
        $chat.LastError = $msg
        $waits = @(5, 10, 20, 40, 60)
        $idx = [Math]::Min($chat.FailStreak - 1, $waits.Count - 1)
        $wait = [int]$waits[$idx]
        if ($chat.FailStreak -ge 5) {
            $chat.Phase = 'blocked'
            $chat.Status = 'ошибка — чат на паузе'
            $chat.NextTryAt = [datetime]::MinValue
            Log 'err' ('[' + (Chat-Name $chat) + '] ' + $chat.FailStreak + ' ошибок подряд — чат поставлен на паузу: ' + $msg)
        }
        else {
            $chat.Phase = 'waiting'
            $chat.Status = 'ошибка отправки — повтор'
            $chat.NextTryAt = (Get-Date).AddSeconds($wait)
            Log 'err' ('[' + (Chat-Name $chat) + '] ошибка отправки (' + $chat.FailStreak + '/5): ' + $msg + ' — повтор через ' + $wait + ' с')
        }
    }
}

function Limit-Reason {
    if ($state.LimitMode -eq 'count') {
        $limit = [int]$state.LimitCount
        if ($limit -gt 0 -and [int]$state.SentThisRun -ge $limit) { return 'count' }
    }
    elseif ($state.LimitMode -eq 'time') {
        $ticks = [long]$state.DeadlineTicks
        if ($ticks -gt 0 -and (Get-Date).Ticks -ge $ticks) { return 'time' }
    }
    return ''
}

$apiFail = 0
$lastApiErr = ''
$healthOk = 0
$nextHealth = [datetime]::MinValue
$infoCache = @{}
$infoRetry = @{}
$lastResolve = [datetime]::MinValue

Log 'info' ('Сервер: ' + $state.BaseUrl + $(if ($state.ServiceVersion) { ' · OpenCode ' + $state.ServiceVersion } else { '' }))
Log 'info' ('Наблюдатель запущен · интервал ' + $state.PollMs + ' мс')

while ($true) {
    try {
        # команды из интерфейса
        $item = $null
        while ($state.RemoveQueue.TryDequeue([ref]$item)) { Remove-Chat ([string]$item) '' }
        while ($state.AddQueue.TryDequeue([ref]$item)) {
            $state.Ignored.Remove([string]$item.Id)
            Add-Chat ([string]$item.Id) ([string]$item.Title) 'добавлен вручную'
        }

        if ($state.Stop) {
            # после потери связи quietly проверяем, не вернулся ли OpenCode
            if ($state.StopReason -eq 'error' -and (Get-Date) -ge $nextHealth) {
                if (Reload-Service) { Log 'info' 'Подхвачены новые параметры сервера OpenCode' }
                try {
                    $null = API 'GET' '/api/session/active' $null 6000
                    $healthOk++
                    if ($healthOk -ge 2) {
                        $state.Stop = $false
                        $state.StopReason = ''
                        $state.ApiError = ''
                        $apiFail = 0
                        $lastApiErr = ''
                        $healthOk = 0
                        Log 'ok' 'Связь восстановлена — автопродолжение возобновлено'
                    }
                }
                catch {
                    $healthOk = 0
                }
                $nextHealth = (Get-Date).AddSeconds(12)
            }
            Start-Sleep -Milliseconds 350
            continue
        }

        # лимит запуска
        $whyLimit = Limit-Reason
        if ($whyLimit) {
            $state.Stop = $true
            $state.StopReason = 'limit'
            $state.LimitHit = $whyLimit
            if ($whyLimit -eq 'count') {
                Log 'ok' ('Лимит итераций достигнут: ' + $state.SentThisRun + ' из ' + $state.LimitCount + ' — пауза')
            }
            else {
                $deadline = [datetime]::new([long]$state.DeadlineTicks)
                Log 'ok' ('Лимит времени достигнут (' + $deadline.ToString('HH:mm') + ') — пауза')
            }
            continue
        }

        # восстановление чатов, заданных названием
        if (((Get-Date) - $lastResolve).TotalSeconds -gt 10) {
            foreach ($c in $chats.ToArray()) {
                if (-not $c.Id) { [void](Resolve-Chat $c) }
            }
            $lastResolve = Get-Date
        }

        $running = @{}
        try {
            $act = API 'GET' '/api/session/active'
            if ($apiFail -gt 0) {
                Log 'ok' 'Связь с OpenCode восстановлена'
                $apiFail = 0
                $lastApiErr = ''
            }
            $state.ApiError = ''
            if ($act -and $act.data) {
                foreach ($prop in $act.data.PSObject.Properties) { $running[[string]$prop.Name] = $true }
            }
        }
        catch {
            $msg = [string]$_.Exception.Message
            $apiFail++
            $state.ApiError = $msg
            $state.ErrorStreak = $apiFail

            if (Reload-Service) {
                Log 'info' 'Сервис OpenCode перезапущен — подхвачены новые параметры подключения'
                $apiFail = 1
                $lastApiErr = ''
                Start-Sleep -Milliseconds 700
                continue
            }

            if ($msg -ne $lastApiErr) {
                $prefix = if ($msg -match '^HTTP 40[13]') { 'Нет доступа к API OpenCode: ' } else { 'Нет связи с OpenCode: ' }
                Log 'err' ($prefix + $msg)
                $lastApiErr = $msg
            }
            elseif ($apiFail % 5 -eq 0) {
                Log 'warn' ('OpenCode не отвечает — попытка ' + $apiFail)
            }

            if ($apiFail -ge 5) {
                $state.Stop = $true
                $state.StopReason = 'error'
                $state.LimitHit = ''
                $healthOk = 0
                $nextHealth = (Get-Date).AddSeconds(8)
                Log 'err' 'Слишком много ошибок подряд — автопродолжение приостановлено, проверяю связь в фоне'
                continue
            }

            $delay = [int][Math]::Min(30, [Math]::Pow(2, $apiFail))
            Start-Sleep -Seconds $delay
            continue
        }

        # авто-подхват активных чатов
        if ($state.AutoAdd) {
            foreach ($id in @($running.Keys)) {
                if ($null -ne (Find-Chat $id)) { continue }
                if ($state.Ignored.ContainsKey($id)) { continue }

                if (-not $infoCache.ContainsKey($id)) {
                    # разовая ошибка запроса не должна навсегда выкинуть чат из автодобавления
                    if ($infoRetry.ContainsKey($id) -and (Get-Date) -lt $infoRetry[$id]) { continue }
                    try {
                        $infoCache[$id] = (API 'GET' ("/api/session/" + $id)).data
                        $infoRetry.Remove($id)
                    }
                    catch {
                        $infoRetry[$id] = (Get-Date).AddSeconds(15)
                        continue
                    }
                }
                $info = $infoCache[$id]
                if ($null -eq $info) { continue }
                if ($info.parentID) { continue }
                if ($info.archived) { continue }

                Add-Chat $id ([string]$info.title) 'активный чат'
            }
            if ($infoCache.Count -gt 400) { $infoCache = @{}; $infoRetry = @{} }
        }

        foreach ($chat in $chats.ToArray()) {
            if ($state.Stop) { break }
            if (Limit-Reason) { break }
            if (-not $chat.Id) { continue }

            $busy = $running.ContainsKey([string]$chat.Id)
            $phase = [string]$chat.Phase

            if ($phase -eq 'waiting') {
                if ($busy) {
                    $chat.Phase = 'running'
                    $chat.Status = 'печатает…'
                    $chat.NoAnswer = 0
                }
                elseif (-not $chat.NextTryAt -or (Get-Date) -ge [datetime]$chat.NextTryAt) {
                    Send-Chat $chat
                }
            }
            elseif ($phase -eq 'sent') {
                if ($busy) {
                    $chat.Phase = 'running'
                    $chat.Status = 'печатает…'
                    $chat.NoAnswer = 0
                }
                else {
                    $age = ((Get-Date) - [datetime]$chat.SentAt).TotalSeconds
                    if ($age -gt 45) {
                        $chat.NoAnswer = [int]$chat.NoAnswer + 1
                        if ($chat.NoAnswer -ge 3) {
                            $chat.Phase = 'blocked'
                            $chat.Status = 'бот не отвечает'
                            Log 'err' ('[' + (Chat-Name $chat) + '] ответ не начался 3 раза — чат на паузе')
                        }
                        else {
                            $chat.Phase = 'waiting'
                            $chat.Status = 'ответ не начался — повтор'
                            $chat.NextTryAt = (Get-Date).AddSeconds(10)
                            Log 'warn' ('[' + (Chat-Name $chat) + '] ответ не начался за 45 с — повторная отправка')
                        }
                    }
                }
            }
            elseif ($phase -eq 'running') {
                if (-not $busy) {
                    $chat.Phase = 'waiting'
                    $chat.Status = 'ответ получен, ждём отправки'
                    Log 'info' ('[' + (Chat-Name $chat) + '] ответ завершён')
                }
            }
            elseif ($phase -eq 'blocked') {
                if ($busy) {
                    $chat.Phase = 'running'
                    $chat.Status = 'печатает…'
                    $chat.FailStreak = 0
                    $chat.NoAnswer = 0
                    Log 'ok' ('[' + (Chat-Name $chat) + '] бот снова работает')
                }
            }
            else {
                $chat.Phase = 'waiting'
                $chat.Status = 'ожидание ответа'
            }
        }

        Start-Sleep -Milliseconds $state.PollMs
    }
    catch {
        Log 'err' ('Сбой наблюдателя: ' + [string]$_.Exception.Message)
        Start-Sleep -Seconds 5
    }
}
'@

$runspace = [runspacefactory]::CreateRunspace()
$runspace.ThreadOptions = 'ReuseThread'
$runspace.Open()
$worker = [PowerShell]::Create()
$worker.Runspace = $runspace
[void]$worker.AddScript($workerCode)
[void]$worker.AddArgument($state)
$workerHandle = $worker.BeginInvoke()

# --------------------------------------------------------------------- ui ----
# Стиль — палитра OpenCode: #0a0a0a / #141414 / #1e1e1e, акцент #fab283, моно-шрифт.

$uiXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework"
        Title="OpenCode AutoContinue"
        Width="400" Height="520" MinWidth="360" MinHeight="440"
        WindowStyle="None" ResizeMode="CanResize"
        WindowStartupLocation="CenterScreen"
        Background="#0A0A0A" Foreground="#EEEEEE"
        FontFamily="Cascadia Mono, Consolas" FontSize="12"
        TextOptions.TextFormattingMode="Display"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <shell:WindowChrome.WindowChrome>
    <shell:WindowChrome CaptionHeight="0" ResizeBorderThickness="6"
                        GlassFrameThickness="0" CornerRadius="0"
                        UseAeroCaptionButtons="False"/>
  </shell:WindowChrome.WindowChrome>
  <Window.Resources>
    <SolidColorBrush x:Key="TextMain" Color="#EEEEEE"/>
    <SolidColorBrush x:Key="TextMuted" Color="#808080"/>
    <SolidColorBrush x:Key="TextDim" Color="#606060"/>
    <SolidColorBrush x:Key="Primary" Color="#FAB283"/>
    <SolidColorBrush x:Key="FieldBorder" Color="#282828"/>

    <Style x:Key="SectionLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="{StaticResource TextDim}"/>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Height" Value="48"/>
      <Setter Property="Padding" Value="18,0"/>
      <Setter Property="Background" Value="#E06C75"/>
      <Setter Property="Foreground" Value="#0A0A0A"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6"/>
              <Border x:Name="Hover" Background="#1FFFFFFF" CornerRadius="6" Opacity="0"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Hover" Property="Opacity" Value="1"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Hover" Property="Opacity" Value="1"/>
                <Setter TargetName="Bd" Property="Opacity" Value="0.8"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="GhostButton" TargetType="Button">
      <Setter Property="Height" Value="26"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#A0A0A0"/>
      <Setter Property="BorderBrush" Value="#3C3C3C"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1E1E1E"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#484848"/>
                <Setter Property="Foreground" Value="#EEEEEE"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#282828"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="LinkButton" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#808080"/>
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="Padding" Value="6,3"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1E1E1E"/>
                <Setter Property="Foreground" Value="#EEEEEE"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="IconButton" TargetType="Button">
      <Setter Property="Width" Value="34"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#808080"/>
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1E1E1E"/>
                <Setter Property="Foreground" Value="#EEEEEE"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#282828"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CloseButton" TargetType="Button" BasedOn="{StaticResource IconButton}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#E06C75"/>
                <Setter Property="Foreground" Value="#0A0A0A"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#B8555D"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SegmentRadio" TargetType="RadioButton">
      <Setter Property="Height" Value="26"/>
      <Setter Property="Foreground" Value="#808080"/>
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" Background="Transparent" BorderBrush="#282828" BorderThickness="1" CornerRadius="5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1E1E1E"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#3C3C3C"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1E1E1E"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#FAB283"/>
                <Setter Property="Foreground" Value="#FAB283"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#EEEEEE"/>
      <Setter Property="HorizontalAlignment" Value="Stretch"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <ContentPresenter VerticalAlignment="Center"/>
              <Border x:Name="Track" Grid.Column="1" Width="34" Height="18" CornerRadius="9" Background="#1E1E1E"
                      BorderBrush="#3C3C3C" BorderThickness="1" VerticalAlignment="Center" Margin="12,0,0,0">
                <Ellipse x:Name="Knob" Width="12" Height="12" Fill="#808080" HorizontalAlignment="Left" Margin="2,0,0,0"/>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#2E2118"/>
                <Setter TargetName="Track" Property="BorderBrush" Value="#FAB283"/>
                <Setter TargetName="Knob" Property="Fill" Value="#FAB283"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Margin" Value="0,0,2,0"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Track" Property="BorderBrush" Value="#606060"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#141414"/>
      <Setter Property="Foreground" Value="{StaticResource TextMain}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Primary}"/>
      <Setter Property="SelectionBrush" Value="#FAB283"/>
      <Setter Property="BorderBrush" Value="{StaticResource FieldBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            VerticalScrollBarVisibility="{TemplateBinding VerticalScrollBarVisibility}"
                            HorizontalScrollBarVisibility="{TemplateBinding HorizontalScrollBarVisibility}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#3C3C3C"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#FAB283"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SlimScrollBar" TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="MinWidth" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False" IsTabStop="False"/>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border Background="#3C3C3C" CornerRadius="3" Margin="1,2"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False" IsTabStop="False"/>
                </Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar" BasedOn="{StaticResource SlimScrollBar}"/>

    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#1E1E1E"/>
      <Setter Property="Foreground" Value="#EEEEEE"/>
      <Setter Property="BorderBrush" Value="#3C3C3C"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="Padding" Value="7,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToolTip">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ProgressBar">
      <Setter Property="Background" Value="#282828"/>
      <Setter Property="Foreground" Value="{StaticResource Primary}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Border Background="{TemplateBinding Background}" CornerRadius="1.5" ClipToBounds="True">
              <Grid x:Name="PART_Track">
                <Border x:Name="PART_Indicator" HorizontalAlignment="Left" Background="{TemplateBinding Foreground}" CornerRadius="1.5"/>
              </Grid>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="WindowFrame" Background="#0A0A0A" BorderBrush="#282828" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="36"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <!-- ===== title bar ===== -->
      <Grid Grid.Row="0" Background="#0A0A0A">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Grid x:Name="DragArea" Background="Transparent" ClipToBounds="True">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="12,0,0,0">
            <Image x:Name="TitleIcon" Width="18" Height="18" Margin="0,0,10,0"
                   RenderOptions.BitmapScalingMode="HighQuality"/>
            <Ellipse x:Name="StatusDot" Width="7" Height="7" Fill="#7FD88F" VerticalAlignment="Center"/>
            <TextBlock x:Name="StatusText" Text="РАБОТАЕТ" Margin="7,0,0,0" FontSize="10.5"
                       FontWeight="Bold" Foreground="#7FD88F" VerticalAlignment="Center"/>
            <TextBlock x:Name="StatusMeta" Text="" Margin="8,0,0,0" FontSize="10"
                       Foreground="#606060" VerticalAlignment="Center"/>
          </StackPanel>
        </Grid>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,6,0">
          <Button x:Name="SettingsBtn" Style="{StaticResource IconButton}" Content="&#xE713;" ToolTip="Настройки и журнал"/>
          <Button x:Name="MinBtn" Style="{StaticResource IconButton}" Content="&#xE921;" ToolTip="Свернуть"/>
          <Button x:Name="CloseBtn" Style="{StaticResource CloseButton}" Content="&#xE8BB;" ToolTip="Выход"/>
        </StackPanel>
      </Grid>

      <!-- ===== main view ===== -->
      <Grid x:Name="MainView" Grid.Row="1" Margin="14,4,14,14">
        <Grid.RowDefinitions>
          <RowDefinition Height="*" MinHeight="80"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- message -->
        <Grid Grid.Row="0">
          <TextBox x:Name="MessageBox" AcceptsReturn="True" TextWrapping="Wrap" MaxLength="4000"
                   VerticalContentAlignment="Top" Padding="12,10"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"/>
          <TextBlock x:Name="MessageHint" Text="Что отправлять боту после каждого ответа…"
                     Margin="13,11,13,0" Foreground="#606060" IsHitTestVisible="False"
                     TextWrapping="Wrap" VerticalAlignment="Top"/>
        </Grid>

        <!-- chats header -->
        <Grid Grid.Row="1" Margin="1,12,0,6">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Text="ЧАТЫ" Style="{StaticResource SectionLabel}" VerticalAlignment="Center"/>
            <Border Background="#1E1E1E" CornerRadius="4" Padding="6,1" Margin="8,0,0,0" VerticalAlignment="Center">
              <TextBlock x:Name="ChatCountText" Text="0" FontSize="10" FontWeight="SemiBold" Foreground="#A0A0A0"/>
            </Border>
          </StackPanel>
          <Button x:Name="AddBtn" Style="{StaticResource GhostButton}" HorizontalAlignment="Right" Content="+ Добавить"/>
        </Grid>

        <!-- chats list -->
        <ScrollViewer Grid.Row="2" MaxHeight="144" VerticalScrollBarVisibility="Auto"
                      HorizontalScrollBarVisibility="Disabled" PanningMode="VerticalOnly">
          <StackPanel x:Name="ChatPanel"/>
        </ScrollViewer>

        <!-- limit -->
        <Grid Grid.Row="3" Margin="0,8,0,0">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Grid Grid.Row="0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Text="ЛИМИТ" Style="{StaticResource SectionLabel}" VerticalAlignment="Center" Margin="1,0,10,0"/>
            <Grid Grid.Column="1">
              <Grid.ColumnDefinitions>
                <ColumnDefinition/>
                <ColumnDefinition/>
                <ColumnDefinition/>
              </Grid.ColumnDefinitions>
              <RadioButton x:Name="LimitNone" Content="Нет" Style="{StaticResource SegmentRadio}"
                           GroupName="LimitMode" IsChecked="True" Margin="0,0,4,0"/>
              <RadioButton x:Name="LimitCountRadio" Grid.Column="1" Content="Итерации"
                           Style="{StaticResource SegmentRadio}" GroupName="LimitMode" Margin="0,0,4,0"/>
              <RadioButton x:Name="LimitTimeRadio" Grid.Column="2" Content="До времени"
                           Style="{StaticResource SegmentRadio}" GroupName="LimitMode"/>
            </Grid>
            <Grid Grid.Column="2">
              <TextBox x:Name="CountBox" Width="62" Height="26" MaxLength="5" Text="50" Margin="8,0,0,0"
                       HorizontalContentAlignment="Center" VerticalContentAlignment="Center"
                       TextAlignment="Center" Padding="4,2" FontSize="11.5" Visibility="Collapsed"/>
              <TextBox x:Name="TimeBox" Width="62" Height="26" MaxLength="5" Text="18:00" Margin="8,0,0,0"
                       HorizontalContentAlignment="Center" VerticalContentAlignment="Center"
                       TextAlignment="Center" Padding="4,2" FontSize="11.5" Visibility="Collapsed"/>
            </Grid>
          </Grid>
          <Grid x:Name="ProgressRow" Grid.Row="1" Margin="1,9,0,0" Visibility="Collapsed">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <ProgressBar x:Name="LimitProgress" Height="3" Minimum="0" Maximum="1" Value="0" VerticalAlignment="Center"/>
            <TextBlock x:Name="ProgressLabel" Grid.Column="1" Margin="10,0,0,0" FontSize="10"
                       Foreground="#808080" VerticalAlignment="Center"/>
          </Grid>
        </Grid>

        <!-- main action -->
        <Button x:Name="MainActionBtn" Grid.Row="4" Style="{StaticResource PrimaryButton}" Margin="0,12,0,0">
          <StackPanel Orientation="Horizontal">
            <TextBlock x:Name="MainActionGlyph" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets"
                       Text="&#xE71A;" FontSize="12" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <TextBlock x:Name="MainActionText" Text="ОСТАНОВИТЬ" VerticalAlignment="Center"/>
          </StackPanel>
        </Button>
      </Grid>

      <!-- ===== settings view ===== -->
      <Grid x:Name="SettingsView" Grid.Row="1" Margin="14,4,14,12" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0" Margin="0,0,0,10">
          <Button x:Name="BackBtn" Style="{StaticResource GhostButton}" HorizontalAlignment="Left">
            <StackPanel Orientation="Horizontal">
              <TextBlock FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Text="&#xE72B;" FontSize="10"
                         VerticalAlignment="Center" Margin="0,0,7,0"/>
              <TextBlock Text="Назад" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
          <TextBlock Text="НАСТРОЙКИ" Style="{StaticResource SectionLabel}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </Grid>

        <Border Grid.Row="1" Background="#141414" BorderBrush="#282828" BorderThickness="1" CornerRadius="8" Padding="14,4">
          <StackPanel>
            <CheckBox x:Name="AutoAddChk" Style="{StaticResource Switch}" Margin="0,9">
              <StackPanel>
                <TextBlock Text="Автодобавление чатов" Foreground="#EEEEEE" FontSize="12"/>
                <TextBlock Text="подхватывать новые активные чаты" Foreground="#606060" FontSize="10" Margin="0,2,0,0"/>
              </StackPanel>
            </CheckBox>
            <Border Height="1" Background="#282828"/>
            <CheckBox x:Name="TopmostChk" Style="{StaticResource Switch}" Margin="0,9">
              <StackPanel>
                <TextBlock Text="Поверх всех окон" Foreground="#EEEEEE" FontSize="12"/>
                <TextBlock Text="окно не прячется за другими" Foreground="#606060" FontSize="10" Margin="0,2,0,0"/>
              </StackPanel>
            </CheckBox>
          </StackPanel>
        </Border>

        <Grid Grid.Row="2" Margin="1,14,0,6">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Text="ЖУРНАЛ" Style="{StaticResource SectionLabel}" VerticalAlignment="Center"/>
            <Ellipse x:Name="LogLiveDot" Width="5" Height="5" Fill="#7FD88F" Margin="8,0,0,0"
                     VerticalAlignment="Center" Opacity="0.7"/>
          </StackPanel>
          <Button x:Name="ClearBtn" Style="{StaticResource LinkButton}" Content="Очистить" HorizontalAlignment="Right"/>
        </Grid>

        <Border Grid.Row="3" Background="#0F0F0F" BorderBrush="#282828" BorderThickness="1"
                CornerRadius="8" Padding="1" ClipToBounds="True">
          <RichTextBox x:Name="LogBox" IsReadOnly="True" IsUndoEnabled="False" BorderThickness="0"
                       Background="Transparent" Foreground="#A0A0A0" Padding="10,8"
                       FontFamily="Cascadia Mono, Consolas" FontSize="10.5"
                       VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                       IsDocumentEnabled="False"/>
        </Border>

        <Grid Grid.Row="4" Margin="1,8,0,0">
          <TextBlock x:Name="FooterText" Text="" FontSize="10" Foreground="#606060" VerticalAlignment="Center"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="DataBtn" Style="{StaticResource LinkButton}" Content="Папка данных" Margin="0,0,4,0"/>
            <Button x:Name="TrayBtn" Style="{StaticResource LinkButton}" Content="В трей"/>
          </StackPanel>
        </Grid>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($uiXaml)

function Find-Ui([string]$name) {
    $el = $window.FindName($name)
    if ($null -eq $el) { throw "В XAML не найден элемент '$name'" }
    return $el
}

$StatusDot = Find-Ui 'StatusDot'
$StatusText = Find-Ui 'StatusText'
$StatusMeta = Find-Ui 'StatusMeta'
$MainView = Find-Ui 'MainView'
$SettingsView = Find-Ui 'SettingsView'
$SettingsBtn = Find-Ui 'SettingsBtn'
$BackBtn = Find-Ui 'BackBtn'
$MainActionBtn = Find-Ui 'MainActionBtn'
$MainActionGlyph = Find-Ui 'MainActionGlyph'
$MainActionText = Find-Ui 'MainActionText'
$ProgressRow = Find-Ui 'ProgressRow'
$LimitProgress = Find-Ui 'LimitProgress'
$ProgressLabel = Find-Ui 'ProgressLabel'
$MessageBox = Find-Ui 'MessageBox'
$MessageHint = Find-Ui 'MessageHint'
$AutoAddChk = Find-Ui 'AutoAddChk'
$TopmostChk = Find-Ui 'TopmostChk'
$LimitNone = Find-Ui 'LimitNone'
$LimitCountRadio = Find-Ui 'LimitCountRadio'
$LimitTimeRadio = Find-Ui 'LimitTimeRadio'
$CountBox = Find-Ui 'CountBox'
$TimeBox = Find-Ui 'TimeBox'
$ChatCountText = Find-Ui 'ChatCountText'
$AddBtn = Find-Ui 'AddBtn'
$ChatPanel = Find-Ui 'ChatPanel'
$LogBox = Find-Ui 'LogBox'
$LogLiveDot = Find-Ui 'LogLiveDot'
$ClearBtn = Find-Ui 'ClearBtn'
$FooterText = Find-Ui 'FooterText'
$TrayBtn = Find-Ui 'TrayBtn'
$DataBtn = Find-Ui 'DataBtn'
$DragArea = Find-Ui 'DragArea'
$TitleIcon = Find-Ui 'TitleIcon'
$MinBtn = Find-Ui 'MinBtn'
$CloseBtn = Find-Ui 'CloseBtn'

$script:BrushCache = @{}
function Brush([string]$hex) {
    if (-not $script:BrushCache.ContainsKey($hex)) {
        $b = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($hex))
        $b.Freeze()
        $script:BrushCache[$hex] = $b
    }
    return $script:BrushCache[$hex]
}

function Write-UiLog([string]$level, [string]$message) {
    $state.Log.Enqueue($level + "`t" + (Get-Date).ToString('HH:mm:ss') + '  ' + $message)
}

function Format-Duration([TimeSpan]$span) {
    if ($span.TotalSeconds -lt 0) { $span = [TimeSpan]::Zero }
    return ('{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds)
}

function Plural([int]$n, [string]$one, [string]$few, [string]$many) {
    $m10 = $n % 10
    $m100 = $n % 100
    if ($m10 -eq 1 -and $m100 -ne 11) { return $one }
    if ($m10 -ge 2 -and $m10 -le 4 -and ($m100 -lt 12 -or $m100 -gt 14)) { return $few }
    return $many
}

function Parse-TimeText([string]$text) {
    if ($text -match '^\s*(\d{1,2})\s*[:.]\s*(\d{2})\s*$') {
        $h = [int]$Matches[1]
        $m = [int]$Matches[2]
        if ($h -ge 0 -and $h -le 23 -and $m -ge 0 -and $m -le 59) {
            return @{ Hour = $h; Minute = $m; Text = ('{0:00}:{1:00}' -f $h, $m) }
        }
    }
    return $null
}

function Get-NextDeadline([int]$hour, [int]$minute) {
    $now = Get-Date
    $deadline = [datetime]::new($now.Year, $now.Month, $now.Day, $hour, $minute, 0)
    if ($deadline -le $now) { $deadline = $deadline.AddDays(1) }
    return $deadline
}

function Read-LimitCount {
    $text = $CountBox.Text.Trim()
    if ($text -match '^\d{1,5}$') {
        $n = [int]$text
        if ($n -ge 1 -and $n -le 99999) { return $n }
    }
    return 0
}

# ---- заголовок окна ----

$script:Topmost = [bool]$settings.topmost
$window.Topmost = $script:Topmost
$TopmostChk.IsChecked = $script:Topmost

$DragArea.Add_MouseLeftButtonDown({
        param($sender, $e)
        try { $window.DragMove() } catch { }
    })

$MinBtn.Add_Click({ $window.WindowState = 'Minimized' })
$CloseBtn.Add_Click({ $window.Close() })

# окно без рамки при разворачивании вылезает за экран — в этой утилите это не нужно
$window.Add_StateChanged({
        if ($window.WindowState -eq 'Maximized') { $window.WindowState = 'Normal' }
    })

function Show-SettingsView([bool]$on) {
    if ($on) {
        $MainView.Visibility = 'Collapsed'
        $SettingsView.Visibility = 'Visible'
        $SettingsBtn.Foreground = Brush '#FAB283'
        $LogBox.UpdateLayout()
        $LogBox.ScrollToEnd()
    }
    else {
        $SettingsView.Visibility = 'Collapsed'
        $MainView.Visibility = 'Visible'
        $SettingsBtn.Foreground = Brush '#808080'
    }
}

# ---- иконка ----
# PNG зашит в скрипт, поэтому иконка есть и у .exe, и у запуска из исходника.

$script:IconPngB64 = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAKFklEQVR42uVba2hb1x3/nZd0dfWw1LlO2nrYJbQdKXTMDvYasopkbPVg+5AOwRj0S6CQDja2sX5oGDTZ6OigsDFSWAZjtOxTChuM4HV1mkztZjuL5TZNpjQkdtw0cdzUlezYet17HvsgXVVuLMd2ZFfqDujDtaVzz/93/u8HsIqVSCQYAIrWWTQej3MA5HZfvN0XKADtPfT392+hlD6std5mjLnbGMOahGBNCJklhEz6fL5zb7311vWa/zEAas0AJBIJ9uqrr6oK4U8opfY5jrPLdd0213WhlGqqK2eMgXMOn8+34PP5Rhhjfzp16tRRALqWllUB4P2gt7d3F4BfFwqFnXNzc1hYWIDrutoYo40xTQUAIQSEECqEoKFQCNFoFMFgMGWMeTaVSg0999xz9NChQwaAWREAj/gdO3Y847ruCzdu3KDZbFYZY0AppaS8mlLwjTEwxhittQaAWCzGOjo6IIQ4lEqlDlZo07UgLKEkHo/zZDIpe3t7f+U4zrNTU1PacRzDGGOEEDTbra/EDcYYKKWUEAJdXV0sEAgcHhsb+2GFRuWBwGpvfnBwUPX09PzMdd1fTExMuEopxjlvJe3/ab1AtdYkm83KcDj8aFdXFx8ZGXkjkUiwdDptqhzgsX1PT89XlVLDk5OTynVdxhgjrXLrK3GD1tpQStW2bdu4EOKbqVRqyKOZ1Jg79PT0nLp+/fqOTCajOOes1YmvBUFKqaLRKLv33nsvlEqlR9LptFvrMOj+/v5vF4vFHdlsVjHGPjfEe8qRc87m5uZUoVB4KBQKfQ+AicfjjHd0dBgAkFI+PTc3Z4wxWEnhUUpBaXOqBa01Kgag7spms8a27f0AXkkmk5oAwK5du+6en5+fnJqaCkkpTT07RwhBoVC47Us+S1a3bXsla2UIIaS7u9uNRCIPjIyMvM8BoFQqPeK6bsh1XU3rXC+lFKVSCbt378aePXuQy+WahhO01rBtG8PDwxgaGoLf7693SURKqaSUQkrZA6AMAIAHpJQwxmhCCF0OQUopXNfF7t27ceDAAbiuCyFEUwDgneXw4cMYHBxEIBBYFoCKaBvXdQHgQQDwAGhXSq3K0cnn85BSYnZ2FpzzpgBASon29nbkcrnVWgQAaK8FYNW+LaUUnPPqp1kW53xNImmMoWixGH9jgNtsM3THmY4Gm+GGAWCMgW3bCAQC8HyJRjszhBAUi0Xk8/mG7c8bdfPBYBAnTpzAm2++uZIZuqObL5VK6O/vx8DAAPL5fEM4oWEAWJaFkydP4sUXX9xQEXjqqaewd+9eLC4uNg8A3rJtG5xzRCIRz9Q0VMvfvHkTwWCwoXmJhitBKWX1syQ2pxS6nLG5I3uvtfYyP9W9Pv38mQGwkgJbWCyA+zgsHwclBFob6HUc2LMCQoiqH0IIAaUUjLHmA0Bpg3DAh+/0PYTTF6dxeSYDaAXCBQI+Ds4ojDEV7ri9F1coFJDJZJDJZKoEe15sLpdbs3XYUADKvreGX3C8/JMn4GiN4fQVDL0zgZPvXsb5KzdwM18ACIPlFxC8TNByoiKlhGVZOHr0KI4dOwatdZXYSsIWxWIRlmWtSf9smgjM5YrYelcIA30PYWDndji5As5O3cCJdycx9PYEUhenkZlfBAAIn4B/GVHxOKCez78eJ2nTnHlGCbQyKBWL5Rczit4H70Pvw1145rtfw+WZDP713/fxj/FL+Pf5K5iamQO0vEVUCGEryvpaFeGmRjOElIHwWLdUcKDzJVBKcH9HFPd/8W48+XgvMpkFnL54Da+/vXZRaUorUF+jE9BKIFpyJUzJBQgQtf14vO9LePzR9YlKywCwBAxCAFYGQyoDnSuWk5kriUr6CqZmMoBRIEwg4BetC8AtokJINU1xi6jc9wU8+Y2vYG4+j3NXbiB5dgp/G30PZ9//EJQQrIUPWiMfQD5RcFprQBuAUAT8Am22hUjQgk+w1tMBdTU5AFORaUYJ/D4B+DmgDD6cncfoex/g9fFL+OfZKZy/+hGMdAEmYPsFTKsCUOsNCs7AbR/AGVB0cOHqLJLnpvD6+CWMvvcBrs3OA8aACQ7b7wML+FtTCWpjoHU50eEXDMQvAEqQv5nHf85dw/F3JnH8nQmcmZzBzcU8AAKfXyActCo1vzLRUq3fFPLNZm2tDQxWZu3kuSlcuPYxpOMAlCHgF4iEbRhTAc0AqPEO1+sEbSoASmtQQmDZfkDw27K25SvLtDYGRhtIpZeEvvVij6YKhmoPdlfIhqM0Tp+/gjfOXF43a3POIYS4BQQv37/WRAzfaKYnhMCRCj/4/TGMXriKCx98BOm6y7K20re08CwhfGFhAfv27cPBgweRzWaXhMOxWAxHjhzB888/j3A4vGog+MZq9rLvv1go4Y9/Pw3KOQJ+Advy3cLaq7UUkUgEnZ2dCIfD1YSIlBJtbW2IxWLNGQwRQhAO2VVTdydaW0oJpRRKpVK1Vc/723rykA0FoLZsVs+hW6/r6e3LGAOldInC81Ji66kVNBQAr3CayWQ2jJvWk/bacAC8osXOnTuxf/9+WJa1IYWRYrGIxx57DMVisWHlsYYBkMvlMDAwgL17925YP2FtaaypAPAOl8/nsbi4uMFJlCYtjm7E4TYlEYP/88Vr4pTVRXA15a9mWd551qh4TS0AHzPGVmVevAJoe3t7U/UICSEQDAZX5U1Wzv1xFQBCyATnHPU6xLyb55xjeHgYL730UsPK0w3JK1T6E06ePAnOeV1OqDRZECEEKKUXawE4wznPCyHseo2SWmv4/X689tprGBwcbM7UYaVRcgVRMJxzxjmXPp9vvNY71b29vcenp6f3ZDIZvVKjdCu3yiqlVFtbG+3s7EyNj4/3ASA8Ho/TZDKpGWNHotHo17PZ7B29pFmXx9SxWIwwxv6ASrM0rUxP0EAg8FfLss5Go1EmpVTNOhazXuKllDoSiVDbti8zxv4MgCSTSUUBmEQiQZLJpKSU/mjLli0QQhittfm8gKC1BmNM3XPPPYQx9uPR0dFCIpGgAMpzf+l02iQSCXb8+PHLnZ2dJBQK7clms9IYQymlpJVvvpJDdLq7u32WZf02lUr9rnaMrlpOSafTiMfjfGRk5ERXV1d7OBx+dH5+XkspUZ6ZIi3J9pRS1d3dLYLB4MupVOrpmsmxao5iye8SiQStjM390nGcn8/MzGB+fl4CIIwxWt67ecfmABillAGgI5EI37p1K/x+/2/GxsZ+WrF4SxKPy1FSC8K3jDEv5HK5R7LZLBYXFyGlVKbypmYCwnNyOOcsGAwiFoshGAxeoJQeGBsb+8tyxNcDAMAnk2Tbt2/3hcPh70sp9zmO0+c4jt913aaKBbyUWaVzzLUsa4wx9vL09PQrV69eLax5dPbTIHjPfX199zPGvqyUeqCZhqcJIRrALKX0EiHkzOjo6KV6NKxr/9WOojeTDlztmf8HtQbED2JR8D0AAAAASUVORK5CYII='

$script:AppIcon = $null
$script:EmbeddedIcon = $null
try {
    $iconBytes = [Convert]::FromBase64String($script:IconPngB64)
    $iconStream = New-Object IO.MemoryStream (, $iconBytes)
    $bmp = New-Object Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.CacheOption = 'OnLoad'
    $bmp.StreamSource = $iconStream
    $bmp.EndInit()
    $bmp.Freeze()
    $script:EmbeddedIcon = $bmp
}
catch { }

$script:IconFile = Join-Path $script:ScriptDir 'app.ico'
if (Test-Path -LiteralPath $script:IconFile) {
    try {
        $uri = [Uri]::new((Resolve-Path -LiteralPath $script:IconFile).Path, [UriKind]::Absolute)
        $script:AppIcon = [Windows.Media.Imaging.BitmapFrame]::Create($uri)
    }
    catch { }
}
if ($null -eq $script:AppIcon -and $exePath -and $isCompiled) {
    try {
        $sysIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($exePath)
        if ($sysIcon) {
            $src = [Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                $sysIcon.Handle,
                [Windows.Int32Rect]::Empty,
                [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
            $src.Freeze()
            $script:AppIcon = $src
            $sysIcon.Dispose()
        }
    }
    catch { }
}
if ($null -eq $script:AppIcon) { $script:AppIcon = $script:EmbeddedIcon }
if ($script:AppIcon) { $window.Icon = $script:AppIcon }
if ($script:EmbeddedIcon) { $TitleIcon.Source = $script:EmbeddedIcon }
elseif ($script:AppIcon) { $TitleIcon.Source = $script:AppIcon }
else { $TitleIcon.Visibility = 'Collapsed' }

# ---- лог ----

$script:LogCount = 0
$LogBox.Document.Blocks.Clear()
$LogBox.Document.PagePadding = [Windows.Thickness]::new(0)

function Add-LogLine([string]$entry) {
    $level = 'info'
    $text = $entry
    $tab = $entry.IndexOf("`t")
    if ($tab -ge 0) {
        $level = $entry.Substring(0, $tab)
        $text = $entry.Substring($tab + 1)
    }
    $color = switch ($level) {
        'ok' { '#7FD88F' }
        'warn' { '#F5A742' }
        'err' { '#E06C75' }
        default { '#A0A0A0' }
    }

    $timePart = ''
    $bodyPart = $text
    if ($text.Length -ge 10) {
        $timePart = $text.Substring(0, 10)
        $bodyPart = $text.Substring(10)
    }

    $para = [Windows.Documents.Paragraph]::new()
    $para.Margin = [Windows.Thickness]::new(0)
    $para.LineHeight = 16
    $runTime = [Windows.Documents.Run]::new($timePart)
    $runTime.Foreground = Brush '#606060'
    $runBody = [Windows.Documents.Run]::new($bodyPart)
    $runBody.Foreground = Brush $color
    [void]$para.Inlines.Add($runTime)
    [void]$para.Inlines.Add($runBody)
    [void]$LogBox.Document.Blocks.Add($para)
    $script:LogCount++

    while ($LogBox.Document.Blocks.Count -gt 600) {
        $LogBox.Document.Blocks.Remove($LogBox.Document.Blocks.FirstBlock)
    }

    try {
        $prefix = switch ($level) {
            'warn' { '[!] ' }
            'err' { '[x] ' }
            'ok' { '[+] ' }
            default { '' }
        }
        [IO.File]::AppendAllText($script:LogFile, $prefix + $text + "`r`n", (New-Object Text.UTF8Encoding($false)))
        $script:LogWrites++
        if (($script:LogWrites % 500) -eq 0) { Invoke-LogRotation }
    }
    catch { }
}

# ---- лимиты ----

function Update-LimitInputs {
    $mode = [string]$state.LimitMode
    $CountBox.Visibility = if ($mode -eq 'count') { 'Visible' } else { 'Collapsed' }
    $TimeBox.Visibility = if ($mode -eq 'time') { 'Visible' } else { 'Collapsed' }
    $ProgressRow.Visibility = if ($mode -eq 'none') { 'Collapsed' } else { 'Visible' }

    $CountBox.ToolTip = 'Сколько отправок за запуск'
    if ($mode -eq 'time') {
        $parsed = Parse-TimeText $TimeBox.Text
        if ($parsed) {
            $deadline = Get-NextDeadline $parsed.Hour $parsed.Minute
            $day = if ($deadline.Date -eq (Get-Date).Date) { 'сегодня' } else { 'завтра' }
            $TimeBox.ToolTip = "Остановится в $($parsed.Text) · $day"
        }
        else {
            $TimeBox.ToolTip = 'Формат: ЧЧ:ММ'
        }
    }
}

function Apply-LimitFromUi {
    $count = Read-LimitCount
    if ($count -gt 0) {
        $state.LimitCount = $count
        $CountBox.BorderBrush = Brush '#282828'
    }
    else {
        $CountBox.BorderBrush = Brush '#E06C75'
    }

    $parsed = Parse-TimeText $TimeBox.Text
    if ($parsed) {
        $state.LimitTime = $parsed.Text
        $state.DeadlineTicks = (Get-NextDeadline $parsed.Hour $parsed.Minute).Ticks
        $state.LimitSince = Get-Date
        $TimeBox.BorderBrush = Brush '#282828'
    }
    else {
        $state.DeadlineTicks = [long]0
        $TimeBox.BorderBrush = Brush '#E06C75'
    }

    Update-LimitInputs
    $script:Dirty = $true
}

function Set-LimitModeUi([string]$mode) {
    if ($mode -notin @('none', 'count', 'time')) { $mode = 'none' }
    $state.LimitMode = $mode
    switch ($mode) {
        'none' { $LimitNone.IsChecked = $true }
        'count' { $LimitCountRadio.IsChecked = $true }
        'time' { $LimitTimeRadio.IsChecked = $true }
    }
    if ($mode -eq 'time') {
        $parsed = Parse-TimeText $TimeBox.Text
        if ($parsed) {
            $state.LimitTime = $parsed.Text
            $state.DeadlineTicks = (Get-NextDeadline $parsed.Hour $parsed.Minute).Ticks
            $state.LimitSince = Get-Date
        }
        else {
            $state.DeadlineTicks = [long]0
        }
    }
    elseif ($mode -eq 'count') {
        $n = Read-LimitCount
        if ($n -gt 0) { $state.LimitCount = $n }
    }
    Update-LimitInputs
    Update-Stats
    $script:Dirty = $true
}

# ---- статус и статистика ----

$script:UiStatus = ''
$script:LastReason = ''
$script:LastServer = ''

function Show-Balloon([string]$title, [string]$text) {
    if (-not $script:TrayIcon) { return }
    try {
        $script:TrayIcon.BalloonTipTitle = $title
        $script:TrayIcon.BalloonTipText = $text
        $script:TrayIcon.ShowBalloonTip(4000)
    }
    catch { }
}

function Set-StatusLook([string]$label, [string]$color, [string]$glyph, [string]$action, [string]$btnBg, [string]$btnFg, [bool]$pulse) {
    $StatusText.Text = $label
    $StatusText.Foreground = Brush $color
    $StatusDot.Fill = Brush $color
    $MainActionGlyph.Text = $glyph
    $MainActionText.Text = $action
    $MainActionBtn.Background = Brush $btnBg
    $MainActionBtn.Foreground = Brush $btnFg
    if ($pulse -and $script:PulseAnimation) {
        $StatusDot.BeginAnimation([Windows.UIElement]::OpacityProperty, $script:PulseAnimation)
    }
    else {
        $StatusDot.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
        $StatusDot.Opacity = 1
    }
}

function Update-StatusVisual {
    if ($null -eq $StatusDot) { return }
    $reason = [string]$state.StopReason
    $running = -not [bool]$state.Stop

    if ($running) { $statusKey = 'running' }
    elseif ($reason -eq 'error') { $statusKey = 'error' }
    elseif ($reason -eq 'limit') { $statusKey = 'limit' }
    else { $statusKey = 'paused' }

    if ($statusKey -ne $script:UiStatus) {
        $script:UiStatus = $statusKey
        switch ($statusKey) {
            'running' { Set-StatusLook 'РАБОТАЕТ' '#7FD88F' ([string][char]0xE71A) 'ОСТАНОВИТЬ' '#E06C75' '#0A0A0A' $true }
            'paused' { Set-StatusLook 'ПАУЗА' '#F5A742' ([string][char]0xE768) 'ЗАПУСТИТЬ' '#FAB283' '#0A0A0A' $false }
            'limit' { Set-StatusLook 'ЛИМИТ' '#F5A742' ([string][char]0xE768) 'НОВЫЙ ЗАПУСК' '#FAB283' '#0A0A0A' $false }
            'error' { Set-StatusLook 'НЕТ СВЯЗИ' '#E06C75' ([string][char]0xE72C) 'ПОВТОРИТЬ' '#5C9CF5' '#0A0A0A' $false }
        }

        if ($reason -ne $script:LastReason) {
            if ($reason -eq 'error') {
                Show-Balloon 'OpenCode AutoContinue' 'Нет связи с OpenCode. Автопродолжение приостановлено, переподключение в фоне.'
            }
            elseif ($reason -eq 'limit') {
                Show-Balloon 'OpenCode AutoContinue' 'Лимит запуска достигнут — автопродолжение остановлено.'
            }
            $script:LastReason = $reason
        }

        if ($script:TrayIcon) {
            $script:TrayIcon.Text = if ($running) { 'OpenCode AutoContinue — работает' } else { 'OpenCode AutoContinue — пауза' }
        }
        if ($script:TrayToggle) {
            $script:TrayToggle.Text = if ($running) { 'Остановить' } else { 'Запустить' }
        }
    }
}

function Update-Stats {
    if ($null -eq $StatusMeta) { return }
    $chats = @($state.Chats)
    $chatCount = $chats.Count
    $sent = [int]$state.SentThisRun
    $running = -not [bool]$state.Stop

    if ($running) {
        $elapsed = if ($state.RunStartedAt -ne [datetime]::MinValue) { Format-Duration ((Get-Date) - [datetime]$state.RunStartedAt) } else { '00:00:00' }
        $StatusMeta.Text = "$sent отпр. · $elapsed"
    }
    elseif ([string]$state.StopReason -eq 'error') {
        $StatusMeta.Text = 'переподключаюсь…'
    }
    else {
        $StatusMeta.Text = "$sent отпр."
    }

    $ChatCountText.Text = [string]$chatCount

    $mode = [string]$state.LimitMode
    $now = Get-Date
    if ($mode -eq 'count') {
        $limit = [Math]::Max(1, [int]$state.LimitCount)
        $value = [Math]::Min($sent, $limit)
        $LimitProgress.Maximum = $limit
        $LimitProgress.Value = $value
        $LimitProgress.Foreground = if ($value -ge $limit) { Brush '#F5A742' } else { Brush '#FAB283' }
        $ProgressLabel.Text = "$value / $limit"
    }
    elseif ($mode -eq 'time') {
        $deadline = if ([long]$state.DeadlineTicks -gt 0) { [datetime]::new([long]$state.DeadlineTicks) } else { $null }
        $LimitProgress.Maximum = 1
        if ($null -ne $deadline) {
            $left = $deadline - $now
            if ($left.TotalSeconds -le 0) {
                $ProgressLabel.Text = "до $($deadline.ToString('HH:mm')) · время вышло"
                $LimitProgress.Value = 1
                $LimitProgress.Foreground = Brush '#F5A742'
            }
            else {
                $ProgressLabel.Text = "до $($deadline.ToString('HH:mm')) · осталось $(Format-Duration $left)"
                $start = [datetime]$state.RunStartedAt
                if ($state.LimitSince -ne [datetime]::MinValue -and [datetime]$state.LimitSince -gt $start) { $start = [datetime]$state.LimitSince }
                if ($start -ne [datetime]::MinValue -and $deadline -gt $start) {
                    $total = ($deadline - $start).TotalSeconds
                    $passed = ($now - $start).TotalSeconds
                    $LimitProgress.Value = [Math]::Max(0, [Math]::Min(1, $passed / [Math]::Max(1, $total)))
                }
                else {
                    $LimitProgress.Value = 0
                }
                $LimitProgress.Foreground = Brush '#FAB283'
            }
        }
        else {
            $ProgressLabel.Text = 'время не задано'
            $LimitProgress.Value = 0
        }
    }
    else {
        $LimitProgress.Maximum = 1
        $LimitProgress.Value = 0
        $ProgressLabel.Text = ''
    }

    if ($state.BaseUrl -ne $script:LastServer) {
        $script:LastServer = [string]$state.BaseUrl
        $short = $script:LastServer -replace '^https?://', ''
        $FooterText.Text = "v$($script:AppVersion) · $short"
    }

    $LogLiveDot.Fill = if ($running) { Brush '#7FD88F' } else { Brush '#606060' }
    $LogLiveDot.Opacity = if ($running) { 0.85 } else { 0.4 }
}

# ---- строки чатов ----

$script:Rows = @()
$script:LastSig = ''

function Get-ChatPhaseColor($chat) {
    switch ([string]$chat.Phase) {
        'running' { return '#F5A742' }
        'sent' { return '#5C9CF5' }
        'blocked' { return '#E06C75' }
        default {
            if ([string]$chat.Status -like 'ошибка*') { return '#E06C75' }
            if ([string]$chat.Status -like 'ответ получен*') { return '#7FD88F' }
            return '#606060'
        }
    }
}

function New-ChatRow($chat) {
    $row = [Windows.Controls.Border]::new()
    $row.Background = Brush '#141414'
    $row.BorderBrush = Brush '#282828'
    $row.BorderThickness = [Windows.Thickness]::new(1)
    $row.CornerRadius = [Windows.CornerRadius]::new(6)
    $row.Padding = [Windows.Thickness]::new(11, 6, 6, 6)
    $row.Margin = [Windows.Thickness]::new(0, 0, 0, 4)
    $row.Add_MouseEnter({ $this.Background = Brush '#1A1A1A'; $this.BorderBrush = Brush '#3C3C3C' })
    $row.Add_MouseLeave({ $this.Background = Brush '#141414'; $this.BorderBrush = Brush '#282828' })

    $grid = [Windows.Controls.Grid]::new()
    foreach ($w in @('Auto', '*', 'Auto', 'Auto')) {
        $cd = [Windows.Controls.ColumnDefinition]::new()
        $cd.Width = if ($w -eq '*') { [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) } else { [Windows.GridLength]::Auto }
        $grid.ColumnDefinitions.Add($cd) | Out-Null
    }

    $dot = [Windows.Shapes.Ellipse]::new()
    $dot.Width = 6
    $dot.Height = 6
    $dot.Margin = [Windows.Thickness]::new(0, 0, 10, 0)
    $dot.VerticalAlignment = 'Center'
    $dot.Fill = Brush (Get-ChatPhaseColor $chat)
    $grid.Children.Add($dot) | Out-Null

    $stack = [Windows.Controls.StackPanel]::new()
    $stack.VerticalAlignment = 'Center'
    $title = [Windows.Controls.TextBlock]::new()
    $title.Text = if ($chat.Title) { [string]$chat.Title } else { '(без названия)' }
    $title.FontSize = 12
    $title.FontWeight = [Windows.FontWeights]::SemiBold
    $title.Foreground = Brush '#EEEEEE'
    $title.TextTrimming = 'CharacterEllipsis'
    $title.ToolTip = $title.Text
    $status = [Windows.Controls.TextBlock]::new()
    $status.Text = [string]$chat.Status
    $status.FontSize = 10
    $status.Margin = [Windows.Thickness]::new(0, 1, 0, 0)
    $status.Foreground = Brush '#808080'
    $status.TextTrimming = 'CharacterEllipsis'
    [void]$stack.Children.Add($title)
    [void]$stack.Children.Add($status)
    [Windows.Controls.Grid]::SetColumn($stack, 1)
    $grid.Children.Add($stack) | Out-Null

    $countBadge = [Windows.Controls.Border]::new()
    $countBadge.Background = Brush '#1E1E1E'
    $countBadge.CornerRadius = [Windows.CornerRadius]::new(4)
    $countBadge.Padding = [Windows.Thickness]::new(7, 2, 7, 2)
    $countBadge.Margin = [Windows.Thickness]::new(8, 0, 6, 0)
    $countBadge.VerticalAlignment = 'Center'
    $countTb = [Windows.Controls.TextBlock]::new()
    $countTb.Text = [string]$chat.Count
    $countTb.FontSize = 10.5
    $countTb.FontWeight = [Windows.FontWeights]::SemiBold
    $countTb.Foreground = Brush '#FAB283'
    $countBadge.Child = $countTb
    $countBadge.ToolTip = 'Отправлено сообщений'
    [Windows.Controls.Grid]::SetColumn($countBadge, 2)
    $grid.Children.Add($countBadge) | Out-Null

    $remove = [Windows.Controls.Border]::new()
    $remove.Width = 24
    $remove.Height = 24
    $remove.CornerRadius = [Windows.CornerRadius]::new(5)
    $remove.Background = [Windows.Media.Brushes]::Transparent
    $remove.Cursor = [Windows.Input.Cursors]::Hand
    $remove.VerticalAlignment = 'Center'
    $remove.ToolTip = 'Убрать чат из списка (и не добавлять автоматически)'
    $remove.Tag = [string]$chat.Id
    $x = [Windows.Controls.TextBlock]::new()
    $x.Text = [string][char]0x2715
    $x.FontSize = 9.5
    $x.Foreground = Brush '#606060'
    $x.HorizontalAlignment = 'Center'
    $x.VerticalAlignment = 'Center'
    $remove.Child = $x
    $remove.Add_MouseEnter({ $this.Background = Brush '#2A1416'; $this.Child.Foreground = Brush '#E06C75' })
    $remove.Add_MouseLeave({ $this.Background = [Windows.Media.Brushes]::Transparent; $this.Child.Foreground = Brush '#606060' })
    $remove.Add_MouseLeftButtonUp({ if ($this.Tag) { Remove-ChatFromUi $this.Tag } })
    [Windows.Controls.Grid]::SetColumn($remove, 3)
    $grid.Children.Add($remove) | Out-Null

    $row.Child = $grid
    return @{
        Element = $row
        Dot     = $dot
        Status  = $status
        Title   = $title
        Count   = $countTb
        Phase   = ''
    }
}

function Build-ChatRows {
    $ChatPanel.Children.Clear()
    $script:Rows = @()
    $chats = @($state.Chats)

    if ($chats.Count -eq 0) {
        $empty = [Windows.Controls.Border]::new()
        $empty.Background = Brush '#0F0F0F'
        $empty.BorderBrush = Brush '#282828'
        $empty.BorderThickness = [Windows.Thickness]::new(1)
        $empty.CornerRadius = [Windows.CornerRadius]::new(6)
        $empty.Padding = [Windows.Thickness]::new(12, 11, 12, 11)
        $empty.Margin = [Windows.Thickness]::new(0, 0, 0, 4)
        $t = [Windows.Controls.TextBlock]::new()
        $t.Text = if ([bool]$state.AutoAdd) { 'Жду активные чаты OpenCode…' } else { 'Чатов нет — нажмите «+ Добавить»' }
        $t.FontSize = 11
        $t.Foreground = Brush '#606060'
        $t.TextTrimming = 'CharacterEllipsis'
        $empty.Child = $t
        $ChatPanel.Children.Add($empty) | Out-Null
        return
    }

    foreach ($chat in $chats) {
        $refs = New-ChatRow $chat
        $ChatPanel.Children.Add($refs.Element) | Out-Null
        $script:Rows += , $refs
    }
}

function Update-ChatRows {
    $chats = @($state.Chats)
    if ($chats.Count -ne $script:Rows.Count) { Build-ChatRows; return }

    for ($i = 0; $i -lt $chats.Count; $i++) {
        $chat = $chats[$i]
        $refs = $script:Rows[$i]
        if ($null -eq $refs) { continue }
        $titleText = if ($chat.Title) { [string]$chat.Title } else { '(без названия)' }
        if ($refs.Title.Text -ne $titleText) { $refs.Title.Text = $titleText; $refs.Title.ToolTip = $titleText }
        $statusText = [string]$chat.Status
        if ($refs.Status.Text -ne $statusText) { $refs.Status.Text = $statusText }
        $countText = [string]$chat.Count
        if ($refs.Count.Text -ne $countText) { $refs.Count.Text = $countText }

        $color = Get-ChatPhaseColor $chat
        if ($refs.Phase -ne $color) {
            $refs.Phase = $color
            $refs.Dot.Fill = Brush $color
            $refs.Status.Foreground = Brush $color
        }
        $refs.Element.Tag = [string]$chat.Id
    }
}

function Remove-ChatFromUi([string]$id) {
    if (-not $id) { return }
    $state.RemoveQueue.Enqueue($id)
    $state.Ignored[$id] = $true
    $script:Dirty = $true
}

# ---- запуск / пауза ----

function Start-Run {
    $wasReason = [string]$state.StopReason
    $mode = [string]$state.LimitMode

    if ($mode -eq 'count') {
        $n = Read-LimitCount
        if ($n -le 0) {
            Write-UiLog 'warn' 'Лимит итераций: укажите число от 1 до 99999'
            $CountBox.Focus() | Out-Null
            return
        }
        $state.LimitCount = $n
        if ($state.SentThisRun -ge $n) {
            $state.SentThisRun = 0
            Write-UiLog 'info' 'Счётчик итераций сброшен — новый запуск'
        }
    }
    elseif ($mode -eq 'time') {
        $parsed = Parse-TimeText $TimeBox.Text
        if (-not $parsed) {
            Write-UiLog 'warn' 'Лимит по времени: укажите время в формате ЧЧ:ММ'
            $TimeBox.Focus() | Out-Null
            return
        }
        $state.LimitTime = $parsed.Text
        $deadline = Get-NextDeadline $parsed.Hour $parsed.Minute
        $state.DeadlineTicks = $deadline.Ticks
        $state.LimitSince = Get-Date
    }

    if ($state.RunStartedAt -eq [datetime]::MinValue -or $wasReason -eq 'limit') {
        $state.RunStartedAt = Get-Date
    }

    # после паузы таймер «ответ не начался» не должен считать время простоя
    foreach ($c in @($state.Chats)) {
        if ([string]$c.Phase -eq 'sent') {
            $c.SentAt = Get-Date
            $c.NoAnswer = 0
        }
    }

    $state.Stop = $false
    $state.StopReason = ''
    $state.LimitHit = ''
    $state.ApiError = ''
    $state.ErrorStreak = 0

    Write-UiLog 'ok' '▶ Автопродолжение запущено'
    Update-StatusVisual
    Update-Stats
}

function Toggle-Run {
    if ($state.Stop) { Start-Run }
    else {
        $state.Stop = $true
        $state.StopReason = 'user'
        Write-UiLog 'warn' '⏸ Автопродолжение остановлено вручную'
        Update-StatusVisual
        Update-Stats
    }
}

# ---- диалог добавления чата ----

function Show-AddDialog {
    if (-not (Update-ServiceInfo)) {
        [void][Windows.MessageBox]::Show('Сервис OpenCode не найден. Запустите OpenCode и попробуйте снова.',
            'OpenCode AutoContinue', 'OK', 'Warning')
        return
    }
    Update-ServiceInfo | Out-Null

    try {
        $r = Invoke-OcApi 'GET' '/api/session?limit=100' -Timeout 6000
    }
    catch {
        [void][Windows.MessageBox]::Show('Не удалось получить список чатов: ' + $_.Exception.Message,
            'OpenCode AutoContinue', 'OK', 'Warning')
        return
    }

    $tracked = @{}
    foreach ($c in @($state.Chats)) { if ($c.Id) { $tracked[[string]$c.Id] = $true } }

    $all = @($r.data | Where-Object { -not $_.parentID -and -not $_.archived -and -not $tracked.ContainsKey([string]$_.id) })
    if ($all.Count -eq 0) {
        [void][Windows.MessageBox]::Show('Нет доступных чатов для добавления.',
            'OpenCode AutoContinue', 'OK', 'Information')
        return
    }

    $dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Добавить чат" Width="400" Height="440"
        WindowStyle="None" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" Background="#0A0A0A" Foreground="#EEEEEE"
        FontFamily="Cascadia Mono, Consolas" UseLayoutRounding="True">
  <Window.Resources>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#141414"/>
      <Setter Property="Foreground" Value="#EEEEEE"/>
      <Setter Property="CaretBrush" Value="#FAB283"/>
      <Setter Property="BorderBrush" Value="#282828"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            VerticalScrollBarVisibility="{TemplateBinding VerticalScrollBarVisibility}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#FAB283"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ListBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
      <Setter Property="ScrollViewer.VerticalScrollBarVisibility" Value="Auto"/>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="6" Padding="10,7" Margin="0,0,0,3">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1E1E1E"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#282828"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border Background="#3C3C3C" CornerRadius="3" Margin="1,2"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>
                </Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DlgGhost" TargetType="Button">
      <Setter Property="Height" Value="32"/>
      <Setter Property="Padding" Value="14,0"/>
      <Setter Property="Background" Value="#141414"/>
      <Setter Property="Foreground" Value="#A0A0A0"/>
      <Setter Property="BorderBrush" Value="#282828"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1E1E1E"/>
                <Setter Property="Foreground" Value="#EEEEEE"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DlgPrimary" TargetType="Button">
      <Setter Property="Height" Value="32"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Background" Value="#FAB283"/>
      <Setter Property="Foreground" Value="#0A0A0A"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6"/>
              <Border x:Name="Hover" Background="#18FFFFFF" CornerRadius="6" Opacity="0"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Hover" Property="Opacity" Value="1"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DlgClose" TargetType="Button">
      <Setter Property="Width" Value="30"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#808080"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#E06C75"/>
                <Setter Property="Foreground" Value="#0A0A0A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border Background="#0A0A0A" BorderBrush="#282828" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="36"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="56"/>
      </Grid.RowDefinitions>
      <Border Grid.Row="0" BorderBrush="#282828" BorderThickness="0,0,0,1">
        <Grid>
          <TextBlock x:Name="DlgTitle" Text="Добавить чат" FontSize="11.5" FontWeight="SemiBold" Foreground="#EEEEEE"
                     VerticalAlignment="Center" Margin="14,0,0,0"/>
          <Button x:Name="DlgCloseBtn" Style="{StaticResource DlgClose}" HorizontalAlignment="Right" Margin="0,0,8,0"
                  Content="&#xE8BB;"/>
        </Grid>
      </Border>
      <Grid Grid.Row="1" Margin="14,8,14,8">
        <TextBox x:Name="SearchBox" Height="34" Padding="10,5" VerticalContentAlignment="Center"/>
        <TextBlock x:Name="SearchHint" Text="Поиск по названию…" FontSize="11.5" Foreground="#606060"
                   Margin="11,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
      </Grid>
      <ListBox x:Name="SessionList" Grid.Row="2" Margin="14,0,14,0"/>
      <Grid Grid.Row="3" Margin="14,10,14,12">
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="DlgCancelBtn" Width="88" Content="Отмена" Style="{StaticResource DlgGhost}"/>
          <Button x:Name="DlgAddBtn" Width="108" Content="Добавить" Margin="8,0,0,0" Style="{StaticResource DlgPrimary}"/>
        </StackPanel>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

    $dlg = [Windows.Markup.XamlReader]::Parse($dialogXaml)
    $dlg.Owner = $window
    $dlg.Topmost = $window.Topmost

    $dlgClose = $dlg.FindName('DlgCloseBtn')
    $dlgCancel = $dlg.FindName('DlgCancelBtn')
    $dlgAdd = $dlg.FindName('DlgAddBtn')
    $search = $dlg.FindName('SearchBox')
    $hint = $dlg.FindName('SearchHint')
    $list = $dlg.FindName('SessionList')
    $dlgTitle = $dlg.FindName('DlgTitle')
    $dlgTitle.Add_MouseLeftButtonDown({ try { $dlg.DragMove() } catch { } })

    $dlgClose.Add_Click({ $dlg.Close() })
    $dlgCancel.Add_Click({ $dlg.Close() })
    $dlg.Add_KeyDown({
            param($s, $e)
            if ($e.Key -eq 'Escape') { $dlg.Close() }
            elseif ($e.Key -eq 'Enter' -and $list.SelectedIndex -ge 0) { Add-Selected }
        })

    $script:DialogCandidates = @()

    function Build-DialogList([string]$filter) {
        $list.Items.Clear()
        $script:DialogCandidates = @()
        $needle = $filter.Trim().ToLowerInvariant()
        foreach ($s in $all) {
            $title = [string]$s.title
            if (-not $title) { $title = '(без названия)' }
            if ($needle -and $title.ToLowerInvariant().IndexOf($needle) -lt 0) { continue }
            $when = ''
            try {
                $when = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$s.time.updated).LocalDateTime.ToString('dd.MM.yy HH:mm')
            }
            catch { }

            $panel = [Windows.Controls.StackPanel]::new()
            $tt = [Windows.Controls.TextBlock]::new()
            $tt.Text = $title
            $tt.FontSize = 12
            $tt.FontWeight = [Windows.FontWeights]::SemiBold
            $tt.Foreground = Brush '#EEEEEE'
            $tt.TextTrimming = 'CharacterEllipsis'
            $mm = [Windows.Controls.TextBlock]::new()
            $meta = if ($when) { "$when  ·  " } else { '' }
            $mm.Text = $meta + [string]$s.id
            $mm.FontSize = 9.5
            $mm.Margin = [Windows.Thickness]::new(0, 1, 0, 0)
            $mm.Foreground = Brush '#606060'
            $mm.TextTrimming = 'CharacterEllipsis'
            [void]$panel.Children.Add($tt)
            [void]$panel.Children.Add($mm)
            [void]$list.Items.Add($panel)
            $script:DialogCandidates += , @{ Id = [string]$s.id; Title = [string]$s.title }
        }
        $dlgAdd.IsEnabled = ($list.Items.Count -gt 0)
        if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }
        $hint.Visibility = if ($filter.Length -gt 0) { 'Collapsed' } else { 'Visible' }
    }

    function Add-Selected {
        $idx = $list.SelectedIndex
        if ($idx -lt 0 -or $idx -ge $script:DialogCandidates.Count) { return }
        $cand = $script:DialogCandidates[$idx]
        if (-not $cand.Id) { return }
        $state.AddQueue.Enqueue(@{ Id = [string]$cand.Id; Title = [string]$cand.Title })
        $state.Ignored.Remove([string]$cand.Id)
        $script:Dirty = $true
        $dlg.Close()
    }

    $search.Add_TextChanged({ Build-DialogList $search.Text })
    $list.Add_SelectionChanged({ $dlgAdd.IsEnabled = ($list.SelectedIndex -ge 0) })
    $list.Add_MouseDoubleClick({ if ($list.SelectedIndex -ge 0) { Add-Selected } })
    $dlgAdd.Add_Click({ Add-Selected })
    $dlg.Add_Loaded({ $search.Focus() | Out-Null })

    Build-DialogList ''
    [void]$dlg.ShowDialog()
}

# ---- настройки из контролов ----

$MessageBox.Text = [string]$state.Message
$MessageHint.Visibility = if ($MessageBox.Text.Length -gt 0) { 'Collapsed' } else { 'Visible' }
$AutoAddChk.IsChecked = [bool]$state.AutoAdd
$CountBox.Text = [string]$state.LimitCount
$TimeBox.Text = [string]$state.LimitTime

# ---- обработчики ----

$MessageBox.Add_TextChanged({
        $state.Message = $MessageBox.Text
        $MessageHint.Visibility = if ($MessageBox.Text.Length -gt 0) { 'Collapsed' } else { 'Visible' }
        $script:Dirty = $true
    })

$AutoAddChk.Add_Click({
        $state.AutoAdd = [bool]$AutoAddChk.IsChecked
        Write-UiLog 'info' ('Автодобавление чатов: ' + $(if ($state.AutoAdd) { 'вкл' } else { 'выкл' }))
        Build-ChatRows
        $script:Dirty = $true
    })

$TopmostChk.Add_Click({
        $script:Topmost = [bool]$TopmostChk.IsChecked
        $window.Topmost = $script:Topmost
        $settings.topmost = $script:Topmost
        $script:Dirty = $true
    })

$SettingsBtn.Add_Click({ Show-SettingsView ($SettingsView.Visibility -ne 'Visible') })
$BackBtn.Add_Click({ Show-SettingsView $false })
$window.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Escape' -and $SettingsView.Visibility -eq 'Visible') {
            Show-SettingsView $false
            $e.Handled = $true
        }
    })

$LimitNone.Add_Checked({ if ($LimitNone.IsChecked) { Set-LimitModeUi 'none' } })
$LimitCountRadio.Add_Checked({ if ($LimitCountRadio.IsChecked) { Set-LimitModeUi 'count' } })
$LimitTimeRadio.Add_Checked({ if ($LimitTimeRadio.IsChecked) { Set-LimitModeUi 'time' } })

$CountBox.Add_TextChanged({
        $n = Read-LimitCount
        if ($n -gt 0) { $state.LimitCount = $n; $script:Dirty = $true; Update-LimitInputs; Update-Stats }
    })
$CountBox.Add_LostFocus({
        $n = Read-LimitCount
        if ($n -gt 0) { $state.LimitCount = $n; $CountBox.Text = [string]$n }
        else { $CountBox.Text = [string]$state.LimitCount }
        Update-LimitInputs
        $script:Dirty = $true
    })

$TimeBox.Add_TextChanged({ Apply-LimitFromUi; Update-Stats })
$TimeBox.Add_LostFocus({
        $parsed = Parse-TimeText $TimeBox.Text
        if ($parsed) { $TimeBox.Text = $parsed.Text }
        else { $TimeBox.Text = [string]$state.LimitTime }
        Apply-LimitFromUi
        Update-Stats
    })

$MainActionBtn.Add_Click({ Toggle-Run })
$AddBtn.Add_Click({ Show-AddDialog })
$ClearBtn.Add_Click({
        $LogBox.Document.Blocks.Clear()
        $script:LogCount = 0
    })
$TrayBtn.Add_Click({ $window.Hide() })
$DataBtn.Add_Click({
        try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $script:AppDir + '"') } catch { }
    })

$window.Add_Loaded({
        $wa = [Windows.SystemParameters]::WorkArea
        $w = [Math]::Max($window.MinWidth, [Math]::Min([int]$settings.winWidth, [int]($wa.Width - 40)))
        $h = [Math]::Max($window.MinHeight, [Math]::Min([int]$settings.winHeight, [int]($wa.Height - 40)))
        $window.Width = $w
        $window.Height = $h
        $window.Left = $wa.Left + [Math]::Max(0, ($wa.Width - $w) / 2)
        $window.Top = $wa.Top + [Math]::Max(0, ($wa.Height - $h) / 2)
        $window.Activate()

        try {
            Add-Type -Namespace Native -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);'
            $hwnd = [Windows.Interop.WindowInteropHelper]::new($window).Handle
            $round = 2
            [void][Native.Dwm]::DwmSetWindowAttribute($hwnd, 33, [ref]$round, 4)
        }
        catch { }
    })

$window.Add_Closed({
        $state.Stop = $true
        $timer.Stop()

        try {
            $w = $window.ActualWidth
            $h = $window.ActualHeight
            if ($w -ge $window.MinWidth -and $h -ge $window.MinHeight) {
                $settings.winWidth = [int]$w
                $settings.winHeight = [int]$h
            }
            Save-Settings
        }
        catch { }

        if ($script:TrayIcon) {
            try { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() } catch { }
        }
    })

# ---- анимация статуса ----

$script:PulseAnimation = [Windows.Media.Animation.DoubleAnimation]::new(0.35, 1.0, [TimeSpan]::FromSeconds(1.4))
$script:PulseAnimation.AutoReverse = $true
$script:PulseAnimation.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever

# ---- трей ----

$script:TrayIcon = $null
$script:TrayToggle = $null
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $trayIcon = New-Object System.Windows.Forms.NotifyIcon
    if (Test-Path -LiteralPath $script:IconFile) {
        try { $trayIcon.Icon = New-Object System.Drawing.Icon -ArgumentList $script:IconFile } catch { }
    }
    if (-not $trayIcon.Icon -and $isCompiled) {
        try { $trayIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exePath) } catch { }
    }
    if (-not $trayIcon.Icon) {
        try {
            $pngStream = New-Object IO.MemoryStream (, [Convert]::FromBase64String($script:IconPngB64))
            $pngBmp = New-Object System.Drawing.Bitmap $pngStream
            $trayIcon.Icon = [System.Drawing.Icon]::FromHandle($pngBmp.GetHicon())
        }
        catch { }
    }
    if (-not $trayIcon.Icon) { $trayIcon.Icon = [System.Drawing.SystemIcons]::Application }
    $trayIcon.Text = 'OpenCode AutoContinue'
    $trayIcon.Visible = $true

    $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $trayShow = New-Object System.Windows.Forms.ToolStripMenuItem('Показать окно')
    $script:TrayToggle = New-Object System.Windows.Forms.ToolStripMenuItem('Остановить')
    $trayExit = New-Object System.Windows.Forms.ToolStripMenuItem('Выход')
    [void]$trayMenu.Items.Add($trayShow)
    [void]$trayMenu.Items.Add($script:TrayToggle)
    [void]$trayMenu.Items.Add($trayExit)
    $trayIcon.ContextMenuStrip = $trayMenu

    $trayShow.Add_Click({ $window.Show(); $window.WindowState = 'Normal'; $window.Activate() })
    $script:TrayToggle.Add_Click({ Toggle-Run })
    $trayExit.Add_Click({ $window.Close() })
    $trayIcon.Add_DoubleClick({ $window.Show(); $window.WindowState = 'Normal'; $window.Activate() })

    $script:TrayIcon = $trayIcon
}
catch { }

# ---- таймер интерфейса ----

$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(220)
$timer.Add_Tick({
        try {
            $drained = 0
            $lines = @()
            while ($drained -lt 60) {
                $line = $null
                if (-not $state.Log.TryDequeue([ref]$line)) { break }
                $lines += $line
                $drained++
            }
            foreach ($line in $lines) { Add-LogLine $line }
            if ($lines.Count -gt 0 -and $SettingsView.Visibility -eq 'Visible') { $LogBox.ScrollToEnd() }

            $sigParts = @()
            foreach ($chat in @($state.Chats)) {
                $sigParts += ([string]$chat.Id + '|' + [string]$chat.Title)
            }
            $sig = $sigParts -join '~'
            if ($sig -ne $script:LastSig) {
                $script:LastSig = $sig
                Build-ChatRows
                $script:Dirty = $true
            }
            Update-ChatRows

            $statusKey = if (-not [bool]$state.Stop) { 'running' } else { [string]$state.StopReason }
            if ($statusKey -ne $script:LastStatusKey) {
                $script:LastStatusKey = $statusKey
                Update-StatusVisual
            }
            Update-Stats

            if ($script:Dirty) { Save-Settings }
        }
        catch {
            try {
                [IO.File]::AppendAllText($script:LogFile, ((Get-Date).ToString('HH:mm:ss') + '  [x] Ошибка интерфейса: ' + $_.Exception.Message + "`r`n"))
            }
            catch { }
        }
    })
$script:LastStatusKey = ''

# ---- старт ----

Set-LimitModeUi ([string]$state.LimitMode)
if ([string]$state.LimitMode -eq 'time') {
    $parsedTime = Parse-TimeText ([string]$state.LimitTime)
    if ($parsedTime) {
        $state.DeadlineTicks = (Get-NextDeadline $parsedTime.Hour $parsedTime.Minute).Ticks
        $state.LimitSince = Get-Date
    }
}
Update-LimitInputs
Update-StatusVisual
Update-Stats
Build-ChatRows
$script:LastSig = (@($state.Chats | ForEach-Object { [string]$_.Id + '|' + [string]$_.Title }) -join '~')
$script:Dirty = $false

Write-UiLog 'info' ('Окно запущено · v' + $script:AppVersion + ' · интервал ' + $state.PollMs + ' мс')
$timer.Start()

[void]$window.ShowDialog()

# ---------------------------------------------------------------- cleanup ----

$state.Stop = $true
$timer.Stop()
Start-Sleep -Milliseconds 300
try {
    if ($workerHandle -and $workerHandle.IsCompleted -eq $false) { $worker.Stop() }
} catch { }
try { $worker.Dispose() } catch { }
try { $runspace.Close(); $runspace.Dispose() } catch { }
try {
    if ($script:AppMutex) {
        $script:AppMutex.ReleaseMutex()
        $script:AppMutex.Dispose()
    }
} catch { }
