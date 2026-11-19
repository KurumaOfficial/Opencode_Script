#requires -version 5.1
<#
    OpenCode AutoContinue
    ---------------------
    Следит за чатами OpenCode и после каждого завершённого ответа бота
    автоматически отправляет ему заданный текст ("Продолжай разработку").

    - Работа разбита на вкладки: у каждой свой текст, свои чаты, свой лимит и своё состояние.
    - Список чатов живёт по sessionId, поэтому переименование чата ничего не ломает.
    - Новые активные чаты можно подхватывать автоматически (в настройках вкладки, по умолчанию выкл).
    - Вкладки, тексты и чаты настраиваются прямо в окне и сохраняются
      в settings.json (у .exe — в %APPDATA%\OpenCodeAutoContinue).
    - Лимит запуска у каждой вкладки: по количеству итераций или до заданного времени.
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
$script:AppVersion = '1.5.0'

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

$script:MaxTabs = 10

function New-TabId { return 'tab_' + ([guid]::NewGuid().ToString('N').Substring(0, 8)) }

function New-ChatObject([string]$id, [string]$title) {
    return [hashtable]::Synchronized(@{
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
}

# Вкладка — самостоятельная задача: свой текст, свои чаты, свой лимит и своё состояние.
function New-TabObject($cfg, [bool]$forcePause = $false) {
    $chats = @()
    foreach ($c in @($cfg.chats)) {
        if ($null -ne $c) { $chats += , (New-ChatObject ([string]$c.Id) ([string]$c.Title)) }
    }
    $paused = [bool]$cfg.paused
    $stopped = $paused -or $forcePause
    return [hashtable]::Synchronized(@{
            Id          = [string]$cfg.id
            Name        = [string]$cfg.name
            Message     = [string]$cfg.message
            AutoAdd     = [bool]$cfg.autoAdd
            Chats       = $chats
            Stop        = $stopped
            StopReason  = $(if ($stopped) { 'user' } else { '' })
            UserPaused  = $paused
            LimitMode   = [string]$cfg.limitMode
            LimitCount  = [int]$cfg.limitCount
            LimitTime   = [string]$cfg.limitTime
            DeadlineTicks = [long]0
            LimitSince  = [datetime]::MinValue
            LimitHit    = ''
            SentThisRun = 0
            RunStartedAt = $(if ($stopped) { [datetime]::MinValue } else { Get-Date })
            Deleted     = $false
            UiKey       = ''
        })
}

# После паузы чат в фазе «отправлено» возвращается в ожидание: если бот свободен,
# сообщение уйдёт сразу, а не после 45-секундного таймаута «ответ не начался».
function Reset-TabChatsForResume($tab) {
    foreach ($c in @($tab.Chats)) {
        if ([string]$c.Phase -eq 'sent') {
            $c.Phase = 'waiting'
            $c.Status = 'ожидание ответа'
            $c.NoAnswer = 0
        }
    }
}

function Read-TabConfig($src, [bool]$trustAutoAdd) {
    $t = @{
        id = ''; name = ''; message = $null; autoAdd = $false; paused = $false
        chats = @(); limitMode = 'none'; limitCount = 50; limitTime = '18:00'
    }
    if ($null -ne $src.id) { $t.id = [string]$src.id }
    if ($null -ne $src.name) { $t.name = ([string]$src.name).Trim() }
    if ($null -ne $src.message) { $t.message = [string]$src.message }
    if ($trustAutoAdd -and $null -ne $src.autoAdd) { $t.autoAdd = [bool]$src.autoAdd }
    if ($null -ne $src.paused) { $t.paused = [bool]$src.paused }
    if ($src.chats) {
        $t.chats = @($src.chats | ForEach-Object { @{ Id = [string]$_.id; Title = [string]$_.title } })
    }
    if ([string]$src.limitMode -in @('none', 'count', 'time')) { $t.limitMode = [string]$src.limitMode }
    if ($null -ne $src.limitCount) {
        $n = 0
        if ([int]::TryParse([string]$src.limitCount, [ref]$n) -and $n -ge 1 -and $n -le 99999) { $t.limitCount = $n }
    }
    if ([string]$src.limitTime -match '^(\d{1,2}):(\d{2})$') {
        $h = [int]$Matches[1]
        $m = [int]$Matches[2]
        if ($h -ge 0 -and $h -le 23 -and $m -ge 0 -and $m -le 59) { $t.limitTime = ('{0:00}:{1:00}' -f $h, $m) }
    }
    return $t
}

$settings = @{
    ignored   = @()
    topmost   = $true
    winWidth  = 400
    winHeight = 540
    activeTab = ''
    tabs      = @()
}

if (Test-Path -LiteralPath $script:SettingsPath) {
    try {
        $rawText = [IO.File]::ReadAllText($script:SettingsPath, [Text.Encoding]::UTF8)
        $raw = $rawText | ConvertFrom-Json
        $schema = 0
        if ($null -ne $raw.schema) { [void][int]::TryParse([string]$raw.schema, [ref]$schema) }

        if ($raw.ignored) { $settings.ignored = @($raw.ignored | ForEach-Object { [string]$_ }) }
        if ($null -ne $raw.topmost) { $settings.topmost = [bool]$raw.topmost }
        # размеры окна интерфейса 1.3 (860x880) не переносим
        if ($schema -ge 2 -and $null -ne $raw.winWidth) { $settings.winWidth = [int]$raw.winWidth }
        if ($schema -ge 2 -and $null -ne $raw.winHeight) { $settings.winHeight = [int]$raw.winHeight }

        if ($schema -ge 3 -and $raw.tabs) {
            foreach ($t in @($raw.tabs)) { $settings.tabs += , (Read-TabConfig $t $true) }
            if ($null -ne $raw.activeTab) { $settings.activeTab = [string]$raw.activeTab }
        }
        else {
            # схемы 0-2 хранили одну задачу в корне файла — она становится первой вкладкой
            # (до схемы 2 автодобавление включалось по умолчанию, а не выбором пользователя)
            $legacy = Read-TabConfig $raw ($schema -ge 2)
            $legacy.name = 'Задача 1'
            $settings.tabs = @($legacy)
        }
    }
    catch { }
}
elseif ($ChatTitles.Count -gt 0) {
    $first = Read-TabConfig @{} $false
    $first.chats = @($ChatTitles | ForEach-Object { @{ Id = ''; Title = [string]$_ } })
    $settings.tabs = @($first)
}

# приводим вкладки в порядок: хотя бы одна, уникальные id, имена, предел количества
if (@($settings.tabs).Count -eq 0) { $settings.tabs = @(Read-TabConfig @{} $false) }
$settings.tabs = @($settings.tabs | Select-Object -First $script:MaxTabs)
$usedIds = @{}
$tabNo = 0
foreach ($t in $settings.tabs) {
    $tabNo++
    if (-not $t.id -or $usedIds.ContainsKey([string]$t.id)) { $t.id = New-TabId }
    $usedIds[[string]$t.id] = $true
    if (-not $t.name) { $t.name = 'Задача ' + $tabNo }
    if ($null -eq $t.message) { $t.message = $MessageText }
}
if (-not $usedIds.ContainsKey([string]$settings.activeTab)) { $settings.activeTab = [string]$settings.tabs[0].id }

$script:Dirty = $false
$script:ActiveTab = $null

function Save-Settings {
    try {
        if ($null -eq $script:ActiveTab) { return }
        $tabsOut = @()
        foreach ($t in @($state.Tabs)) {
            $chatsOut = @()
            foreach ($c in @($t.Chats)) { $chatsOut += , @{ id = [string]$c.Id; title = [string]$c.Title } }
            $tabsOut += , @{
                id         = [string]$t.Id
                name       = [string]$t.Name
                message    = [string]$t.Message
                autoAdd    = [bool]$t.AutoAdd
                paused     = [bool]$t.UserPaused
                limitMode  = [string]$t.LimitMode
                limitCount = [int]$t.LimitCount
                limitTime  = [string]$t.LimitTime
                chats      = $chatsOut
            }
        }
        $payload = @{
            schema    = 3
            activeTab = [string]$script:ActiveTab.Id
            tabs      = $tabsOut
            ignored   = @($state.Ignored.Keys)
            topmost   = [bool]$settings.topmost
            winWidth  = [int]$settings.winWidth
            winHeight = [int]$settings.winHeight
        }
        $json = $payload | ConvertTo-Json -Depth 8
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
$state.PollMs = [Math]::Max(500, $PollMs)
$state.SentTotal = 0
$state.ErrorTotal = 0
$state.ErrorStreak = 0
$state.StartedAt = Get-Date
$state.ApiError = ''
$state.Shutdown = $false
$state.Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$state.AddQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[hashtable]'
$state.RemoveQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$state.Ignored = [hashtable]::Synchronized(@{})
foreach ($ig in $settings.ignored) { if ($ig) { $state.Ignored[$ig] = $true } }

$builtTabs = @()
foreach ($cfg in $settings.tabs) { $builtTabs += , (New-TabObject $cfg ([bool]$StartStopped)) }
$state.Tabs = $builtTabs

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
    $req.UserAgent = 'OpenCode-AutoContinue/1.5'
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

# с одной вкладкой журнал выглядит как раньше, с несколькими — с именем вкладки
function Chat-Label($tab, $chat) {
    if (@($state.Tabs).Count -gt 1) { return '[' + [string]$tab.Name + ' · ' + (Chat-Name $chat) + ']' }
    return '[' + (Chat-Name $chat) + ']'
}

function Tab-Label($tab) {
    if (@($state.Tabs).Count -gt 1) { return '«' + [string]$tab.Name + '»: ' }
    return ''
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

# ---- вкладки и чаты ----
# Чат принадлежит ровно одной вкладке. Список чатов вкладки меняет только воркер,
# интерфейс отправляет команды через очереди.

function Find-Chat([string]$id) {
    foreach ($t in @($state.Tabs)) {
        foreach ($c in @($t.Chats)) {
            if ([string]$c.Id -eq $id) { return @{ Tab = $t; Chat = $c } }
        }
    }
    return $null
}

function Find-Tab([string]$id) {
    foreach ($t in @($state.Tabs)) { if ([string]$t.Id -eq $id) { return $t } }
    return $null
}

function Add-Chat($tab, [string]$id, [string]$title, [string]$reason) {
    if (-not $id) { return }
    $existing = Find-Chat $id
    if ($null -ne $existing) {
        if ($reason -eq 'добавлен вручную' -and [string]$existing.Tab.Id -ne [string]$tab.Id) {
            Log 'warn' ('Чат «' + $(if ($title) { $title } else { $id }) + '» уже в вкладке «' + [string]$existing.Tab.Name + '» — пропускаю')
        }
        return
    }
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
    $tab.Chats = @($tab.Chats) + , $chat
    $name = if ($title) { $title } else { $id }
    Log 'info' ((Tab-Label $tab) + '+ добавлен чат «' + $name + '»' + $(if ($reason) { ' — ' + $reason } else { '' }))
}

function Remove-Chat([string]$id, [string]$why) {
    foreach ($t in @($state.Tabs)) {
        $hit = @($t.Chats | Where-Object { [string]$_.Id -eq $id })
        if ($hit.Count -eq 0) { continue }
        $name = Chat-Name $hit[0]
        $t.Chats = @($t.Chats | Where-Object { [string]$_.Id -ne $id })
        Log 'info' ((Tab-Label $t) + '− убран чат «' + $name + '»' + $(if ($why) { ' — ' + $why } else { '' }))
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

# потеря связи или отказ в доступе касаются сервиса целиком, поэтому паузятся все работающие вкладки
function Pause-Running-Tabs([string]$reason) {
    foreach ($t in @($state.Tabs)) {
        if (-not $t.Stop) {
            $t.Stop = $true
            $t.StopReason = $reason
            $t.LimitHit = ''
        }
    }
}

function Resume-Tab($tab) {
    foreach ($c in @($tab.Chats)) {
        if ([string]$c.Phase -eq 'sent') {
            $c.Phase = 'waiting'
            $c.Status = 'ожидание ответа'
            $c.NoAnswer = 0
        }
    }
    $tab.Stop = $false
    $tab.StopReason = ''
}

function Send-Chat($tab, $chat) {
    $text = [string]$tab.Message
    if ([string]::IsNullOrWhiteSpace($text)) {
        $chat.Phase = 'waiting'
        $chat.Status = 'пустой текст сообщения'
        return
    }
    if ($chat.NextTryAt -and (Get-Date) -lt [datetime]$chat.NextTryAt) { return }

    try {
        $null = API 'POST' ("/api/session/" + $chat.Id + "/prompt") @{ text = $text; delivery = 'queue' }
        $chat.Count = [int]$chat.Count + 1
        $tab.SentThisRun = [int]$tab.SentThisRun + 1
        $state.SentTotal = [int]$state.SentTotal + 1
        $chat.SentAt = Get-Date
        $chat.Phase = 'sent'
        $chat.Status = "отправлено #$($chat.Count)"
        $chat.FailStreak = 0
        $chat.LastError = ''
        $chat.NextTryAt = [datetime]::MinValue
        $preview = ($text -replace '\s+', ' ').Trim()
        if ($preview.Length -gt 90) { $preview = $preview.Substring(0, 90) + '…' }
        Log 'info' ((Chat-Label $tab $chat) + ' → ' + $preview + '  (#' + $chat.Count + ')')
    }
    catch {
        $msg = [string]$_.Exception.Message
        $state.ErrorTotal = [int]$state.ErrorTotal + 1
        if ($msg -match '^HTTP 404') {
            Log 'warn' ((Chat-Label $tab $chat) + ' сессия не найдена — убираю из списка')
            Remove-Chat $chat.Id 'сессия удалена'
            return
        }
        if ($msg -match '^HTTP 40[13]') {
            Pause-Running-Tabs 'error'
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
            Log 'err' ((Chat-Label $tab $chat) + ' ' + $chat.FailStreak + ' ошибок подряд — чат поставлен на паузу: ' + $msg)
        }
        else {
            $chat.Phase = 'waiting'
            $chat.Status = 'ошибка отправки — повтор'
            $chat.NextTryAt = (Get-Date).AddSeconds($wait)
            Log 'err' ((Chat-Label $tab $chat) + ' ошибка отправки (' + $chat.FailStreak + '/5): ' + $msg + ' — повтор через ' + $wait + ' с')
        }
    }
}

function Limit-Reason($tab) {
    if ($tab.LimitMode -eq 'count') {
        $limit = [int]$tab.LimitCount
        if ($limit -gt 0 -and [int]$tab.SentThisRun -ge $limit) { return 'count' }
    }
    elseif ($tab.LimitMode -eq 'time') {
        $ticks = [long]$tab.DeadlineTicks
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
        if ($state.Shutdown) { break }

        # команды из интерфейса
        $item = $null
        while ($state.RemoveQueue.TryDequeue([ref]$item)) { Remove-Chat ([string]$item) '' }
        while ($state.AddQueue.TryDequeue([ref]$item)) {
            $target = Find-Tab ([string]$item.TabId)
            if ($null -eq $target) { continue }
            $state.Ignored.Remove([string]$item.Id)
            Add-Chat $target ([string]$item.Id) ([string]$item.Title) 'добавлен вручную'
        }

        $tabs = @($state.Tabs | Where-Object { -not $_.Deleted })
        $live = @($tabs | Where-Object { -not $_.Stop })

        if ($live.Count -eq 0) {
            # все вкладки на паузе. Если причина — потеря связи, тихо проверяем, не вернулся ли OpenCode
            $errTabs = @($tabs | Where-Object { [string]$_.StopReason -eq 'error' })
            if ($errTabs.Count -gt 0 -and (Get-Date) -ge $nextHealth) {
                if (Reload-Service) { Log 'info' 'Подхвачены новые параметры сервера OpenCode' }
                try {
                    $null = API 'GET' '/api/session/active' $null 6000
                    $healthOk++
                    if ($healthOk -ge 2) {
                        foreach ($t in $errTabs) { Resume-Tab $t }
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

        # лимиты запуска — у каждой вкладки свои
        foreach ($t in $live) {
            $whyLimit = Limit-Reason $t
            if (-not $whyLimit) { continue }
            $t.Stop = $true
            $t.StopReason = 'limit'
            $t.LimitHit = $whyLimit
            if ($whyLimit -eq 'count') {
                Log 'ok' ((Tab-Label $t) + 'лимит итераций достигнут: ' + $t.SentThisRun + ' из ' + $t.LimitCount + ' — пауза')
            }
            else {
                $deadline = [datetime]::new([long]$t.DeadlineTicks)
                Log 'ok' ((Tab-Label $t) + 'лимит времени достигнут (' + $deadline.ToString('HH:mm') + ') — пауза')
            }
        }
        $live = @($live | Where-Object { -not $_.Stop })
        if ($live.Count -eq 0) { continue }

        # восстановление чатов, заданных названием
        if (((Get-Date) - $lastResolve).TotalSeconds -gt 10) {
            foreach ($t in $tabs) {
                foreach ($c in @($t.Chats)) {
                    if (-not $c.Id) { [void](Resolve-Chat $c) }
                }
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
            # связь есть: вкладки, которые остановила ошибка, продолжают работу
            foreach ($t in $tabs) {
                if ($t.Stop -and [string]$t.StopReason -eq 'error') { Resume-Tab $t }
            }
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

            if ($apiFail -ge 5) {
                Pause-Running-Tabs 'error'
                $healthOk = 0
                $nextHealth = (Get-Date).AddSeconds(8)
                Log 'err' 'Слишком много ошибок подряд — автопродолжение приостановлено, проверяю связь в фоне'
                continue
            }

            $delay = [int][Math]::Min(30, [Math]::Pow(2, $apiFail))
            Start-Sleep -Seconds $delay
            continue
        }

        # авто-подхват активных чатов — только во вкладку с включённым автодобавлением
        $addTab = $null
        foreach ($t in $live) { if ($t.AutoAdd) { $addTab = $t; break } }
        if ($null -ne $addTab) {
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

                Add-Chat $addTab $id ([string]$info.title) 'активный чат'
            }
            if ($infoCache.Count -gt 400) { $infoCache = @{}; $infoRetry = @{} }
        }

        foreach ($tab in $live) {
            foreach ($chat in @($tab.Chats)) {
                if ($tab.Stop -or $tab.Deleted) { break }
                if (Limit-Reason $tab) { break }
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
                        Send-Chat $tab $chat
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
                                Log 'err' ((Chat-Label $tab $chat) + ' ответ не начался 3 раза — чат на паузе')
                            }
                            else {
                                $chat.Phase = 'waiting'
                                $chat.Status = 'ответ не начался — повтор'
                                $chat.NextTryAt = (Get-Date).AddSeconds(10)
                                Log 'warn' ((Chat-Label $tab $chat) + ' ответ не начался за 45 с — повторная отправка')
                            }
                        }
                    }
                }
                elseif ($phase -eq 'running') {
                    if (-not $busy) {
                        $chat.Phase = 'waiting'
                        $chat.Status = 'ответ получен, ждём отправки'
                        Log 'info' ((Chat-Label $tab $chat) + ' ответ завершён')
                    }
                }
                elseif ($phase -eq 'blocked') {
                    if ($busy) {
                        $chat.Phase = 'running'
                        $chat.Status = 'печатает…'
                        $chat.FailStreak = 0
                        $chat.NoAnswer = 0
                        Log 'ok' ((Chat-Label $tab $chat) + ' бот снова работает')
                    }
                }
                else {
                    $chat.Phase = 'waiting'
                    $chat.Status = 'ожидание ответа'
                }
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
        Width="400" Height="540" MinWidth="360" MinHeight="480"
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
      <Style.Triggers>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Opacity" Value="0.35"/>
        </Trigger>
      </Style.Triggers>
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
      <Style.Triggers>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Opacity" Value="0.35"/>
        </Trigger>
      </Style.Triggers>
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
        <RowDefinition Height="32"/>
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

      <!-- ===== tabs ===== -->
      <Border Grid.Row="1" BorderBrush="#282828" BorderThickness="0,0,0,1" IsHitTestVisible="False"/>
      <Grid x:Name="TabRow" Grid.Row="1" Margin="10,0,8,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <ScrollViewer x:Name="TabScroll" Height="30" VerticalAlignment="Bottom" Focusable="False"
                      HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Disabled">
          <StackPanel x:Name="TabPanel" Orientation="Horizontal"/>
        </ScrollViewer>
        <Button x:Name="NewTabBtn" Grid.Column="1" Style="{StaticResource IconButton}" Width="28" Height="26"
                HorizontalAlignment="Left" VerticalAlignment="Center" Margin="4,0,0,0"
                Content="&#xE710;" ToolTip="Новая вкладка (Ctrl+T)"/>
      </Grid>

      <!-- ===== main view ===== -->
      <Grid x:Name="MainView" Grid.Row="2" Margin="14,8,14,14">
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
      <Grid x:Name="SettingsView" Grid.Row="2" Margin="14,8,14,12" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
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

        <Border Grid.Row="1" Background="#141414" BorderBrush="#282828" BorderThickness="1" CornerRadius="8" Padding="14,10,14,4">
          <StackPanel>
            <Grid>
              <TextBlock Text="ЭТА ВКЛАДКА" Style="{StaticResource SectionLabel}" VerticalAlignment="Center"/>
              <Button x:Name="CloseTabBtn" Style="{StaticResource LinkButton}" Content="Закрыть вкладку"
                      Foreground="#E06C75" HorizontalAlignment="Right" ToolTip="Закрыть вкладку (Ctrl+W)"/>
            </Grid>
            <Grid Margin="0,10,0,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Text="Название" Foreground="#808080" FontSize="11" VerticalAlignment="Center" Margin="0,0,14,0"/>
              <TextBox x:Name="TabNameBox" Grid.Column="1" Height="28" MaxLength="24" Padding="8,3" FontSize="11.5"
                       VerticalContentAlignment="Center"/>
            </Grid>
            <Border Height="1" Background="#282828" Margin="0,10,0,0"/>
            <CheckBox x:Name="AutoAddChk" Style="{StaticResource Switch}" Margin="0,9">
              <StackPanel>
                <TextBlock Text="Автодобавление чатов" Foreground="#EEEEEE" FontSize="12"/>
                <TextBlock Text="новые активные чаты, только в одной вкладке" Foreground="#606060" FontSize="10"
                           Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
            </CheckBox>
          </StackPanel>
        </Border>

        <Border Grid.Row="2" Background="#141414" BorderBrush="#282828" BorderThickness="1" CornerRadius="8"
                Padding="14,4" Margin="0,10,0,0">
          <CheckBox x:Name="TopmostChk" Style="{StaticResource Switch}" Margin="0,9">
            <StackPanel>
              <TextBlock Text="Поверх всех окон" Foreground="#EEEEEE" FontSize="12"/>
              <TextBlock Text="окно не прячется за другими" Foreground="#606060" FontSize="10" Margin="0,2,0,0"/>
            </StackPanel>
          </CheckBox>
        </Border>

        <Grid Grid.Row="3" Margin="1,14,0,6">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Text="ЖУРНАЛ" Style="{StaticResource SectionLabel}" VerticalAlignment="Center"/>
            <Ellipse x:Name="LogLiveDot" Width="5" Height="5" Fill="#7FD88F" Margin="8,0,0,0"
                     VerticalAlignment="Center" Opacity="0.7"/>
          </StackPanel>
          <Button x:Name="ClearBtn" Style="{StaticResource LinkButton}" Content="Очистить" HorizontalAlignment="Right"/>
        </Grid>

        <Border Grid.Row="4" Background="#0F0F0F" BorderBrush="#282828" BorderThickness="1"
                CornerRadius="8" Padding="1" ClipToBounds="True">
          <RichTextBox x:Name="LogBox" IsReadOnly="True" IsUndoEnabled="False" BorderThickness="0"
                       Background="Transparent" Foreground="#A0A0A0" Padding="10,8"
                       FontFamily="Cascadia Mono, Consolas" FontSize="10.5"
                       VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                       IsDocumentEnabled="False"/>
        </Border>

        <Grid Grid.Row="5" Margin="1,8,0,0">
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
$TabRow = Find-Ui 'TabRow'
$TabScroll = Find-Ui 'TabScroll'
$TabPanel = Find-Ui 'TabPanel'
$NewTabBtn = Find-Ui 'NewTabBtn'
$TabNameBox = Find-Ui 'TabNameBox'
$CloseTabBtn = Find-Ui 'CloseTabBtn'

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

# ---- лимиты (у каждой вкладки свои) ----

function Set-TabDeadline($tab) {
    $parsed = Parse-TimeText ([string]$tab.LimitTime)
    if ($parsed) {
        $tab.DeadlineTicks = (Get-NextDeadline $parsed.Hour $parsed.Minute).Ticks
        $tab.LimitSince = Get-Date
    }
    else {
        $tab.DeadlineTicks = [long]0
    }
}

function Update-LimitInputs {
    $tab = $script:ActiveTab
    if ($null -eq $tab) { return }
    $mode = [string]$tab.LimitMode
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

function Apply-CountFromUi {
    if ($script:LoadingTab) { return }
    $tab = $script:ActiveTab
    if ($null -eq $tab) { return }
    $n = Read-LimitCount
    if ($n -gt 0) {
        $tab.LimitCount = $n
        $CountBox.BorderBrush = Brush '#282828'
        $script:Dirty = $true
    }
    else {
        $CountBox.BorderBrush = Brush '#E06C75'
    }
    Update-LimitInputs
}

function Apply-TimeFromUi {
    if ($script:LoadingTab) { return }
    $tab = $script:ActiveTab
    if ($null -eq $tab) { return }
    $parsed = Parse-TimeText $TimeBox.Text
    if ($parsed) {
        $tab.LimitTime = $parsed.Text
        Set-TabDeadline $tab
        $TimeBox.BorderBrush = Brush '#282828'
        $script:Dirty = $true
    }
    else {
        $tab.DeadlineTicks = [long]0
        $TimeBox.BorderBrush = Brush '#E06C75'
    }
    Update-LimitInputs
}

function Set-LimitModeUi([string]$mode) {
    if ($script:LoadingTab) { return }
    $tab = $script:ActiveTab
    if ($null -eq $tab) { return }
    if ($mode -notin @('none', 'count', 'time')) { $mode = 'none' }
    $tab.LimitMode = $mode
    if ($mode -eq 'time') { Set-TabDeadline $tab }
    elseif ($mode -eq 'count') {
        $n = Read-LimitCount
        if ($n -gt 0) { $tab.LimitCount = $n }
    }
    Update-LimitInputs
    Update-Stats
    $script:Dirty = $true
}

# ---- статус и статистика (показывают активную вкладку) ----

$script:UiStatus = ''
$script:LastServer = ''

function Get-TabStatusKey($tab) {
    if (-not [bool]$tab.Stop) { return 'running' }
    switch ([string]$tab.StopReason) {
        'error' { return 'error' }
        'limit' { return 'limit' }
        default { return 'paused' }
    }
}

function Get-TabDotColor([string]$key) {
    switch ($key) {
        'running' { return '#7FD88F' }
        'limit' { return '#F5A742' }
        'error' { return '#E06C75' }
        default { return '#606060' }
    }
}

function Get-TabStatusWord([string]$key) {
    switch ($key) {
        'running' { return 'работает' }
        'limit' { return 'лимит' }
        'error' { return 'нет связи' }
        default { return 'пауза' }
    }
}

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
    $tab = $script:ActiveTab
    if ($null -eq $tab) { return }
    $statusKey = Get-TabStatusKey $tab
    if ($statusKey -eq $script:UiStatus) { return }
    $script:UiStatus = $statusKey
    switch ($statusKey) {
        'running' { Set-StatusLook 'РАБОТАЕТ' '#7FD88F' ([string][char]0xE71A) 'ОСТАНОВИТЬ' '#E06C75' '#0A0A0A' $true }
        'paused' { Set-StatusLook 'ПАУЗА' '#F5A742' ([string][char]0xE768) 'ЗАПУСТИТЬ' '#FAB283' '#0A0A0A' $false }
        'limit' { Set-StatusLook 'ЛИМИТ' '#F5A742' ([string][char]0xE768) 'НОВЫЙ ЗАПУСК' '#FAB283' '#0A0A0A' $false }
        'error' { Set-StatusLook 'НЕТ СВЯЗИ' '#E06C75' ([string][char]0xE72C) 'ПОВТОРИТЬ' '#5C9CF5' '#0A0A0A' $false }
    }
}

function Update-Stats {
    if ($null -eq $StatusMeta) { return }
    $tab = $script:ActiveTab
    if ($null -eq $tab) { return }
    $chats = @($tab.Chats)
    $sent = [int]$tab.SentThisRun
    $running = -not [bool]$tab.Stop

    if ($running) {
        $elapsed = if ($tab.RunStartedAt -ne [datetime]::MinValue) { Format-Duration ((Get-Date) - [datetime]$tab.RunStartedAt) } else { '00:00:00' }
        $StatusMeta.Text = "$sent отпр. · $elapsed"
    }
    elseif ([string]$tab.StopReason -eq 'error') {
        $StatusMeta.Text = 'переподключаюсь…'
    }
    else {
        $StatusMeta.Text = "$sent отпр."
    }

    $ChatCountText.Text = [string]$chats.Count

    $mode = [string]$tab.LimitMode
    $now = Get-Date
    if ($mode -eq 'count') {
        $limit = [Math]::Max(1, [int]$tab.LimitCount)
        $value = [Math]::Min($sent, $limit)
        $LimitProgress.Maximum = $limit
        $LimitProgress.Value = $value
        $LimitProgress.Foreground = if ($value -ge $limit) { Brush '#F5A742' } else { Brush '#FAB283' }
        $ProgressLabel.Text = "$value / $limit"
    }
    elseif ($mode -eq 'time') {
        $deadline = if ([long]$tab.DeadlineTicks -gt 0) { [datetime]::new([long]$tab.DeadlineTicks) } else { $null }
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
                $start = [datetime]$tab.RunStartedAt
                if ($tab.LimitSince -ne [datetime]::MinValue -and [datetime]$tab.LimitSince -gt $start) { $start = [datetime]$tab.LimitSince }
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

    $anyRunning = @($state.Tabs | Where-Object { -not $_.Stop }).Count -gt 0
    $LogLiveDot.Fill = if ($anyRunning) { Brush '#7FD88F' } else { Brush '#606060' }
    $LogLiveDot.Opacity = if ($anyRunning) { 0.85 } else { 0.4 }
}

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

function Get-ChatSig($tab) {
    if ($null -eq $tab) { return '' }
    $parts = @()
    foreach ($c in @($tab.Chats)) { $parts += ([string]$c.Id + '|' + [string]$c.Title) }
    return ($tab.Id + '#' + ($parts -join '~'))
}

function Build-ChatRows {
    $tab = $script:ActiveTab
    $ChatPanel.Children.Clear()
    $script:Rows = @()
    $chats = if ($null -ne $tab) { @($tab.Chats) } else { @() }

    if ($chats.Count -eq 0) {
        $empty = [Windows.Controls.Border]::new()
        $empty.Background = Brush '#0F0F0F'
        $empty.BorderBrush = Brush '#282828'
        $empty.BorderThickness = [Windows.Thickness]::new(1)
        $empty.CornerRadius = [Windows.CornerRadius]::new(6)
        $empty.Padding = [Windows.Thickness]::new(12, 11, 12, 11)
        $empty.Margin = [Windows.Thickness]::new(0, 0, 0, 4)
        $t = [Windows.Controls.TextBlock]::new()
        $t.Text = if ($null -ne $tab -and [bool]$tab.AutoAdd) { 'Жду активные чаты OpenCode…' } else { 'Чатов нет — нажмите «+ Добавить»' }
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
    $tab = $script:ActiveTab
    if ($null -eq $tab) { return }
    $chats = @($tab.Chats)
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

function Tab-LogName($tab) {
    if (@($state.Tabs).Count -gt 1) { return '«' + [string]$tab.Name + '»: ' }
    return ''
}

function Start-Run($tab, [bool]$interactive = $true) {
    if ($null -eq $tab) { return $false }
    $isActive = ($null -ne $script:ActiveTab -and [string]$script:ActiveTab.Id -eq [string]$tab.Id)
    $wasReason = [string]$tab.StopReason
    $mode = [string]$tab.LimitMode

    if ([string]::IsNullOrWhiteSpace([string]$tab.Message)) {
        Write-UiLog 'warn' ((Tab-LogName $tab) + 'нечего отправлять — укажите текст сообщения')
        if ($isActive -and $interactive) { $MessageBox.Focus() | Out-Null }
        return $false
    }

    if ($mode -eq 'count') {
        $n = if ($isActive) { Read-LimitCount } else { [int]$tab.LimitCount }
        if ($n -le 0) {
            Write-UiLog 'warn' ((Tab-LogName $tab) + 'лимит итераций: укажите число от 1 до 99999')
            if ($isActive) { $CountBox.Focus() | Out-Null }
            return $false
        }
        $tab.LimitCount = $n
        if ($tab.SentThisRun -ge $n) {
            $tab.SentThisRun = 0
            Write-UiLog 'info' ((Tab-LogName $tab) + 'счётчик итераций сброшен — новый запуск')
        }
    }
    elseif ($mode -eq 'time') {
        $timeText = if ($isActive) { $TimeBox.Text } else { [string]$tab.LimitTime }
        $parsed = Parse-TimeText $timeText
        if (-not $parsed) {
            Write-UiLog 'warn' ((Tab-LogName $tab) + 'лимит по времени: укажите время в формате ЧЧ:ММ')
            if ($isActive) { $TimeBox.Focus() | Out-Null }
            return $false
        }
        $tab.LimitTime = $parsed.Text
        Set-TabDeadline $tab
    }

    if ($tab.RunStartedAt -eq [datetime]::MinValue -or $wasReason -eq 'limit') {
        $tab.RunStartedAt = Get-Date
    }

    Reset-TabChatsForResume $tab

    $tab.Stop = $false
    $tab.StopReason = ''
    $tab.UserPaused = $false
    $tab.LimitHit = ''
    $state.ApiError = ''
    $state.ErrorStreak = 0

    Write-UiLog 'ok' ('▶ ' + (Tab-LogName $tab) + 'автопродолжение запущено')
    $script:Dirty = $true
    return $true
}

function Stop-Run($tab) {
    if ($null -eq $tab -or $tab.Stop) { return }
    $tab.Stop = $true
    $tab.StopReason = 'user'
    $tab.UserPaused = $true
    Write-UiLog 'warn' ('⏸ ' + (Tab-LogName $tab) + 'остановлено вручную')
    $script:Dirty = $true
}

function Toggle-Run {
    $tab = $script:ActiveTab
    if ($null -eq $tab) { return }
    if ($tab.Stop) { [void](Start-Run $tab $true) } else { Stop-Run $tab }
    Update-StatusVisual
    Update-Stats
}

# из трея: если хоть одна вкладка работает — остановить все, иначе запустить все
function Toggle-All {
    $tabs = @($state.Tabs)
    $anyRunning = @($tabs | Where-Object { -not $_.Stop }).Count -gt 0
    if ($anyRunning) {
        foreach ($t in $tabs) { Stop-Run $t }
    }
    else {
        foreach ($t in $tabs) { [void](Start-Run $t $false) }
    }
    Update-StatusVisual
    Update-Stats
}

# ---- вкладки ----

$script:TabUi = @{}
$script:LoadingTab = $false

function Find-TabById([string]$id) {
    foreach ($t in @($state.Tabs)) { if ([string]$t.Id -eq $id) { return $t } }
    return $null
}

function Update-TabVisual($tab) {
    $ui = $script:TabUi[[string]$tab.Id]
    if (-not $ui) { return }
    $active = ($null -ne $script:ActiveTab -and [string]$script:ActiveTab.Id -eq [string]$tab.Id)
    $hover = [bool]$ui.Hover
    $multi = (@($state.Tabs).Count -gt 1)

    $ui.Root.Background = if ($active) { Brush '#141414' } elseif ($hover) { Brush '#0F0F0F' } else { [Windows.Media.Brushes]::Transparent }
    $ui.Root.BorderBrush = if ($active) { Brush '#FAB283' } else { [Windows.Media.Brushes]::Transparent }
    $ui.Title.Foreground = if ($active -or $hover) { Brush '#EEEEEE' } else { Brush '#808080' }

    $showClose = $multi -and ($active -or ($hover -and -not [bool]$ui.Compact))
    $ui.Close.Visibility = if ($multi -and -not [bool]$ui.Compact) { 'Visible' } else { 'Collapsed' }
    $ui.Close.Opacity = if ($showClose) { 1 } else { 0 }
    $ui.Close.IsHitTestVisible = $showClose
}

function Update-TabDot($tab) {
    $ui = $script:TabUi[[string]$tab.Id]
    if (-not $ui) { return }
    $key = Get-TabStatusKey $tab
    $ui.Dot.Fill = Brush (Get-TabDotColor $key)
    $ui.Root.ToolTip = ([string]$tab.Name + ' · ' + (Get-TabStatusWord $key))
}

# вкладки делят ширину поровну (как в Chrome); если места мало, неактивные
# сжимаются до точки статуса, а активная остаётся читаемой
function Update-TabLayout {
    $tabs = @($state.Tabs)
    $n = $tabs.Count
    if ($n -eq 0 -or $null -eq $TabRow -or $TabRow.ActualWidth -lt 80) { return }
    $gap = 2
    $avail = [Math]::Max(60, $TabRow.ActualWidth - 32)
    $TabScroll.MaxWidth = $avail

    $w = [Math]::Floor(($avail - $gap * $n) / $n)
    $compact = ($w -lt 60)
    if (-not $compact) {
        $wAct = [Math]::Min(150, $w)
        $wIn = $wAct
    }
    else {
        $wAct = 100
        $wIn = [Math]::Floor(($avail - $wAct - $gap * $n) / [Math]::Max(1, $n - 1))
        $wIn = [Math]::Max(34, [Math]::Min(60, $wIn))
    }

    foreach ($tab in $tabs) {
        $ui = $script:TabUi[[string]$tab.Id]
        if (-not $ui) { continue }
        $active = ($null -ne $script:ActiveTab -and [string]$script:ActiveTab.Id -eq [string]$tab.Id)
        $dotOnly = ($compact -and -not $active)
        $ui.Compact = $dotOnly
        $ui.Root.Width = if ($active) { $wAct } else { $wIn }
        $ui.Title.Visibility = if ($dotOnly) { 'Collapsed' } else { 'Visible' }
        $ui.Dot.Margin = if ($dotOnly) { [Windows.Thickness]::new(0) } else { [Windows.Thickness]::new(10, 0, 6, 0) }
        $ui.Dot.HorizontalAlignment = if ($dotOnly) { 'Center' } else { 'Left' }
        [Windows.Controls.Grid]::SetColumnSpan($ui.Dot, $(if ($dotOnly) { 3 } else { 1 }))
        Update-TabVisual $tab
    }
}

function Refresh-TabControls {
    $tabs = @($state.Tabs)
    $CloseTabBtn.IsEnabled = ($tabs.Count -gt 1)
    $NewTabBtn.IsEnabled = ($tabs.Count -lt $script:MaxTabs)
    foreach ($t in $tabs) { Update-TabVisual $t }
    Update-TabLayout
}

function New-TabItem($tab) {
    $id = [string]$tab.Id

    $root = [Windows.Controls.Border]::new()
    $root.Height = 30
    $root.VerticalAlignment = 'Bottom'
    $root.CornerRadius = [Windows.CornerRadius]::new(7, 7, 0, 0)
    $root.BorderThickness = [Windows.Thickness]::new(0, 2, 0, 0)
    $root.BorderBrush = [Windows.Media.Brushes]::Transparent
    $root.Background = [Windows.Media.Brushes]::Transparent
    $root.Margin = [Windows.Thickness]::new(0, 0, 2, 0)
    $root.Cursor = [Windows.Input.Cursors]::Hand
    $root.Tag = $id

    $grid = [Windows.Controls.Grid]::new()
    foreach ($w in @('Auto', '*', 'Auto')) {
        $cd = [Windows.Controls.ColumnDefinition]::new()
        $cd.Width = if ($w -eq '*') { [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) } else { [Windows.GridLength]::Auto }
        $grid.ColumnDefinitions.Add($cd) | Out-Null
    }

    $dot = [Windows.Shapes.Ellipse]::new()
    $dot.Width = 6
    $dot.Height = 6
    $dot.Margin = [Windows.Thickness]::new(10, 0, 6, 0)
    $dot.VerticalAlignment = 'Center'
    $dot.HorizontalAlignment = 'Left'
    $dot.Fill = Brush (Get-TabDotColor (Get-TabStatusKey $tab))
    $grid.Children.Add($dot) | Out-Null

    $title = [Windows.Controls.TextBlock]::new()
    $title.Text = [string]$tab.Name
    $title.FontSize = 11
    $title.TextTrimming = 'CharacterEllipsis'
    $title.VerticalAlignment = 'Center'
    $title.Foreground = Brush '#808080'
    [Windows.Controls.Grid]::SetColumn($title, 1)
    $grid.Children.Add($title) | Out-Null

    $close = [Windows.Controls.Border]::new()
    $close.Width = 16
    $close.Height = 16
    $close.CornerRadius = [Windows.CornerRadius]::new(4)
    $close.Margin = [Windows.Thickness]::new(4, 0, 6, 0)
    $close.Background = [Windows.Media.Brushes]::Transparent
    $close.VerticalAlignment = 'Center'
    $close.Cursor = [Windows.Input.Cursors]::Hand
    $close.ToolTip = 'Закрыть вкладку (Ctrl+W)'
    $close.Tag = $id
    $close.Opacity = 0
    $x = [Windows.Controls.TextBlock]::new()
    $x.Text = [string][char]0x2715
    $x.FontSize = 8.5
    $x.Foreground = Brush '#808080'
    $x.HorizontalAlignment = 'Center'
    $x.VerticalAlignment = 'Center'
    $close.Child = $x
    [Windows.Controls.Grid]::SetColumn($close, 2)
    $grid.Children.Add($close) | Out-Null

    $root.Child = $grid

    $refs = @{ Root = $root; Dot = $dot; Title = $title; Close = $close; Hover = $false; Compact = $false }
    $script:TabUi[$id] = $refs

    $root.Add_MouseEnter({
            param($sender, $e)
            $ui = $script:TabUi[[string]$sender.Tag]
            $t = Find-TabById ([string]$sender.Tag)
            if ($ui -and $t) { $ui.Hover = $true; Update-TabVisual $t }
        })
    $root.Add_MouseLeave({
            param($sender, $e)
            $ui = $script:TabUi[[string]$sender.Tag]
            $t = Find-TabById ([string]$sender.Tag)
            if ($ui -and $t) { $ui.Hover = $false; Update-TabVisual $t }
        })
    $root.Add_MouseLeftButtonDown({
            param($sender, $e)
            $t = Find-TabById ([string]$sender.Tag)
            if ($null -eq $t) { return }
            if ($e.ClickCount -ge 2) {
                # двойной щелчок — переименовать
                if ([string]$script:ActiveTab.Id -ne [string]$t.Id) { Select-Tab $t }
                Show-SettingsView $true
                $SettingsView.UpdateLayout()
                $TabNameBox.Focus() | Out-Null
                $TabNameBox.SelectAll()
            }
            elseif ([string]$script:ActiveTab.Id -ne [string]$t.Id) {
                Select-Tab $t
            }
            $e.Handled = $true
        })
    # средняя кнопка мыши закрывает вкладку, как в браузере
    $root.Add_MouseUp({
            param($sender, $e)
            if ($e.ChangedButton -eq 'Middle') {
                $t = Find-TabById ([string]$sender.Tag)
                if ($t) { Close-Tab $t }
                $e.Handled = $true
            }
        })

    $close.Add_MouseEnter({ $this.Background = Brush '#2A1416'; $this.Child.Foreground = Brush '#E06C75' })
    $close.Add_MouseLeave({ $this.Background = [Windows.Media.Brushes]::Transparent; $this.Child.Foreground = Brush '#808080' })
    $close.Add_MouseLeftButtonDown({ param($sender, $e) $e.Handled = $true })
    $close.Add_MouseLeftButtonUp({
            param($sender, $e)
            $t = Find-TabById ([string]$sender.Tag)
            if ($t) { Close-Tab $t }
            $e.Handled = $true
        })

    return $refs
}

function Add-TabItem($tab) {
    $refs = New-TabItem $tab
    [void]$TabPanel.Children.Add($refs.Root)
    Update-TabDot $tab
}

# подгружает данные вкладки в общие элементы окна
function Select-Tab($tab) {
    if ($null -eq $tab) { return }
    $script:ActiveTab = $tab
    $script:LoadingTab = $true
    try {
        $MessageBox.Text = [string]$tab.Message
        $CountBox.Text = [string]$tab.LimitCount
        $TimeBox.Text = [string]$tab.LimitTime
        $AutoAddChk.IsChecked = [bool]$tab.AutoAdd
        $TabNameBox.Text = [string]$tab.Name
        switch ([string]$tab.LimitMode) {
            'count' { $LimitCountRadio.IsChecked = $true }
            'time' { $LimitTimeRadio.IsChecked = $true }
            default { $LimitNone.IsChecked = $true }
        }
    }
    finally {
        $script:LoadingTab = $false
    }
    $MessageHint.Visibility = if ($MessageBox.Text.Length -gt 0) { 'Collapsed' } else { 'Visible' }
    $CountBox.BorderBrush = Brush '#282828'
    $TimeBox.BorderBrush = Brush '#282828'
    Update-LimitInputs
    Build-ChatRows
    $script:LastSig = Get-ChatSig $tab
    $script:UiStatus = ''
    Update-StatusVisual
    Update-Stats
    Refresh-TabControls
    $ui = $script:TabUi[[string]$tab.Id]
    if ($ui) { try { $TabPanel.UpdateLayout(); $ui.Root.BringIntoView() } catch { } }
    $script:Dirty = $true
}

function Add-Tab {
    if (@($state.Tabs).Count -ge $script:MaxTabs) {
        Write-UiLog 'warn' ('Больше ' + $script:MaxTabs + ' вкладок не поместится')
        return
    }
    $names = @($state.Tabs | ForEach-Object { [string]$_.Name })
    $n = 1
    while ($names -contains ('Задача ' + $n)) { $n++ }

    # новая вкладка стартует на паузе и без текста: пока не задан промт и не выбраны чаты, отправлять нечего
    $tab = New-TabObject @{
        id = (New-TabId); name = ('Задача ' + $n); message = ''; autoAdd = $false; paused = $true
        chats = @(); limitMode = 'none'; limitCount = 50; limitTime = '18:00'
    } $false
    $state.Tabs = @($state.Tabs) + , $tab
    Add-TabItem $tab
    Select-Tab $tab
    Show-SettingsView $false
    Write-UiLog 'info' ('Новая вкладка «' + $tab.Name + '» — на паузе, укажите текст и добавьте чаты')
    $MessageBox.Focus() | Out-Null
}

function Close-Tab($tab) {
    if ($null -eq $tab) { return }
    $tabs = @($state.Tabs)
    if ($tabs.Count -le 1) { return }

    $chatCount = @($tab.Chats).Count
    if ($chatCount -gt 0) {
        $word = Plural $chatCount 'чат' 'чата' 'чатов'
        $text = '«' + [string]$tab.Name + '»: ' + $chatCount + ' ' + $word + ' перестанут отслеживаться, текст сообщения и лимит будут потеряны.'
        if (-not (Show-Confirm 'Закрыть вкладку?' $text 'Закрыть')) { return }
    }

    $idx = 0
    for ($i = 0; $i -lt $tabs.Count; $i++) {
        if ([string]$tabs[$i].Id -eq [string]$tab.Id) { $idx = $i; break }
    }

    $tab.Deleted = $true
    $tab.Stop = $true
    $remaining = @($tabs | Where-Object { [string]$_.Id -ne [string]$tab.Id })
    $state.Tabs = $remaining

    $ui = $script:TabUi[[string]$tab.Id]
    if ($ui) {
        [void]$TabPanel.Children.Remove($ui.Root)
        $script:TabUi.Remove([string]$tab.Id)
    }
    Write-UiLog 'info' ('Вкладка «' + [string]$tab.Name + '» закрыта')

    if ($null -ne $script:ActiveTab -and [string]$script:ActiveTab.Id -eq [string]$tab.Id) {
        Select-Tab $remaining[[Math]::Min($idx, $remaining.Count - 1)]
    }
    else {
        Refresh-TabControls
    }
    $script:Dirty = $true
}

function Step-Tab([int]$direction) {
    $tabs = @($state.Tabs)
    if ($tabs.Count -lt 2) { return }
    $cur = 0
    for ($i = 0; $i -lt $tabs.Count; $i++) {
        if ([string]$tabs[$i].Id -eq [string]$script:ActiveTab.Id) { $cur = $i; break }
    }
    $next = ($cur + $direction + $tabs.Count) % $tabs.Count
    Select-Tab $tabs[$next]
}

function Select-TabNumber([int]$number) {
    $tabs = @($state.Tabs)
    if ($number -ge 1 -and $number -le $tabs.Count) { Select-Tab $tabs[$number - 1] }
}

# маленький тёмный диалог подтверждения (системный MessageBox светлый и выбивается из стиля)
function Show-Confirm([string]$title, [string]$text, [string]$okText, [bool]$infoOnly = $false) {
    $cfXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="340" SizeToContent="Height" WindowStyle="None" ResizeMode="NoResize"
        ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        Background="#0A0A0A" Foreground="#EEEEEE"
        FontFamily="Cascadia Mono, Consolas" FontSize="12"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="CfButton" TargetType="Button">
      <Setter Property="Height" Value="30"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="1" CornerRadius="5"/>
              <Border x:Name="Hover" Background="#1FFFFFFF" CornerRadius="5" Opacity="0"/>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Hover" Property="Opacity" Value="1"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border BorderBrush="#3C3C3C" BorderThickness="1">
    <StackPanel Margin="18,16,18,16">
      <TextBlock x:Name="CfTitle" FontWeight="SemiBold" FontSize="13"/>
      <TextBlock x:Name="CfText" Margin="0,10,0,0" Foreground="#A0A0A0" TextWrapping="Wrap" LineHeight="18"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
        <Button x:Name="CfCancel" Content="Отмена" Width="90" Style="{StaticResource CfButton}"
                Background="Transparent" BorderBrush="#3C3C3C" Foreground="#A0A0A0"/>
        <Button x:Name="CfOk" Width="110" Margin="8,0,0,0" Style="{StaticResource CfButton}"
                Background="#E06C75" BorderBrush="#E06C75" Foreground="#0A0A0A" FontWeight="Bold"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@
    $dlg = [Windows.Markup.XamlReader]::Parse($cfXaml)
    $dlg.Owner = $window
    $dlg.Topmost = $window.Topmost
    $dlg.FindName('CfTitle').Text = $title
    $dlg.FindName('CfText').Text = $text
    $dlg.FindName('CfOk').Content = $okText
    if ($infoOnly) {
        $dlg.FindName('CfCancel').Visibility = 'Collapsed'
        $okBtn = $dlg.FindName('CfOk')
        $okBtn.Background = Brush '#FAB283'
        $okBtn.BorderBrush = Brush '#FAB283'
    }
    $script:ConfirmResult = $false
    $dlg.FindName('CfOk').Add_Click({ $script:ConfirmResult = $true; $dlg.Close() })
    $dlg.FindName('CfCancel').Add_Click({ $dlg.Close() })
    $dlg.Add_KeyDown({
            param($s, $e)
            if ($e.Key -eq 'Escape') { $dlg.Close() }
            elseif ($e.Key -eq 'Return') { $script:ConfirmResult = $true; $dlg.Close() }
        })
    [void]$dlg.ShowDialog()
    return [bool]$script:ConfirmResult
}

function Show-AddDialog {
    $script:DialogTab = $script:ActiveTab
    if (-not (Update-ServiceInfo)) {
        [void](Show-Confirm 'Сервис не найден' 'Сервис OpenCode не найден. Запустите OpenCode и попробуйте снова.' 'OK' $true)
        return
    }
    Update-ServiceInfo | Out-Null

    try {
        $r = Invoke-OcApi 'GET' '/api/session?limit=100' -Timeout 6000
    }
    catch {
        [void](Show-Confirm 'Нет списка чатов' ('Не удалось получить список чатов: ' + $_.Exception.Message) 'OK' $true)
        return
    }

    $tracked = @{}
    foreach ($t in @($state.Tabs)) {
        foreach ($c in @($t.Chats)) { if ($c.Id) { $tracked[[string]$c.Id] = $true } }
    }

    $all = @($r.data | Where-Object { -not $_.parentID -and -not $_.archived -and -not $tracked.ContainsKey([string]$_.id) })
    if ($all.Count -eq 0) {
        [void](Show-Confirm 'Нет чатов' 'Все недавние сессии уже добавлены — в эту или в другие вкладки.' 'OK' $true)
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
    $dlgTitle.Text = 'Добавить в «' + [string]$script:DialogTab.Name + '»'
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
        $state.AddQueue.Enqueue(@{ Id = [string]$cand.Id; Title = [string]$cand.Title; TabId = [string]$script:DialogTab.Id })
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

# ---- обработчики ----

$MessageBox.Add_TextChanged({
        if ($script:LoadingTab) { return }
        $MessageHint.Visibility = if ($MessageBox.Text.Length -gt 0) { 'Collapsed' } else { 'Visible' }
        if ($null -ne $script:ActiveTab) { $script:ActiveTab.Message = $MessageBox.Text }
        $script:Dirty = $true
    })

# автодобавление включено только в одной вкладке, иначе непонятно, куда класть новый чат
$AutoAddChk.Add_Click({
        $tab = $script:ActiveTab
        if ($null -eq $tab) { return }
        $on = [bool]$AutoAddChk.IsChecked
        $tab.AutoAdd = $on
        if ($on) {
            foreach ($t in @($state.Tabs)) {
                if ([string]$t.Id -ne [string]$tab.Id -and [bool]$t.AutoAdd) {
                    $t.AutoAdd = $false
                    Write-UiLog 'info' ('Автодобавление перенесено из «' + [string]$t.Name + '» в «' + [string]$tab.Name + '»')
                }
            }
        }
        Write-UiLog 'info' ('Автодобавление чатов (' + [string]$tab.Name + '): ' + $(if ($on) { 'вкл' } else { 'выкл' }))
        Build-ChatRows
        $script:Dirty = $true
    })

$TopmostChk.Add_Click({
        $script:Topmost = [bool]$TopmostChk.IsChecked
        $window.Topmost = $script:Topmost
        $settings.topmost = $script:Topmost
        $script:Dirty = $true
    })

$TabNameBox.Add_TextChanged({
        if ($script:LoadingTab) { return }
        $tab = $script:ActiveTab
        if ($null -eq $tab) { return }
        $name = $TabNameBox.Text.Trim()
        if (-not $name) { return }
        $tab.Name = $name
        $ui = $script:TabUi[[string]$tab.Id]
        if ($ui) { $ui.Title.Text = $name }
        Update-TabDot $tab
        $script:Dirty = $true
    })
$TabNameBox.Add_LostFocus({
        $tab = $script:ActiveTab
        if ($null -ne $tab -and -not $TabNameBox.Text.Trim()) { $TabNameBox.Text = [string]$tab.Name }
    })

$NewTabBtn.Add_Click({ Add-Tab })
$CloseTabBtn.Add_Click({ Close-Tab $script:ActiveTab })
$TabScroll.Add_PreviewMouseWheel({
        param($s, $e)
        $TabScroll.ScrollToHorizontalOffset($TabScroll.HorizontalOffset - $e.Delta)
        $e.Handled = $true
    })

$SettingsBtn.Add_Click({ Show-SettingsView ($SettingsView.Visibility -ne 'Visible') })
$BackBtn.Add_Click({ Show-SettingsView $false })

# Ctrl+T — новая вкладка, Ctrl+W — закрыть, Ctrl+Tab / Ctrl+Shift+Tab — переключение, Ctrl+1..9 — по номеру
$window.Add_PreviewKeyDown({
        param($s, $e)
        $key = [string]$e.Key
        if ($key -eq 'Escape' -and $SettingsView.Visibility -eq 'Visible') {
            Show-SettingsView $false
            $e.Handled = $true
            return
        }
        $mods = [Windows.Input.Keyboard]::Modifiers
        if (($mods -band [Windows.Input.ModifierKeys]::Control) -eq 0) { return }
        $shift = (($mods -band [Windows.Input.ModifierKeys]::Shift) -ne 0)
        if ($key -eq 'T') { Add-Tab; $e.Handled = $true }
        elseif ($key -eq 'W') { Close-Tab $script:ActiveTab; $e.Handled = $true }
        elseif ($key -eq 'Tab') { Step-Tab $(if ($shift) { -1 } else { 1 }); $e.Handled = $true }
        elseif ($key -match '^D([1-9])$') { Select-TabNumber ([int]$Matches[1]); $e.Handled = $true }
    })

$LimitNone.Add_Checked({ if ($LimitNone.IsChecked) { Set-LimitModeUi 'none' } })
$LimitCountRadio.Add_Checked({ if ($LimitCountRadio.IsChecked) { Set-LimitModeUi 'count' } })
$LimitTimeRadio.Add_Checked({ if ($LimitTimeRadio.IsChecked) { Set-LimitModeUi 'time' } })

$CountBox.Add_TextChanged({ Apply-CountFromUi; Update-Stats })
$CountBox.Add_LostFocus({
        $tab = $script:ActiveTab
        if ($null -eq $tab) { return }
        $n = Read-LimitCount
        if ($n -gt 0) { $tab.LimitCount = $n; $CountBox.Text = [string]$n }
        else { $CountBox.Text = [string]$tab.LimitCount }
        Update-LimitInputs
        $script:Dirty = $true
    })

$TimeBox.Add_TextChanged({ Apply-TimeFromUi; Update-Stats })
$TimeBox.Add_LostFocus({
        $tab = $script:ActiveTab
        if ($null -eq $tab) { return }
        $parsed = Parse-TimeText $TimeBox.Text
        if ($parsed) { $TimeBox.Text = $parsed.Text }
        else { $TimeBox.Text = [string]$tab.LimitTime }
        Apply-TimeFromUi
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

$window.Add_SizeChanged({ Update-TabLayout })

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

        Update-TabLayout
    })

$window.Add_Closed({
        $state.Shutdown = $true
        foreach ($t in @($state.Tabs)) { $t.Stop = $true }
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
$script:LastTrayText = ''
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
    $script:TrayToggle = New-Object System.Windows.Forms.ToolStripMenuItem('Остановить все')
    $trayExit = New-Object System.Windows.Forms.ToolStripMenuItem('Выход')
    [void]$trayMenu.Items.Add($trayShow)
    [void]$trayMenu.Items.Add($script:TrayToggle)
    [void]$trayMenu.Items.Add($trayExit)
    $trayIcon.ContextMenuStrip = $trayMenu

    $trayShow.Add_Click({ $window.Show(); $window.WindowState = 'Normal'; $window.Activate() })
    $script:TrayToggle.Add_Click({ Toggle-All })
    $trayExit.Add_Click({ $window.Close() })
    $trayIcon.Add_DoubleClick({ $window.Show(); $window.WindowState = 'Normal'; $window.Activate() })

    $script:TrayIcon = $trayIcon
}
catch { }

# ---- таймер интерфейса ----

$script:LastAllSig = ''

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

            # состояние каждой вкладки: цвет точки и уведомления о потере связи / лимите
            $tabsNow = @($state.Tabs)
            $errNames = @()
            $limitNames = @()
            foreach ($tab in $tabsNow) {
                $key = Get-TabStatusKey $tab
                if ($key -ne [string]$tab.UiKey) {
                    $first = ([string]$tab.UiKey -eq '')
                    $tab.UiKey = $key
                    Update-TabDot $tab
                    if (-not $first) {
                        if ($key -eq 'error') { $errNames += [string]$tab.Name }
                        elseif ($key -eq 'limit') { $limitNames += [string]$tab.Name }
                    }
                }
            }
            if ($errNames.Count -gt 0) {
                Show-Balloon 'OpenCode AutoContinue' 'Нет связи с OpenCode. Автопродолжение приостановлено, переподключение в фоне.'
            }
            if ($limitNames.Count -gt 0) {
                $msg = if ($tabsNow.Count -gt 1) { 'Лимит запуска достигнут: ' + ($limitNames -join ', ') } else { 'Лимит запуска достигнут — автопродолжение остановлено.' }
                Show-Balloon 'OpenCode AutoContinue' $msg
            }

            # чаты могут появиться и в неактивных вкладках (автодобавление) — это тоже повод сохранить настройки
            $allSig = ($tabsNow | ForEach-Object { Get-ChatSig $_ }) -join '|'
            if ($allSig -ne $script:LastAllSig) { $script:LastAllSig = $allSig; $script:Dirty = $true }

            $sig = Get-ChatSig $script:ActiveTab
            if ($sig -ne $script:LastSig) {
                $script:LastSig = $sig
                Build-ChatRows
            }
            Update-ChatRows
            Update-StatusVisual
            Update-Stats

            if ($script:TrayIcon) {
                $running = @($tabsNow | Where-Object { -not $_.Stop }).Count
                $trayText = if ($tabsNow.Count -le 1) {
                    if ($running -gt 0) { 'AutoContinue — работает' } else { 'AutoContinue — пауза' }
                }
                else { 'AutoContinue — работает ' + $running + ' из ' + $tabsNow.Count }
                if ($trayText -ne $script:LastTrayText) {
                    $script:LastTrayText = $trayText
                    $script:TrayIcon.Text = $trayText
                    if ($script:TrayToggle) { $script:TrayToggle.Text = if ($running -gt 0) { 'Остановить все' } else { 'Запустить все' } }
                }
            }

            if ($script:Dirty) { Save-Settings }
        }
        catch {
            try {
                [IO.File]::AppendAllText($script:LogFile, ((Get-Date).ToString('HH:mm:ss') + '  [x] Ошибка интерфейса: ' + $_.Exception.Message + "`r`n"))
            }
            catch { }
        }
    })

# ---- старт ----

foreach ($t in @($state.Tabs)) {
    if ([string]$t.LimitMode -eq 'time') { Set-TabDeadline $t }
    Add-TabItem $t
}
$startTab = Find-TabById ([string]$settings.activeTab)
if ($null -eq $startTab) { $startTab = @($state.Tabs)[0] }
Select-Tab $startTab
$script:LastAllSig = (@($state.Tabs | ForEach-Object { Get-ChatSig $_ }) -join '|')
$script:Dirty = $false

Write-UiLog 'info' ('Окно запущено · v' + $script:AppVersion + ' · вкладок: ' + @($state.Tabs).Count + ' · интервал ' + $state.PollMs + ' мс')
$timer.Start()

# страховка: необработанная ошибка в любом обработчике пишется в журнал и не закрывает окно
try {
    $window.Dispatcher.Add_UnhandledException({
            param($s, $e)
            try { [IO.File]::AppendAllText($script:LogFile, ((Get-Date).ToString('HH:mm:ss') + '  [x] Ошибка интерфейса: ' + $e.Exception.Message + "`r`n")) } catch { }
            try { Write-UiLog 'err' ('Ошибка интерфейса: ' + $e.Exception.Message) } catch { }
            $e.Handled = $true
        })
}
catch { }

[void]$window.ShowDialog()

# ---------------------------------------------------------------- cleanup ----

$state.Shutdown = $true
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
