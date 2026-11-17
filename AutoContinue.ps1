#requires -version 5.1
<#
    OpenCode AutoContinue
    ---------------------
    Следит за чатами OpenCode и после каждого завершённого ответа бота
    автоматически отправляет ему заданный текст ("Продолжай разработку").

    - Список чатов живёт по sessionId, поэтому переименование чата ничего не ломает.
    - Новые активные чаты подхватываются автоматически (можно выключить).
    - Текст сообщения и список чатов настраиваются прямо в окне и сохраняются
      в settings.json рядом со скриптом.
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
$script:AppVersion = '1.3.0'

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
    autoAdd    = $true
    chats      = @()
    ignored    = @()
    limitMode  = 'none'
    limitCount = 50
    limitTime  = '18:00'
    topmost    = $true
    winWidth   = 860
    winHeight  = 880
}

if (Test-Path -LiteralPath $script:SettingsPath) {
    try {
        $rawText = [IO.File]::ReadAllText($script:SettingsPath, [Text.Encoding]::UTF8)
        $raw = $rawText | ConvertFrom-Json
        if ($raw.message) { $settings.message = [string]$raw.message }
        if ($null -ne $raw.autoAdd) { $settings.autoAdd = [bool]$raw.autoAdd }
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
        if ($null -ne $raw.winWidth) { $settings.winWidth = [int]$raw.winWidth }
        if ($null -ne $raw.winHeight) { $settings.winHeight = [int]$raw.winHeight }
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
    $req.UserAgent = 'OpenCode-AutoContinue/1.3'
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
        $chat.NoAnswer = 0
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
                    try { $infoCache[$id] = (API 'GET' ("/api/session/" + $id)).data }
                    catch { $infoCache[$id] = $null }
                }
                $info = $infoCache[$id]
                if ($null -eq $info) { continue }
                if ($info.parentID) { continue }
                if ($info.archived) { continue }

                Add-Chat $id ([string]$info.title) 'активный чат'
            }
            if ($infoCache.Count -gt 400) { $infoCache = @{} }
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
                }
                elseif (-not $chat.NextTryAt -or (Get-Date) -ge [datetime]$chat.NextTryAt) {
                    Send-Chat $chat
                }
            }
            elseif ($phase -eq 'sent') {
                if ($busy) {
                    $chat.Phase = 'running'
                    $chat.Status = 'печатает…'
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

$uiXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework"
        Title="OpenCode AutoContinue"
        Width="860" Height="880" MinWidth="720" MinHeight="680"
        WindowStyle="None" ResizeMode="CanResize"
        WindowStartupLocation="CenterScreen"
        Background="#0A0E15" Foreground="#ECF1F8"
        FontFamily="Segoe UI Variable Text, Segoe UI"
        TextOptions.TextFormattingMode="Display"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <shell:WindowChrome.WindowChrome>
    <shell:WindowChrome CaptionHeight="0" ResizeBorderThickness="6"
                        GlassFrameThickness="0" CornerRadius="0"
                        UseAeroCaptionButtons="False"/>
  </shell:WindowChrome.WindowChrome>
  <Window.Resources>
    <SolidColorBrush x:Key="TextMain" Color="#ECF1F8"/>
    <SolidColorBrush x:Key="TextMuted" Color="#8B99AE"/>
    <SolidColorBrush x:Key="TextDim" Color="#6B7A90"/>
    <SolidColorBrush x:Key="Accent" Color="#34D399"/>
    <SolidColorBrush x:Key="AccentSoft" Color="#6EE7B7"/>
    <SolidColorBrush x:Key="Danger" Color="#F87171"/>
    <SolidColorBrush x:Key="Warn" Color="#FBBF24"/>
    <SolidColorBrush x:Key="Blue" Color="#60A5FA"/>
    <SolidColorBrush x:Key="FieldBorder" Color="#223047"/>

    <Style x:Key="SectionLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="{StaticResource TextDim}"/>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#101722"/>
      <Setter Property="BorderBrush" Value="#1C2838"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="14"/>
      <Setter Property="Padding" Value="16,14"/>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Height" Value="44"/>
      <Setter Property="Padding" Value="18,0"/>
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="Foreground" Value="#05170E"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="11"/>
              <Border x:Name="Hover" Background="#18FFFFFF" CornerRadius="11" Opacity="0"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Hover" Property="Opacity" Value="1"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Hover" Property="Opacity" Value="1"/>
                <Setter TargetName="Bd" Property="Opacity" Value="0.82"/>
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
      <Setter Property="Height" Value="28"/>
      <Setter Property="Padding" Value="11,0"/>
      <Setter Property="Background" Value="#111927"/>
      <Setter Property="Foreground" Value="#A9B6C8"/>
      <Setter Property="BorderBrush" Value="#223047"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#172234"/>
                <Setter Property="Foreground" Value="#E8EEF7"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1E2C42"/>
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
      <Setter Property="Foreground" Value="#7E8CA3"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Padding" Value="7,3"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#131C29"/>
                <Setter Property="Foreground" Value="#C8D4E4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="IconButton" TargetType="Button">
      <Setter Property="Width" Value="30"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#78879D"/>
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="7">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#172131"/>
                <Setter Property="Foreground" Value="#E8EEF7"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#212D40"/>
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
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="7">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#B91C1C"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#991B1B"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SegmentRadio" TargetType="RadioButton">
      <Setter Property="Height" Value="30"/>
      <Setter Property="Foreground" Value="#8B99AE"/>
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" Background="#0D141E" BorderBrush="#1C2838" BorderThickness="1" CornerRadius="7">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#2C3C55"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#12291F"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#2E6A4F"/>
                <Setter Property="Foreground" Value="#6EE7B7"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#DCE6F3"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Track" Width="36" Height="20" CornerRadius="10" Background="#182233"
                      BorderBrush="#2A3A50" BorderThickness="1" VerticalAlignment="Center">
                <Ellipse x:Name="Knob" Width="14" Height="14" Fill="#7A8798" HorizontalAlignment="Left" Margin="2,0,0,0"/>
              </Border>
              <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#123626"/>
                <Setter TargetName="Track" Property="BorderBrush" Value="#2F7A51"/>
                <Setter TargetName="Knob" Property="Fill" Value="#34D399"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Margin" Value="0,0,2,0"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Track" Property="BorderBrush" Value="#3A506C"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#0A1019"/>
      <Setter Property="Foreground" Value="{StaticResource TextMain}"/>
      <Setter Property="CaretBrush" Value="{StaticResource AccentSoft}"/>
      <Setter Property="SelectionBrush" Value="#2563EB"/>
      <Setter Property="BorderBrush" Value="{StaticResource FieldBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="9">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            VerticalScrollBarVisibility="{TemplateBinding VerticalScrollBarVisibility}"
                            HorizontalScrollBarVisibility="{TemplateBinding HorizontalScrollBarVisibility}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#3F6E5C"/>
                <Setter TargetName="Bd" Property="Background" Value="#0C1420"/>
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
                        <Border Background="#2A374B" CornerRadius="3" Margin="1,2"/>
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
      <Setter Property="Background" Value="#141D2B"/>
      <Setter Property="Foreground" Value="#D7E2F0"/>
      <Setter Property="BorderBrush" Value="#273449"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToolTip">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ProgressBar">
      <Setter Property="Background" Value="#1A2434"/>
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Border Background="{TemplateBinding Background}" CornerRadius="2" ClipToBounds="True">
              <Grid x:Name="PART_Track">
                <Border x:Name="PART_Indicator" HorizontalAlignment="Left" Background="{TemplateBinding Foreground}" CornerRadius="2"/>
              </Grid>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="WindowFrame" Background="#0A0E15" BorderBrush="#1B2634" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="46"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <!-- ===== title bar ===== -->
      <Border Grid.Row="0" BorderBrush="#141D2A" BorderThickness="0,0,0,1" Background="#0A0E15">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Grid x:Name="DragArea" Background="Transparent">
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0,0,0">
              <Image x:Name="TitleIcon" Width="20" Height="20" Margin="0,0,10,0"
                     RenderOptions.BitmapScalingMode="HighQuality"/>
              <TextBlock Text="AutoContinue" FontSize="12.5" FontWeight="SemiBold"
                         Foreground="#E8EEF7" VerticalAlignment="Center"/>
              <Border Background="#111926" BorderBrush="#1E2A3B" BorderThickness="1"
                      CornerRadius="5" Padding="6,2" Margin="10,0,0,0" VerticalAlignment="Center">
                <TextBlock Text="OPENCODE" FontSize="8" FontWeight="Bold" Foreground="#73839A"/>
              </Border>
            </StackPanel>
          </Grid>
          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,8,0">
            <Button x:Name="PinBtn" Style="{StaticResource IconButton}" Content="&#xE718;" ToolTip="Поверх всех окон"/>
            <Button x:Name="MinBtn" Style="{StaticResource IconButton}" Content="&#xE921;" ToolTip="Свернуть"/>
            <Button x:Name="MaxBtn" Style="{StaticResource IconButton}" Content="&#xE922;" ToolTip="Развернуть"/>
            <Button x:Name="CloseBtn" Style="{StaticResource CloseButton}" Content="&#xE8BB;" ToolTip="Выход"/>
          </StackPanel>
        </Grid>
      </Border>

      <!-- ===== body ===== -->
      <Grid Grid.Row="1" Margin="20,14,20,12">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- hero -->
        <Border x:Name="HeroCard" Grid.Row="0" CornerRadius="16" BorderThickness="1" BorderBrush="#223349"
                ClipToBounds="True" Margin="0,0,0,14">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
              <GradientStop Color="#132031" Offset="0"/>
              <GradientStop Color="#0E1826" Offset="0.58"/>
              <GradientStop Color="#0B1A18" Offset="1"/>
            </LinearGradientBrush>
          </Border.Background>
          <Grid>
            <Canvas ClipToBounds="True" IsHitTestVisible="False">
              <Ellipse Canvas.Top="-190" Canvas.Right="-120" Width="380" Height="380">
                <Ellipse.Fill>
                  <RadialGradientBrush>
                    <GradientStop Color="#3822C55E" Offset="0"/>
                    <GradientStop Color="#0022C55E" Offset="1"/>
                  </RadialGradientBrush>
                </Ellipse.Fill>
              </Ellipse>
            </Canvas>
            <Grid Margin="20,16,18,14">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>

              <StackPanel Grid.Row="0" Grid.Column="0">
                <StackPanel Orientation="Horizontal">
                  <Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="#34D399" VerticalAlignment="Center">
                    <Ellipse.Effect>
                      <DropShadowEffect Color="#34D399" BlurRadius="12" ShadowDepth="0" Opacity="0.9"/>
                    </Ellipse.Effect>
                  </Ellipse>
                  <TextBlock x:Name="StatusText" Text="РАБОТАЕТ" Margin="9,0,0,0" FontSize="10.5"
                             FontWeight="Bold" Foreground="#6EE7B7"/>
                  <TextBlock x:Name="StatusMeta" Text="· сервер" Margin="8,0,0,0" FontSize="10.5"
                             Foreground="#6C7B91"/>
                </StackPanel>
                <TextBlock x:Name="HeroTitle" Text="Автопродолжение активно" Margin="0,10,0,0"
                           FontSize="22" FontWeight="SemiBold" Foreground="#F1F5FB" TextTrimming="CharacterEllipsis"/>
                <TextBlock x:Name="HeroSub" Text="" Margin="0,5,0,0" FontSize="11.5"
                           Foreground="#8B99AE" TextTrimming="CharacterEllipsis"/>
              </StackPanel>

              <StackPanel Grid.Row="0" Grid.Column="1" VerticalAlignment="Top" HorizontalAlignment="Right" Margin="24,0,0,0">
                <Button x:Name="MainActionBtn" Style="{StaticResource PrimaryButton}" Width="176">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock x:Name="MainActionGlyph" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets"
                               Text="&#xE71A;" FontSize="11" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <TextBlock x:Name="MainActionText" Text="ОСТАНОВИТЬ" VerticalAlignment="Center"/>
                  </StackPanel>
                </Button>
                <TextBlock x:Name="LimitSummary" Text="без лимита" Margin="0,8,0,0" FontSize="10.5"
                           Foreground="#7E8CA1" HorizontalAlignment="Right"/>
              </StackPanel>

              <Grid x:Name="ProgressRow" Grid.Row="1" Grid.ColumnSpan="2" Margin="0,13,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <ProgressBar x:Name="LimitProgress" Height="4" Minimum="0" Maximum="1" Value="0"/>
                <TextBlock x:Name="ProgressLabel" Grid.Column="1" Margin="10,0,0,0" FontSize="10"
                           Foreground="#7E8CA1" VerticalAlignment="Center"/>
              </Grid>
            </Grid>
          </Grid>
        </Border>

        <!-- message + limits -->
        <Grid Grid.Row="1" Margin="0,0,0,14">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="304"/>
          </Grid.ColumnDefinitions>

          <Border Style="{StaticResource Card}" Margin="0,0,12,0">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <TextBlock Text="СООБЩЕНИЕ" Style="{StaticResource SectionLabel}"/>
              <TextBox x:Name="MessageBox" Grid.Row="1" Margin="0,8,0,0" Height="66"
                       AcceptsReturn="True" TextWrapping="Wrap" MaxLength="4000"
                       VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"/>
              <Grid Grid.Row="2" Margin="0,10,0,0">
                <CheckBox x:Name="AutoAddChk" Style="{StaticResource Switch}"
                          Content="Автодобавление чатов" VerticalAlignment="Center" IsChecked="True"/>
                <TextBlock Text="подхватывать активные сессии" HorizontalAlignment="Right"
                           VerticalAlignment="Center" FontSize="10" Foreground="#66748A"/>
              </Grid>
            </Grid>
          </Border>

          <Border Grid.Column="1" Style="{StaticResource Card}">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <TextBlock Text="ЛИМИТ ЗАПУСКА" Style="{StaticResource SectionLabel}"/>
              <Grid Grid.Row="1" Margin="0,8,0,0">
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
              <Grid Grid.Row="2" Margin="0,10,0,0" Height="34">
                <StackPanel x:Name="CountPanel" Orientation="Horizontal">
                  <TextBox x:Name="CountBox" Width="66" Height="34" MaxLength="5" Text="50"
                           HorizontalContentAlignment="Center" VerticalContentAlignment="Center" TextAlignment="Center" Padding="10,5" FontSize="12"/>
                  <TextBlock x:Name="CountUnit" Text="итераций" Margin="8,0,0,0" VerticalAlignment="Center"
                             FontSize="11" Foreground="#8B99AE"/>
                </StackPanel>
                <StackPanel x:Name="TimePanel" Orientation="Horizontal" Visibility="Collapsed">
                  <TextBox x:Name="TimeBox" Width="66" Height="34" MaxLength="5" Text="18:00"
                           HorizontalContentAlignment="Center" VerticalContentAlignment="Center" TextAlignment="Center" Padding="10,5" FontSize="12"/>
                  <TextBlock x:Name="TimeHint" Text="· сегодня" Margin="8,0,0,0" VerticalAlignment="Center"
                             FontSize="11" Foreground="#66748A"/>
                </StackPanel>
              </Grid>
              <TextBlock x:Name="LimitFootnote" Grid.Row="3" Text="работает, пока не остановите вручную"
                         Margin="0,7,0,0" FontSize="10" Foreground="#66748A" TextWrapping="Wrap"/>
            </Grid>
          </Border>
        </Grid>

        <!-- chats header -->
        <Grid Grid.Row="2" Margin="2,0,2,8">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="ЧАТЫ" Style="{StaticResource SectionLabel}" VerticalAlignment="Center"/>
            <Border Background="#101A29" BorderBrush="#1B2A3D" BorderThickness="1" CornerRadius="5"
                    Padding="6,1" Margin="8,0,0,0" VerticalAlignment="Center">
              <TextBlock x:Name="ChatCountText" Text="0" FontSize="9.5" FontWeight="SemiBold" Foreground="#7E93AD"/>
            </Border>
          </StackPanel>
          <Button x:Name="AddBtn" Style="{StaticResource GhostButton}" HorizontalAlignment="Right"
                  Content="+  Добавить"/>
        </Grid>

        <!-- chats list -->
        <ScrollViewer Grid.Row="3" MaxHeight="156" VerticalScrollBarVisibility="Auto"
                      HorizontalScrollBarVisibility="Disabled" Margin="0,0,0,10" PanningMode="VerticalOnly">
          <StackPanel x:Name="ChatPanel"/>
        </ScrollViewer>

        <!-- log header -->
        <Grid Grid.Row="4" Margin="2,2,2,8">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="ЖУРНАЛ" Style="{StaticResource SectionLabel}" VerticalAlignment="Center"/>
            <Ellipse x:Name="LogLiveDot" Width="5" Height="5" Fill="#34D399" Margin="8,0,0,0"
                     VerticalAlignment="Center" Opacity="0.6"/>
          </StackPanel>
          <Button x:Name="ClearBtn" Style="{StaticResource LinkButton}" Content="Очистить"
                  HorizontalAlignment="Right"/>
        </Grid>

        <!-- log -->
        <Border Grid.Row="5" Background="#070A10" BorderBrush="#182130" BorderThickness="1"
                CornerRadius="12" Padding="1" ClipToBounds="True">
          <RichTextBox x:Name="LogBox" IsReadOnly="True" IsUndoEnabled="False" BorderThickness="0"
                       Background="Transparent" Foreground="#93A4BD" Padding="10,8"
                       FontFamily="Cascadia Mono, Consolas" FontSize="11"
                       VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                       IsDocumentEnabled="False"/>
        </Border>

        <!-- footer -->
        <Grid Grid.Row="6" Margin="2,8,2,0">
          <TextBlock x:Name="FooterText" Text="OpenCode AutoContinue · v1.3.0" FontSize="10"
                     Foreground="#59677C" VerticalAlignment="Center"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="TrayBtn" Style="{StaticResource LinkButton}" Content="Свернуть в трей"
                    Margin="0,0,10,0" VerticalAlignment="Center"/>
            <TextBlock x:Name="ServerText" Text="" FontSize="10" Foreground="#59677C"
                       VerticalAlignment="Center"/>
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
$HeroTitle = Find-Ui 'HeroTitle'
$HeroSub = Find-Ui 'HeroSub'
$MainActionBtn = Find-Ui 'MainActionBtn'
$MainActionGlyph = Find-Ui 'MainActionGlyph'
$MainActionText = Find-Ui 'MainActionText'
$LimitSummary = Find-Ui 'LimitSummary'
$ProgressRow = Find-Ui 'ProgressRow'
$LimitProgress = Find-Ui 'LimitProgress'
$ProgressLabel = Find-Ui 'ProgressLabel'
$MessageBox = Find-Ui 'MessageBox'
$AutoAddChk = Find-Ui 'AutoAddChk'
$LimitNone = Find-Ui 'LimitNone'
$LimitCountRadio = Find-Ui 'LimitCountRadio'
$LimitTimeRadio = Find-Ui 'LimitTimeRadio'
$CountPanel = Find-Ui 'CountPanel'
$CountBox = Find-Ui 'CountBox'
$CountUnit = Find-Ui 'CountUnit'
$TimePanel = Find-Ui 'TimePanel'
$TimeBox = Find-Ui 'TimeBox'
$TimeHint = Find-Ui 'TimeHint'
$LimitFootnote = Find-Ui 'LimitFootnote'
$ChatCountText = Find-Ui 'ChatCountText'
$AddBtn = Find-Ui 'AddBtn'
$ChatPanel = Find-Ui 'ChatPanel'
$LogBox = Find-Ui 'LogBox'
$LogLiveDot = Find-Ui 'LogLiveDot'
$ClearBtn = Find-Ui 'ClearBtn'
$FooterText = Find-Ui 'FooterText'
$ServerText = Find-Ui 'ServerText'
$TrayBtn = Find-Ui 'TrayBtn'
$DragArea = Find-Ui 'DragArea'
$TitleIcon = Find-Ui 'TitleIcon'
$PinBtn = Find-Ui 'PinBtn'
$MinBtn = Find-Ui 'MinBtn'
$MaxBtn = Find-Ui 'MaxBtn'
$CloseBtn = Find-Ui 'CloseBtn'

$FooterText.Text = "OpenCode AutoContinue · v$($script:AppVersion)"

$script:BrushCache = @{}
function Brush([string]$hex) {
    if (-not $script:BrushCache.ContainsKey($hex)) {
        $script:BrushCache[$hex] = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($hex))
    }
    return $script:BrushCache[$hex]
}

function Get-Color([string]$hex) {
    return [Windows.Media.ColorConverter]::ConvertFromString($hex)
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

function Update-PinVisual {
    if ($script:Topmost) {
        $PinBtn.Foreground = Brush '#6EE7B7'
        $PinBtn.ToolTip = 'Поверх всех окон: включено'
    }
    else {
        $PinBtn.Foreground = Brush '#78879D'
        $PinBtn.ToolTip = 'Поверх всех окон: выключено'
    }
}

function Toggle-Maximize {
    if ($window.WindowState -eq 'Maximized') { $window.WindowState = 'Normal' }
    else { $window.WindowState = 'Maximized' }
}

$DragArea.Add_MouseLeftButtonDown({
        param($sender, $e)
        if ($e.ClickCount -eq 2) { Toggle-Maximize; return }
        try { $window.DragMove() } catch { }
    })

$MinBtn.Add_Click({ $window.WindowState = 'Minimized' })
$MaxBtn.Add_Click({ Toggle-Maximize })
$CloseBtn.Add_Click({ $window.Close() })
$PinBtn.Add_Click({
        $script:Topmost = -not $script:Topmost
        $window.Topmost = $script:Topmost
        $settings.topmost = $script:Topmost
        $script:Dirty = $true
        Update-PinVisual
    })

$window.Add_StateChanged({
        if ($window.WindowState -eq 'Maximized') { $MaxBtn.Content = [string][char]0xE923 }
        else { $MaxBtn.Content = [string][char]0xE922 }
    })

# ---- иконка ----

$script:IconFile = Join-Path $script:ScriptDir 'app.ico'
$script:AppIcon = $null
if (Test-Path -LiteralPath $script:IconFile) {
    try {
        $uri = [Uri]::new((Resolve-Path -LiteralPath $script:IconFile).Path, [UriKind]::Absolute)
        $script:AppIcon = [Windows.Media.Imaging.BitmapFrame]::Create($uri)
        $window.Icon = $script:AppIcon
        $TitleIcon.Source = $script:AppIcon
    }
    catch { }
}
if ($null -eq $script:AppIcon -and $exePath) {
    try {
        $sysIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($exePath)
        if ($sysIcon) {
            $src = [Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                $sysIcon.Handle,
                [Windows.Int32Rect]::Empty,
                [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
            $src.Freeze()
            $script:AppIcon = $src
            $window.Icon = $src
            $TitleIcon.Source = $src
            $sysIcon.Dispose()
        }
    }
    catch { }
}
if ($null -eq $script:AppIcon) { $TitleIcon.Visibility = 'Collapsed' }

# ---- лог ----

$script:LogCount = 0
$logParagraph = [Windows.Documents.Paragraph]::new()
$logParagraph.Margin = [Windows.Thickness]::new(0)
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
        'ok' { '#6EE7B7' }
        'warn' { '#FBBF24' }
        'err' { '#F87171' }
        default { '#93A4BD' }
    }

    $timePart = ''
    $bodyPart = $text
    if ($text.Length -ge 10) {
        $timePart = $text.Substring(0, 10)
        $bodyPart = $text.Substring(10)
    }

    $para = [Windows.Documents.Paragraph]::new()
    $para.Margin = [Windows.Thickness]::new(0)
    $para.LineHeight = 17
    $runTime = [Windows.Documents.Run]::new($timePart)
    $runTime.Foreground = Brush '#4C5B72'
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
    $CountPanel.Visibility = if ($mode -eq 'count') { 'Visible' } else { 'Collapsed' }
    $TimePanel.Visibility = if ($mode -eq 'time') { 'Visible' } else { 'Collapsed' }

    switch ($mode) {
        'count' {
            $CountUnit.Text = Plural $state.LimitCount 'итерация' 'итерации' 'итераций'
            $LimitFootnote.Text = "остановится после $($state.LimitCount) $(Plural $state.LimitCount 'итерации' 'итерации' 'итераций')"
        }
        'time' {
            $parsed = Parse-TimeText $TimeBox.Text
            if ($parsed) {
                $deadline = Get-NextDeadline $parsed.Hour $parsed.Minute
                $day = if ($deadline.Date -eq (Get-Date).Date) { 'сегодня' } else { 'завтра' }
                $LimitFootnote.Text = "остановится в $($parsed.Text) · $day"
                $TimeHint.Text = '· ' + $day
            }
            else {
                $LimitFootnote.Text = 'укажите время в формате ЧЧ:ММ'
                $TimeHint.Text = '· —'
            }
        }
        default {
            $LimitFootnote.Text = 'работает, пока не остановите вручную'
        }
    }

    $ProgressRow.Visibility = if ($mode -eq 'none') { 'Collapsed' } else { 'Visible' }
}

function Apply-LimitFromUi {
    $count = Read-LimitCount
    if ($count -gt 0) {
        $state.LimitCount = $count
        $CountBox.BorderBrush = Brush '#223047'
    }
    else {
        $CountBox.BorderBrush = Brush '#7F1D1D'
    }

    $parsed = Parse-TimeText $TimeBox.Text
    if ($parsed) {
        $state.LimitTime = $parsed.Text
        $state.DeadlineTicks = (Get-NextDeadline $parsed.Hour $parsed.Minute).Ticks
        $state.LimitSince = Get-Date
        $TimeBox.BorderBrush = Brush '#223047'
    }
    else {
        $state.DeadlineTicks = [long]0
        $TimeBox.BorderBrush = Brush '#7F1D1D'
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
            'running' {
                $StatusText.Text = 'РАБОТАЕТ'
                $StatusText.Foreground = Brush '#6EE7B7'
                $StatusDot.Fill = Brush '#34D399'
                $StatusDot.Effect.Color = Get-Color '#34D399'
                $HeroTitle.Text = 'Автопродолжение активно'
                $MainActionGlyph.Text = [string][char]0xE71A
                $MainActionText.Text = 'ОСТАНОВИТЬ'
                $MainActionBtn.Background = Brush '#F05252'
                $MainActionBtn.Foreground = Brush '#FFFFFF'
                if ($script:PulseAnimation) {
                    $StatusDot.BeginAnimation([Windows.UIElement]::OpacityProperty, $script:PulseAnimation)
                }
            }
            'paused' {
                $StatusText.Text = 'ПАУЗА'
                $StatusText.Foreground = Brush '#FBBF24'
                $StatusDot.Fill = Brush '#FBBF24'
                $StatusDot.Effect.Color = Get-Color '#FBBF24'
                $HeroTitle.Text = 'Автопродолжение на паузе'
                $MainActionGlyph.Text = [string][char]0xE768
                $MainActionText.Text = 'ЗАПУСТИТЬ'
                $MainActionBtn.Background = Brush '#34D399'
                $MainActionBtn.Foreground = Brush '#05170E'
                $StatusDot.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
                $StatusDot.Opacity = 1
            }
            'limit' {
                $StatusText.Text = 'ЛИМИТ'
                $StatusText.Foreground = Brush '#FBBF24'
                $StatusDot.Fill = Brush '#FBBF24'
                $StatusDot.Effect.Color = Get-Color '#FBBF24'
                $HeroTitle.Text = 'Лимит запуска достигнут'
                $MainActionGlyph.Text = [string][char]0xE768
                $MainActionText.Text = 'НОВЫЙ ЗАПУСК'
                $MainActionBtn.Background = Brush '#34D399'
                $MainActionBtn.Foreground = Brush '#05170E'
                $StatusDot.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
                $StatusDot.Opacity = 1
            }
            'error' {
                $StatusText.Text = 'НЕТ СВЯЗИ'
                $StatusText.Foreground = Brush '#F87171'
                $StatusDot.Fill = Brush '#F87171'
                $StatusDot.Effect.Color = Get-Color '#F87171'
                $HeroTitle.Text = 'OpenCode не отвечает'
                $MainActionGlyph.Text = [string][char]0xE72C
                $MainActionText.Text = 'ПОВТОРИТЬ'
                $MainActionBtn.Background = Brush '#3B82F6'
                $MainActionBtn.Foreground = Brush '#FFFFFF'
                $StatusDot.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
                $StatusDot.Opacity = 1
            }
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
    if ($null -eq $HeroSub) { return }
    $chats = @($state.Chats)
    $chatCount = $chats.Count
    $sent = [int]$state.SentThisRun
    $running = -not [bool]$state.Stop

    if ($running) {
        $elapsed = if ($state.RunStartedAt -ne [datetime]::MinValue) { Format-Duration ((Get-Date) - [datetime]$state.RunStartedAt) } else { '00:00:00' }
        $HeroSub.Text = "$chatCount $(Plural $chatCount 'чат' 'чата' 'чатов') · $sent $(Plural $sent 'отправка' 'отправки' 'отправок') · в работе $elapsed"
    }
    elseif ([string]$state.StopReason -eq 'error') {
        $HeroSub.Text = "$chatCount $(Plural $chatCount 'чат' 'чата' 'чатов') · переподключение в фоне · отправлено $sent"
    }
    elseif ([string]$state.StopReason -eq 'limit') {
        $HeroSub.Text = "$chatCount $(Plural $chatCount 'чат' 'чата' 'чатов') · $sent $(Plural $sent 'отправка' 'отправки' 'отправок') за запуск"
    }
    else {
        $HeroSub.Text = "$chatCount $(Plural $chatCount 'чат' 'чата' 'чатов') · $sent $(Plural $sent 'отправка' 'отправки' 'отправок')"
    }

    $ChatCountText.Text = [string]$chatCount

    $mode = [string]$state.LimitMode
    $now = Get-Date
    if ($mode -eq 'count') {
        $limit = [Math]::Max(1, [int]$state.LimitCount)
        $value = [Math]::Min($sent, $limit)
        $LimitSummary.Text = "$value / $limit итераций"
        $LimitProgress.Maximum = $limit
        $LimitProgress.Value = $value
        $LimitProgress.Foreground = if ($value -ge $limit) { Brush '#FBBF24' } else { Brush '#34D399' }
        $ProgressLabel.Text = "$value / $limit"
        $LimitSummary.Foreground = Brush '#8B99AE'
    }
    elseif ($mode -eq 'time') {
        $deadline = if ([long]$state.DeadlineTicks -gt 0) { [datetime]::new([long]$state.DeadlineTicks) } else { $null }
        $LimitProgress.Maximum = 1
        if ($null -ne $deadline) {
            $left = $deadline - $now
            if ($left.TotalSeconds -le 0) {
                $LimitSummary.Text = "до $($deadline.ToString('HH:mm')) · время вышло"
                $ProgressLabel.Text = '00:00:00'
                $LimitProgress.Value = 1
                $LimitProgress.Foreground = Brush '#FBBF24'
            }
            else {
                $LimitSummary.Text = "до $($deadline.ToString('HH:mm')) · осталось $(Format-Duration $left)"
                $ProgressLabel.Text = "осталось $(Format-Duration $left)"
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
                $LimitProgress.Foreground = Brush '#34D399'
            }
        }
        else {
            $LimitSummary.Text = 'время не задано'
            $ProgressLabel.Text = ''
            $LimitProgress.Value = 0
        }
        $LimitSummary.Foreground = Brush '#8B99AE'
    }
    else {
        $LimitSummary.Text = 'без лимита'
        $LimitSummary.Foreground = Brush '#7E8CA1'
        $LimitProgress.Maximum = 1
        $LimitProgress.Value = 0
        $ProgressLabel.Text = ''
    }

    if ($state.BaseUrl -ne $script:LastServer) {
        $script:LastServer = [string]$state.BaseUrl
        $short = $script:LastServer -replace '^https?://', ''
        $ServerText.Text = $short
        $StatusMeta.Text = "· $short"
    }

    $LogLiveDot.Fill = if ($running) { Brush '#34D399' } else { Brush '#4B5A71' }
    $LogLiveDot.Opacity = if ($running) { 0.85 } else { 0.35 }
}

# ---- строки чатов ----

$script:Rows = @()
$script:LastSig = ''

function Get-ChatPhaseColor($chat) {
    switch ([string]$chat.Phase) {
        'running' { return '#FBBF24' }
        'sent' { return '#60A5FA' }
        'blocked' { return '#F87171' }
        default {
            if ([string]$chat.Status -like 'ошибка*') { return '#F87171' }
            if ([string]$chat.Status -like 'ответ получен*') { return '#34D399' }
            return '#62718A'
        }
    }
}

function New-ChatRow($chat) {
    $row = [Windows.Controls.Border]::new()
    $row.Background = Brush '#101822'
    $row.BorderBrush = Brush '#1C2838'
    $row.BorderThickness = [Windows.Thickness]::new(1)
    $row.CornerRadius = [Windows.CornerRadius]::new(11)
    $row.Padding = [Windows.Thickness]::new(12, 7, 8, 7)
    $row.Margin = [Windows.Thickness]::new(0, 0, 0, 6)
    $row.Add_MouseEnter({ $this.Background = Brush '#131D2A'; $this.BorderBrush = Brush '#27364A' })
    $row.Add_MouseLeave({ $this.Background = Brush '#101822'; $this.BorderBrush = Brush '#1C2838' })

    $grid = [Windows.Controls.Grid]::new()
    foreach ($w in @('Auto', '*', 'Auto', 'Auto')) {
        $cd = [Windows.Controls.ColumnDefinition]::new()
        $cd.Width = if ($w -eq '*') { [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) } else { [Windows.GridLength]::Auto }
        $grid.ColumnDefinitions.Add($cd) | Out-Null
    }

    $dot = [Windows.Shapes.Ellipse]::new()
    $dot.Width = 7
    $dot.Height = 7
    $dot.Margin = [Windows.Thickness]::new(0, 0, 11, 0)
    $dot.VerticalAlignment = 'Center'
    $dot.Fill = Brush (Get-ChatPhaseColor $chat)
    $dotGlow = [Windows.Media.Effects.DropShadowEffect]::new()
    $dotGlow.BlurRadius = 9
    $dotGlow.ShadowDepth = 0
    $dotGlow.Opacity = 0.55
    $dotGlow.Color = Get-Color (Get-ChatPhaseColor $chat)
    $dot.Effect = $dotGlow
    $grid.Children.Add($dot) | Out-Null

    $stack = [Windows.Controls.StackPanel]::new()
    $stack.VerticalAlignment = 'Center'
    $title = [Windows.Controls.TextBlock]::new()
    $title.Text = if ($chat.Title) { [string]$chat.Title } else { '(без названия)' }
    $title.FontSize = 12.5
    $title.FontWeight = [Windows.FontWeights]::SemiBold
    $title.Foreground = Brush '#E8EEF7'
    $title.TextTrimming = 'CharacterEllipsis'
    $status = [Windows.Controls.TextBlock]::new()
    $status.Text = [string]$chat.Status
    $status.FontSize = 10
    $status.Margin = [Windows.Thickness]::new(0, 1, 0, 0)
    $status.Foreground = Brush '#7C8AA0'
    $status.TextTrimming = 'CharacterEllipsis'
    [void]$stack.Children.Add($title)
    [void]$stack.Children.Add($status)
    [Windows.Controls.Grid]::SetColumn($stack, 1)
    $grid.Children.Add($stack) | Out-Null

    $countBadge = [Windows.Controls.Border]::new()
    $countBadge.Background = Brush '#0E1929'
    $countBadge.BorderBrush = Brush '#1A2A3E'
    $countBadge.BorderThickness = [Windows.Thickness]::new(1)
    $countBadge.CornerRadius = [Windows.CornerRadius]::new(6)
    $countBadge.Padding = [Windows.Thickness]::new(7, 2, 7, 2)
    $countBadge.Margin = [Windows.Thickness]::new(0, 0, 10, 0)
    $countBadge.VerticalAlignment = 'Center'
    $countTb = [Windows.Controls.TextBlock]::new()
    $countTb.Text = [string]$chat.Count
    $countTb.FontSize = 10.5
    $countTb.FontWeight = [Windows.FontWeights]::SemiBold
    $countTb.Foreground = Brush '#7DD3FC'
    $countBadge.Child = $countTb
    $countBadge.ToolTip = 'Отправлено сообщений'
    [Windows.Controls.Grid]::SetColumn($countBadge, 2)
    $grid.Children.Add($countBadge) | Out-Null

    $remove = [Windows.Controls.Border]::new()
    $remove.Width = 24
    $remove.Height = 24
    $remove.CornerRadius = [Windows.CornerRadius]::new(6)
    $remove.Background = [Windows.Media.Brushes]::Transparent
    $remove.Cursor = [Windows.Input.Cursors]::Hand
    $remove.VerticalAlignment = 'Center'
    $remove.ToolTip = 'Убрать чат из списка (и не добавлять автоматически)'
    $remove.Tag = [string]$chat.Id
    $x = [Windows.Controls.TextBlock]::new()
    $x.Text = [string][char]0x2715
    $x.FontSize = 9.5
    $x.Foreground = Brush '#62718A'
    $x.HorizontalAlignment = 'Center'
    $x.VerticalAlignment = 'Center'
    $remove.Child = $x
    $remove.Add_MouseEnter({ $this.Background = Brush '#2A1720'; $this.Child.Foreground = Brush '#F87171' })
    $remove.Add_MouseLeave({ $this.Background = [Windows.Media.Brushes]::Transparent; $this.Child.Foreground = Brush '#62718A' })
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
        $empty.Background = Brush '#0C121B'
        $empty.BorderBrush = Brush '#1A2637'
        $empty.BorderThickness = [Windows.Thickness]::new(1)
        $empty.CornerRadius = [Windows.CornerRadius]::new(11)
        $empty.Padding = [Windows.Thickness]::new(14, 12, 14, 12)
        $inner = [Windows.Controls.StackPanel]::new()
        $inner.Orientation = 'Horizontal'
        $icon = [Windows.Controls.TextBlock]::new()
        $icon.Text = [string][char]0xE8BD
        $icon.FontFamily = [Windows.Media.FontFamily]::new('Segoe Fluent Icons, Segoe MDL2 Assets')
        $icon.FontSize = 16
        $icon.Foreground = Brush '#3B4B63'
        $icon.VerticalAlignment = 'Center'
        $icon.Margin = [Windows.Thickness]::new(0, 0, 10, 0)
        $txt = [Windows.Controls.StackPanel]::new()
        $t1 = [Windows.Controls.TextBlock]::new()
        $t1.Text = 'Пока нет чатов'
        $t1.FontSize = 12
        $t1.FontWeight = [Windows.FontWeights]::SemiBold
        $t1.Foreground = Brush '#B7C4D6'
        $t2 = [Windows.Controls.TextBlock]::new()
        $t2.Text = 'Включите авто-добавление или нажмите «+ Добавить».'
        $t2.FontSize = 10.5
        $t2.Margin = [Windows.Thickness]::new(0, 2, 0, 0)
        $t2.Foreground = Brush '#66748A'
        [void]$txt.Children.Add($t1)
        [void]$txt.Children.Add($t2)
        [void]$inner.Children.Add($icon)
        [void]$inner.Children.Add($txt)
        $empty.Child = $inner
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
        if ($refs.Title.Text -ne $titleText) { $refs.Title.Text = $titleText }
        $statusText = [string]$chat.Status
        if ($refs.Status.Text -ne $statusText) { $refs.Status.Text = $statusText }
        $countText = [string]$chat.Count
        if ($refs.Count.Text -ne $countText) { $refs.Count.Text = $countText }

        $color = Get-ChatPhaseColor $chat
        if ($refs.Phase -ne $color) {
            $refs.Phase = $color
            $refs.Dot.Fill = Brush $color
            $refs.Dot.Effect.Color = Get-Color $color
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
        Title="Добавить чат" Width="560" Height="520"
        WindowStyle="None" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" Background="#0A0E15" Foreground="#ECF1F8"
        FontFamily="Segoe UI Variable Text, Segoe UI" UseLayoutRounding="True">
  <Window.Resources>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#0A1019"/>
      <Setter Property="Foreground" Value="#ECF1F8"/>
      <Setter Property="CaretBrush" Value="#6EE7B7"/>
      <Setter Property="BorderBrush" Value="#223047"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="9">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            VerticalScrollBarVisibility="{TemplateBinding VerticalScrollBarVisibility}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#3F6E5C"/>
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
            <Border x:Name="Bd" Background="Transparent" CornerRadius="8" Padding="10,7" Margin="0,0,0,3">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#131D2A"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#12291F"/>
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
                        <Border Background="#2A374B" CornerRadius="3" Margin="1,2"/>
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
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="14,0"/>
      <Setter Property="Background" Value="#111927"/>
      <Setter Property="Foreground" Value="#A9B6C8"/>
      <Setter Property="BorderBrush" Value="#223047"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#172234"/>
                <Setter Property="Foreground" Value="#E8EEF7"/>
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
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Background" Value="#34D399"/>
      <Setter Property="Foreground" Value="#05170E"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8"/>
              <Border x:Name="Hover" Background="#18FFFFFF" CornerRadius="8" Opacity="0"/>
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
      <Setter Property="Foreground" Value="#78879D"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="7">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#B91C1C"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border Background="#0A0E15" BorderBrush="#1C2838" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="46"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="60"/>
      </Grid.RowDefinitions>
      <Border Grid.Row="0" BorderBrush="#141D2A" BorderThickness="0,0,0,1">
        <Grid>
          <TextBlock x:Name="DlgTitle" Text="Добавить чат" FontSize="12.5" FontWeight="SemiBold" Foreground="#E8EEF7"
                     VerticalAlignment="Center" Margin="16,0,0,0"/>
          <Button x:Name="DlgCloseBtn" Style="{StaticResource DlgClose}" HorizontalAlignment="Right" Margin="0,0,8,0"
                  Content="&#xE8BB;"/>
        </Grid>
      </Border>
      <Grid Grid.Row="1" Margin="18,12,18,8">
        <TextBox x:Name="SearchBox" Height="34" Padding="10,5" VerticalContentAlignment="Center"/>
        <TextBlock x:Name="SearchHint" Text="Поиск по названию…" FontSize="11.5" Foreground="#5C6B80"
                   Margin="11,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
      </Grid>
      <ListBox x:Name="SessionList" Grid.Row="2" Margin="18,0,18,0"/>
      <Grid Grid.Row="3" Margin="18,10,18,14">
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="DlgCancelBtn" Width="96" Content="Отмена" Style="{StaticResource DlgGhost}"/>
          <Button x:Name="DlgAddBtn" Width="120" Content="Добавить" Margin="8,0,0,0" Style="{StaticResource DlgPrimary}"/>
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
            $tt.Foreground = Brush '#E8EEF7'
            $tt.TextTrimming = 'CharacterEllipsis'
            $mm = [Windows.Controls.TextBlock]::new()
            $meta = if ($when) { "$when  ·  " } else { '' }
            $mm.Text = $meta + [string]$s.id
            $mm.FontSize = 9.5
            $mm.Margin = [Windows.Thickness]::new(0, 1, 0, 0)
            $mm.Foreground = Brush '#66748A'
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
$AutoAddChk.IsChecked = [bool]$state.AutoAdd
$CountBox.Text = [string]$state.LimitCount
$TimeBox.Text = [string]$state.LimitTime

# ---- обработчики ----

$MessageBox.Add_TextChanged({
        $state.Message = $MessageBox.Text
        $script:Dirty = $true
    })

$AutoAddChk.Add_Click({
        $state.AutoAdd = [bool]$AutoAddChk.IsChecked
        Write-UiLog 'info' ('Автодобавление чатов: ' + $(if ($state.AutoAdd) { 'вкл' } else { 'выкл' }))
        $script:Dirty = $true
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
            $w = if ($window.WindowState -eq 'Maximized') { $window.RestoreBounds.Width } else { $window.ActualWidth }
            $h = if ($window.WindowState -eq 'Maximized') { $window.RestoreBounds.Height } else { $window.ActualHeight }
            if ($w -ge 720 -and $h -ge 680) {
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
    if (-not $trayIcon.Icon) {
        try { $trayIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exePath) } catch { }
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
            if ($lines.Count -gt 0) { $LogBox.ScrollToEnd() }

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

Update-PinVisual
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
