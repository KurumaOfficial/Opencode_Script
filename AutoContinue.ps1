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

    Запуск: Запустить.cmd  (или powershell -ExecutionPolicy Bypass -File AutoContinue.ps1)
#>
param(
    [string[]]$ChatTitles = @(),
    [string]$MessageText = 'Продолжай разработку',
    [int]$PollMs = 1200,
    [switch]$StartStopped
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

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

$service = Get-ServiceInfo
if (-not $service -or -not $service.url) {
    [void][Windows.MessageBox]::Show(
        "Не найден запущенный сервис OpenCode.`n`nЗапустите OpenCode и попробуйте снова.",
        'OpenCode AutoContinue', 'OK', 'Error')
    exit 1
}

$script:BaseUrl = $service.url.TrimEnd('/')
$script:Auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("opencode:$($service.password)"))

# ---- каталог данных: рядом со скриптом, а у .exe — в профиле ----
$exePath = ''
try { $exePath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { }
$isCompiled = ($exePath -match '\.exe$') -and ($exePath -notmatch 'powershell(_ise)?\.exe$')

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
    $req.UserAgent = 'OpenCode-AutoContinue/1.1'
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
    message = $MessageText
    autoAdd = $true
    chats   = @()
    ignored = @()
}

if (Test-Path -LiteralPath $script:SettingsPath) {
    try {
        $raw = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
        if ($raw.message) { $settings.message = [string]$raw.message }
        if ($null -ne $raw.autoAdd) { $settings.autoAdd = [bool]$raw.autoAdd }
        if ($raw.chats) {
            $settings.chats = @($raw.chats | ForEach-Object {
                    @{ Id = [string]$_.id; Title = [string]$_.title }
                })
        }
        if ($raw.ignored) { $settings.ignored = @($raw.ignored | ForEach-Object { [string]$_ }) }
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
            message = [string]$state.Message
            autoAdd = [bool]$state.AutoAdd
            chats   = @($state.Chats | ForEach-Object { @{ id = [string]$_.Id; title = [string]$_.Title } })
            ignored = @($state.Ignored.Keys)
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
$state.Message = [string]$settings.message
$state.AutoAdd = [bool]$settings.autoAdd
$state.PollMs = [Math]::Max(500, $PollMs)
$state.Stop = [bool]$StartStopped
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
                Id     = [string]$c.Id
                Title  = [string]$c.Title
                Phase  = 'init'
                Status = 'запуск…'
                Count  = 0
                SentAt = [datetime]::MinValue
            }))
}
$state.SeedChats = $seed
$state.Chats = $seed

$state.Log.Enqueue("$(Get-Date -Format 'HH:mm:ss')  Сервер: $script:BaseUrl")

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
    $req.UserAgent = 'OpenCode-AutoContinue/1.1'
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

function Log([string]$msg) {
    $state.Log.Enqueue("$((Get-Date).ToString('HH:mm:ss'))  $msg")
}

$chats = New-Object System.Collections.ArrayList
foreach ($c in $state.SeedChats) { [void]$chats.Add($c) }
$state.Chats = @($chats)

function Sync-Chats {
    $state.Chats = @($chats)
}

function Find-Chat([string]$id) {
    foreach ($c in $chats) { if ($c.Id -eq $id) { return $c } }
    return $null
}

function Add-Chat([string]$id, [string]$title, [string]$reason) {
    if (-not $id) { return }
    if ($null -ne (Find-Chat $id)) { return }
    $chat = [hashtable]::Synchronized(@{
            Id     = $id
            Title  = $title
            Phase  = 'waiting'
            Status = 'ожидание ответа'
            Count  = 0
            SentAt = [datetime]::MinValue
        })
    [void]$chats.Add($chat)
    Sync-Chats
    $name = if ($title) { $title } else { $id }
    Log ("+ добавлен чат «" + $name + "»" + $(if ($reason) { " — " + $reason } else { '' }))
}

function Remove-Chat([string]$id, [string]$why) {
    for ($i = $chats.Count - 1; $i -ge 0; $i--) {
        if ($chats[$i].Id -eq $id) {
            $name = if ($chats[$i].Title) { $chats[$i].Title } else { $id }
            $chats.RemoveAt($i)
            Sync-Chats
            Log ("− убран чат «" + $name + "»" + $(if ($why) { " — " + $why } else { '' }))
        }
    }
}

function Resolve-Chat($chat) {
    if ($chat.Id) { return $true }
    try {
        $query = [uri]::EscapeDataString($chat.Title)
        $r = API 'GET' "/api/session?limit=100&search=$query"
        $hit = @($r.data | Where-Object { $_.title -eq $chat.Title })
        if ($hit.Count -gt 0) {
            $chat.Id = $hit[0].id
            $chat.Phase = 'waiting'
            $chat.Status = 'ожидание ответа'
            Log ("[" + $chat.Title + "] найден " + $chat.Id)
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
        $chat.Status = 'пустой текст в настройках'
        return
    }
    try {
        $null = API 'POST' ("/api/session/" + $chat.Id + "/prompt") @{ text = $state.Message; delivery = 'queue' }
        $chat.Count = [int]$chat.Count + 1
        $chat.SentAt = Get-Date
        $chat.Phase = 'sent'
        $chat.Status = "отправлено #$($chat.Count)"
        $name = if ($chat.Title) { $chat.Title } else { $chat.Id }
        Log ("[" + $name + "] → " + $state.Message + "  (#" + $chat.Count + ")")
    }
    catch {
        $msg = $_.Exception.Message
        $chat.Status = 'ошибка отправки'
        $name = if ($chat.Title) { $chat.Title } else { $chat.Id }
        Log ("[" + $name + "] ошибка: " + $msg)
        if ($msg -match '^HTTP 404') {
            Remove-Chat $chat.Id 'сессия удалена'
        }
        else {
            $chat.Phase = 'waiting'
        }
    }
}

$infoCache = @{}
$lastResolve = [datetime]::MinValue

while ($true) {
    if ($state.Stop) {
        Start-Sleep -Milliseconds 300
        continue
    }

    # команды из интерфейса
    $item = $null
    while ($state.RemoveQueue.TryDequeue([ref]$item)) { Remove-Chat $item '' }
    while ($state.AddQueue.TryDequeue([ref]$item)) {
        $state.Ignored.Remove([string]$item.Id)
        Add-Chat ([string]$item.Id) ([string]$item.Title) 'добавлен вручную'
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
        if ($act -and $act.data) {
            foreach ($prop in $act.data.PSObject.Properties) { $running[$prop.Name] = $true }
        }
        $state.ApiError = ''
    }
    catch {
        $state.ApiError = $_.Exception.Message
        Log ('Нет связи с сервером: ' + $_.Exception.Message)
        Start-Sleep -Milliseconds 3000
        continue
    }

    # авто-подхват активных чатов
    if ($state.AutoAdd) {
        foreach ($id in @($running.Keys)) {
            if ($null -ne (Find-Chat $id)) { continue }
            if ($state.Ignored.ContainsKey($id)) { continue }

            if (-not $infoCache.ContainsKey($id)) {
                try {
                    $info = (API 'GET' ("/api/session/" + $id)).data
                    $infoCache[$id] = $info
                }
                catch {
                    $infoCache[$id] = $null
                }
            }
            $info = $infoCache[$id]
            if ($null -eq $info) { continue }
            if ($info.parentID) { continue }          # под-агенты не трогаем
            if ($info.archived) { continue }

            $title = [string]$info.title
            Add-Chat $id $title 'активный чат'
            if ($state.Ignored.ContainsKey($id)) { $state.Ignored.Remove($id) }
        }
    }

    foreach ($chat in $chats.ToArray()) {
        if ($state.Stop) { break }
        if (-not $chat.Id) { continue }

        $busy = $running.ContainsKey($chat.Id)

        switch ($chat.Phase) {
            'waiting' {
                if ($busy) {
                    $chat.Phase = 'running'
                    $chat.Status = 'печатает…'
                }
                else {
                    Send-Chat $chat
                }
            }
            'sent' {
                if ($busy) {
                    $chat.Phase = 'running'
                    $chat.Status = 'печатает…'
                }
                elseif (((Get-Date) - $chat.SentAt).TotalSeconds -gt 20) {
                    $chat.Phase = 'waiting'
                    $chat.Status = 'не запустилось, повтор'
                }
            }
            'running' {
                if (-not $busy) {
                    $chat.Phase = 'waiting'
                    $chat.Status = 'ответ получен, ждём отправки'
                    $name = if ($chat.Title) { $chat.Title } else { $chat.Id }
                    Log ("[" + $name + "] ответ завершён")
                }
            }
            default {
                $chat.Phase = 'waiting'
                $chat.Status = 'ожидание ответа'
            }
        }
    }

    Start-Sleep -Milliseconds $state.PollMs
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

function Brush([string]$hex) {
    return [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($hex))
}

$bg = Brush '#12151b'
$panelBg = Brush '#1b2029'
$fieldBg = Brush '#0f131a'
$fgMain = Brush '#f2f5fa'
$fgMuted = Brush '#8c96a8'
$green = Brush '#22c55e'
$red = Brush '#ef4444'
$blue = Brush '#4f8ef7'
$amber = Brush '#f59e0b'

$window = [Windows.Window]::new()
$window.Title = 'OpenCode · Автопродолжение'
$window.Width = 620
$window.Height = 700
$window.MinWidth = 540
$window.MinHeight = 520
$window.WindowStartupLocation = 'CenterScreen'
$window.Topmost = $true
$window.Background = $bg
$window.Foreground = $fgMain
$window.FontFamily = [Windows.Media.FontFamily]::new('Segoe UI')

$root = [Windows.Controls.Grid]::new()
$root.Margin = [Windows.Thickness]::new(18, 16, 18, 16)

$unitAuto = [Windows.GridUnitType]::Auto
$unitStar = [Windows.GridUnitType]::Star
foreach ($h in @($unitAuto, $unitAuto, $unitAuto, $unitAuto, $unitAuto, $unitStar, $unitAuto)) {
    $rd = [Windows.Controls.RowDefinition]::new()
    $rd.Height = [Windows.GridLength]::new(1, $h)
    $root.RowDefinitions.Add($rd) | Out-Null
}

# --- header ---
$header = [Windows.Controls.Grid]::new()
$hc1 = [Windows.Controls.ColumnDefinition]::new()
$hc1.Width = [Windows.GridLength]::new(1, $unitStar)
$hc2 = [Windows.Controls.ColumnDefinition]::new()
$hc2.Width = [Windows.GridLength]::new(1, $unitAuto)
$header.ColumnDefinitions.Add($hc1) | Out-Null
$header.ColumnDefinitions.Add($hc2) | Out-Null

$titleStack = [Windows.Controls.StackPanel]::new()
$titleTb = [Windows.Controls.TextBlock]::new()
$titleTb.Text = 'Автопродолжение чатов'
$titleTb.FontSize = 22
$titleTb.FontWeight = [Windows.FontWeights]::SemiBold
$titleTb.Foreground = $fgMain
$subTb = [Windows.Controls.TextBlock]::new()
$subTb.Text = 'после каждого ответа бот получает сообщение из настроек'
$subTb.FontSize = 12
$subTb.Margin = [Windows.Thickness]::new(0, 4, 0, 0)
$subTb.Foreground = $fgMuted
$titleStack.Children.Add($titleTb) | Out-Null
$titleStack.Children.Add($subTb) | Out-Null
$header.Children.Add($titleStack) | Out-Null

$pill = [Windows.Controls.Border]::new()
$pill.CornerRadius = [Windows.CornerRadius]::new(20)
$pill.Padding = [Windows.Thickness]::new(12, 6, 12, 6)
$pill.VerticalAlignment = 'Top'
$pill.Background = Brush '#1f2937'
$pillLbl = [Windows.Controls.TextBlock]::new()
$pillLbl.Text = 'РАБОТАЕТ'
$pillLbl.FontSize = 11
$pillLbl.FontWeight = [Windows.FontWeights]::Bold
$pillLbl.Foreground = $green
$pill.Child = $pillLbl
[Windows.Controls.Grid]::SetColumn($pill, 1)
$header.Children.Add($pill) | Out-Null
[Windows.Controls.Grid]::SetRow($header, 0)
$root.Children.Add($header) | Out-Null

# --- settings ---
$setBorder = [Windows.Controls.Border]::new()
$setBorder.Background = $panelBg
$setBorder.CornerRadius = [Windows.CornerRadius]::new(12)
$setBorder.Padding = [Windows.Thickness]::new(14, 12, 14, 12)
$setBorder.Margin = [Windows.Thickness]::new(0, 16, 0, 0)
[Windows.Controls.Grid]::SetRow($setBorder, 1)
$root.Children.Add($setBorder) | Out-Null

$setStack = [Windows.Controls.StackPanel]::new()
$setBorder.Child = $setStack

$msgLabel = [Windows.Controls.TextBlock]::new()
$msgLabel.Text = 'Текст сообщения'
$msgLabel.FontSize = 11
$msgLabel.FontWeight = [Windows.FontWeights]::Bold
$msgLabel.Foreground = $fgMuted
$setStack.Children.Add($msgLabel) | Out-Null

$msgBox = [Windows.Controls.TextBox]::new()
$msgBox.Text = [string]$state.Message
$msgBox.FontSize = 14
$msgBox.Padding = [Windows.Thickness]::new(8, 6, 8, 6)
$msgBox.Margin = [Windows.Thickness]::new(0, 6, 0, 0)
$msgBox.MinHeight = 54
$msgBox.MaxHeight = 90
$msgBox.AcceptsReturn = $true
$msgBox.TextWrapping = 'Wrap'
$msgBox.VerticalScrollBarVisibility = 'Auto'
$msgBox.Background = $fieldBg
$msgBox.Foreground = $fgMain
$msgBox.CaretBrush = $fgMain
$msgBox.BorderThickness = [Windows.Thickness]::new(1)
$msgBox.BorderBrush = Brush '#2a3140'
$setStack.Children.Add($msgBox) | Out-Null

$autoChk = [Windows.Controls.CheckBox]::new()
$autoChk.Content = 'Автоматически добавлять активные чаты'
$autoChk.IsChecked = [bool]$state.AutoAdd
$autoChk.Foreground = $fgMain
$autoChk.FontSize = 12
$autoChk.Margin = [Windows.Thickness]::new(0, 10, 0, 0)
$setStack.Children.Add($autoChk) | Out-Null

$autoHint = [Windows.Controls.TextBlock]::new()
$autoHint.Text = 'новый чат появится в списке сам, как только в нём начнётся работа'
$autoHint.FontSize = 11
$autoHint.Margin = [Windows.Thickness]::new(22, 2, 0, 0)
$autoHint.Foreground = $fgMuted
$setStack.Children.Add($autoHint) | Out-Null

# --- chats header ---
$chatsHead = [Windows.Controls.Grid]::new()
$chatsHead.Margin = [Windows.Thickness]::new(0, 16, 0, 8)
$ch1 = [Windows.Controls.ColumnDefinition]::new()
$ch1.Width = [Windows.GridLength]::new(1, $unitStar)
$ch2 = [Windows.Controls.ColumnDefinition]::new()
$ch2.Width = [Windows.GridLength]::new(1, $unitAuto)
$chatsHead.ColumnDefinitions.Add($ch1) | Out-Null
$chatsHead.ColumnDefinitions.Add($ch2) | Out-Null

$chatsLbl = [Windows.Controls.TextBlock]::new()
$chatsLbl.Text = 'ЧАТЫ'
$chatsLbl.FontSize = 11
$chatsLbl.FontWeight = [Windows.FontWeights]::Bold
$chatsLbl.Foreground = $fgMuted
$chatsLbl.VerticalAlignment = 'Center'
$chatsHead.Children.Add($chatsLbl) | Out-Null

function New-FlatButton {
    param([string]$Text, [Windows.Media.Brush]$Background, [Windows.Media.Brush]$Foreground, [int]$Height = 46, [int]$Width = 0, [double]$FontSize = 15)
    $b = [Windows.Controls.Border]::new()
    $b.Background = $Background
    $b.CornerRadius = [Windows.CornerRadius]::new(9)
    $b.Height = $Height
    $b.Cursor = [Windows.Input.Cursors]::Hand
    if ($Width -gt 0) { $b.Width = $Width }
    $tb = [Windows.Controls.TextBlock]::new()
    $tb.Text = $Text
    $tb.FontSize = $FontSize
    $tb.FontWeight = [Windows.FontWeights]::Bold
    $tb.Foreground = $Foreground
    $tb.HorizontalAlignment = 'Center'
    $tb.VerticalAlignment = 'Center'
    $b.Child = $tb
    return $b
}

$addBtn = New-FlatButton -Text '+ Добавить' -Background (Brush '#232936') -Foreground $fgMain -Height 26 -Width 104 -FontSize 11.5
[Windows.Controls.Grid]::SetColumn($addBtn, 1)
$chatsHead.Children.Add($addBtn) | Out-Null
[Windows.Controls.Grid]::SetRow($chatsHead, 2)
$root.Children.Add($chatsHead) | Out-Null

# --- chats list ---
$chatPanel = [Windows.Controls.StackPanel]::new()
$chatScroll = [Windows.Controls.ScrollViewer]::new()
$chatScroll.Content = $chatPanel
$chatScroll.MaxHeight = 176
$chatScroll.VerticalScrollBarVisibility = 'Auto'
$chatScroll.HorizontalScrollBarVisibility = 'Disabled'
[Windows.Controls.Grid]::SetRow($chatScroll, 3)
$root.Children.Add($chatScroll) | Out-Null

# --- log label ---
$logHead = [Windows.Controls.TextBlock]::new()
$logHead.Text = 'ЖУРНАЛ'
$logHead.FontSize = 11
$logHead.FontWeight = [Windows.FontWeights]::Bold
$logHead.Foreground = $fgMuted
$logHead.Margin = [Windows.Thickness]::new(2, 12, 0, 6)
[Windows.Controls.Grid]::SetRow($logHead, 4)
$root.Children.Add($logHead) | Out-Null

# --- log ---
$logBorder = [Windows.Controls.Border]::new()
$logBorder.Background = Brush '#0d1016'
$logBorder.CornerRadius = [Windows.CornerRadius]::new(10)
$logBorder.Padding = [Windows.Thickness]::new(2)
[Windows.Controls.Grid]::SetRow($logBorder, 5)
$root.Children.Add($logBorder) | Out-Null

$logBox = [Windows.Controls.TextBox]::new()
$logBox.IsReadOnly = $true
$logBox.AcceptsReturn = $true
$logBox.TextWrapping = 'Wrap'
$logBox.VerticalScrollBarVisibility = 'Auto'
$logBox.HorizontalScrollBarVisibility = 'Disabled'
$logBox.Background = [Windows.Media.Brushes]::Transparent
$logBox.Foreground = Brush '#93a4bd'
$logBox.BorderThickness = [Windows.Thickness]::new(0)
$logBox.Padding = [Windows.Thickness]::new(10)
$logBox.FontFamily = [Windows.Media.FontFamily]::new('Consolas')
$logBox.FontSize = 11.5
$logBorder.Child = $logBox

# --- footer ---
$footer = [Windows.Controls.Grid]::new()
$footer.Margin = [Windows.Thickness]::new(0, 14, 0, 0)
$fc1 = [Windows.Controls.ColumnDefinition]::new()
$fc1.Width = [Windows.GridLength]::new(1, $unitStar)
$fc2 = [Windows.Controls.ColumnDefinition]::new()
$fc2.Width = [Windows.GridLength]::new(1, $unitAuto)
$fc3 = [Windows.Controls.ColumnDefinition]::new()
$fc3.Width = [Windows.GridLength]::new(1, $unitAuto)
$footer.ColumnDefinitions.Add($fc1) | Out-Null
$footer.ColumnDefinitions.Add($fc2) | Out-Null
$footer.ColumnDefinitions.Add($fc3) | Out-Null

$mainBtn = New-FlatButton -Text 'ОСТАНОВИТЬ' -Background $red -Foreground ([Windows.Media.Brushes]::White)
[Windows.Controls.Grid]::SetColumn($mainBtn, 0)
$footer.Children.Add($mainBtn) | Out-Null

$clearBtn = New-FlatButton -Text 'Очистить' -Background (Brush '#232936') -Foreground $fgMuted -Width 96
$clearBtn.Margin = [Windows.Thickness]::new(10, 0, 0, 0)
[Windows.Controls.Grid]::SetColumn($clearBtn, 1)
$footer.Children.Add($clearBtn) | Out-Null

$closeBtn = New-FlatButton -Text '✕' -Background (Brush '#232936') -Foreground $fgMuted -Width 46
$closeBtn.Margin = [Windows.Thickness]::new(10, 0, 0, 0)
[Windows.Controls.Grid]::SetColumn($closeBtn, 2)
$footer.Children.Add($closeBtn) | Out-Null

[Windows.Controls.Grid]::SetRow($footer, 6)
$root.Children.Add($footer) | Out-Null

$window.Content = $root

# ------------------------------------------------------------- behaviour ----

function Update-ToggleVisual {
    if ($state.Stop) {
        $mainBtn.Background = $green
        $mainBtn.Child.Text = 'ЗАПУСТИТЬ'
        $mainBtn.ToolTip = 'Возобновить автопродолжение'
        $pillLbl.Text = 'ОСТАНОВЛЕНО'
        $pillLbl.Foreground = $amber
        $pill.BorderBrush = $amber
        $pill.BorderThickness = [Windows.Thickness]::new(1)
    }
    else {
        $mainBtn.Background = $red
        $mainBtn.Child.Text = 'ОСТАНОВИТЬ'
        $mainBtn.ToolTip = 'Остановить автопродолжение'
        $pillLbl.Text = 'РАБОТАЕТ'
        $pillLbl.Foreground = $green
        $pill.BorderThickness = [Windows.Thickness]::new(0)
    }

    if ($script:TrayIcon) {
        try {
            $script:TrayIcon.Text = if ($state.Stop) { 'OpenCode AutoContinue — остановлено' } else { 'OpenCode AutoContinue — работает' }
            $script:TrayToggle.Text = if ($state.Stop) { 'Запустить' } else { 'Остановить' }
        }
        catch { }
    }
}

function Toggle-Run {
    $state.Stop = -not $state.Stop
    if ($state.Stop) {
        $state.Log.Enqueue("$((Get-Date).ToString('HH:mm:ss'))  ⏸ Пауза — скрипт остановлен")
    }
    else {
        $state.Log.Enqueue("$((Get-Date).ToString('HH:mm:ss'))  ▶ Скрипт запущен")
    }
    Update-ToggleVisual
}

function Add-LogLine([string]$line) {
    if ($script:LogCount -gt 350) {
        $logBox.Clear()
        $script:LogCount = 0
    }
    $logBox.AppendText($line + "`r`n")
    $script:LogCount++
    $logBox.ScrollToEnd()
}

$script:LogCount = 0
$script:RowRefs = @{}
$script:LastSig = ''

function Build-ChatRows {
    $chatPanel.Children.Clear()
    $script:RowRefs = @{}

    foreach ($chat in $state.Chats) {
        $row = [Windows.Controls.Border]::new()
        $row.Background = $panelBg
        $row.CornerRadius = [Windows.CornerRadius]::new(12)
        $row.Padding = [Windows.Thickness]::new(14, 7, 10, 7)
        $row.Margin = [Windows.Thickness]::new(0, 0, 0, 5)

        $grid = [Windows.Controls.Grid]::new()
        $c1 = [Windows.Controls.ColumnDefinition]::new()
        $c1.Width = [Windows.GridLength]::new(1, $unitStar)
        $c2 = [Windows.Controls.ColumnDefinition]::new()
        $c2.Width = [Windows.GridLength]::new(1, $unitAuto)
        $c3 = [Windows.Controls.ColumnDefinition]::new()
        $c3.Width = [Windows.GridLength]::new(1, $unitAuto)
        $grid.ColumnDefinitions.Add($c1) | Out-Null
        $grid.ColumnDefinitions.Add($c2) | Out-Null
        $grid.ColumnDefinitions.Add($c3) | Out-Null

        $left = [Windows.Controls.StackPanel]::new()
        $nameTb = [Windows.Controls.TextBlock]::new()
        $nameTb.Text = if ($chat.Title) { $chat.Title } else { '(без названия)' }
        $nameTb.FontSize = 15
        $nameTb.FontWeight = [Windows.FontWeights]::SemiBold
        $nameTb.Foreground = $fgMain
        $nameTb.TextTrimming = 'CharacterEllipsis'
        $statusTb = [Windows.Controls.TextBlock]::new()
        $statusTb.Text = [string]$chat.Status
        $statusTb.FontSize = 11.5
        $statusTb.Margin = [Windows.Thickness]::new(0, 2, 0, 0)
        $statusTb.Foreground = $fgMuted
        $left.Children.Add($nameTb) | Out-Null
        $left.Children.Add($statusTb) | Out-Null
        [Windows.Controls.Grid]::SetColumn($left, 0)
        $grid.Children.Add($left) | Out-Null

        $countTb = [Windows.Controls.TextBlock]::new()
        $countTb.Text = [string]$chat.Count
        $countTb.FontSize = 18
        $countTb.FontWeight = [Windows.FontWeights]::Bold
        $countTb.Foreground = $blue
        $countTb.VerticalAlignment = 'Center'
        $countTb.Margin = [Windows.Thickness]::new(0, 0, 12, 0)
        [Windows.Controls.Grid]::SetColumn($countTb, 1)
        $grid.Children.Add($countTb) | Out-Null

        $rm = [Windows.Controls.Border]::new()
        $rm.Width = 26
        $rm.Height = 26
        $rm.CornerRadius = [Windows.CornerRadius]::new(7)
        $rm.Background = Brush '#232936'
        $rm.Cursor = [Windows.Input.Cursors]::Hand
        $rm.VerticalAlignment = 'Center'
        $rm.ToolTip = 'Убрать чат из списка (и не добавлять автоматически)'
        $x = [Windows.Controls.TextBlock]::new()
        $x.Text = '✕'
        $x.FontSize = 11
        $x.Foreground = $fgMuted
        $x.HorizontalAlignment = 'Center'
        $x.VerticalAlignment = 'Center'
        $rm.Child = $x
        $rm.Tag = $chat.Id
        $rm.Add_MouseLeftButtonUp({ Remove-ChatFromUi $this.Tag })
        $rm.Add_MouseEnter({ $this.Background = Brush '#3a2530' })
        $rm.Add_MouseLeave({ $this.Background = Brush '#232936' })
        [Windows.Controls.Grid]::SetColumn($rm, 2)
        $grid.Children.Add($rm) | Out-Null

        $row.Child = $grid
        $chatPanel.Children.Add($row) | Out-Null
        $script:RowRefs[$chat.Id] = @{ Status = $statusTb; Count = $countTb; Title = $nameTb }
    }

    if ($state.Chats.Count -eq 0) {
        $empty = [Windows.Controls.TextBlock]::new()
        $empty.Text = 'Пока пусто. Включите авто-добавление или нажмите «+ Добавить».'
        $empty.FontSize = 12
        $empty.Margin = [Windows.Thickness]::new(4, 6, 0, 10)
        $empty.Foreground = $fgMuted
        $chatPanel.Children.Add($empty) | Out-Null
    }
}

function Remove-ChatFromUi([string]$id) {
    if (-not $id) { return }
    $state.RemoveQueue.Enqueue($id)
    $state.Ignored[$id] = $true
    $script:Dirty = $true
}

# --- диалог добавления чата ---
$script:AddCandidates = @()

function Show-AddDialog {
    try { $r = Invoke-OcApi 'GET' '/api/session?limit=100' } catch {
        [void][Windows.MessageBox]::Show('Не удалось получить список чатов: ' + $_.Exception.Message, 'Ошибка', 'OK', 'Warning')
        return
    }
    $list = @($r.data | Where-Object { -not $_.parentID })

    $dlg = [Windows.Window]::new()
    $dlg.Title = 'Добавить чат'
    $dlg.Width = 520
    $dlg.Height = 480
    $dlg.Owner = $window
    $dlg.WindowStartupLocation = 'CenterOwner'
    $dlg.Background = $bg
    $dlg.Foreground = $fgMain
    $dlg.FontFamily = [Windows.Media.FontFamily]::new('Segoe UI')

    $dg = [Windows.Controls.Grid]::new()
    $dg.Margin = [Windows.Thickness]::new(16)
    foreach ($h in @($unitAuto, $unitStar, $unitAuto)) {
        $rd = [Windows.Controls.RowDefinition]::new()
        $rd.Height = [Windows.GridLength]::new(1, $h)
        $dg.RowDefinitions.Add($rd) | Out-Null
    }

    $lbl = [Windows.Controls.TextBlock]::new()
    $lbl.Text = 'Выберите чат (последние 100 сессий):'
    $lbl.FontSize = 12
    $lbl.Foreground = $fgMuted
    $dg.Children.Add($lbl) | Out-Null

    $lb = [Windows.Controls.ListBox]::new()
    $lb.Background = Brush '#0f131a'
    $lb.Foreground = $fgMain
    $lb.BorderThickness = [Windows.Thickness]::new(1)
    $lb.BorderBrush = Brush '#2a3140'
    $lb.Margin = [Windows.Thickness]::new(0, 10, 0, 0)
    $lb.FontSize = 12.5
    [Windows.Controls.Grid]::SetRow($lb, 1)
    $dg.Children.Add($lb) | Out-Null

    $script:AddCandidates = @()
    foreach ($s in $list) {
        $t = [string]$s.title
        if (-not $t) { $t = '(без названия)' }
        $when = ''
        try { $when = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$s.time.updated).LocalDateTime.ToString('dd.MM HH:mm') } catch { }
        $idx = $lb.Items.Add("$t    ·    $when    ·    $($s.id)")
        $script:AddCandidates += , @{ Id = $s.id; Title = [string]$s.title; Index = $idx }
    }

    $btns = [Windows.Controls.StackPanel]::new()
    $btns.Orientation = 'Horizontal'
    $btns.HorizontalAlignment = 'Right'
    $btns.Margin = [Windows.Thickness]::new(0, 12, 0, 0)
    [Windows.Controls.Grid]::SetRow($btns, 2)
    $dg.Children.Add($btns) | Out-Null

    $ok = New-FlatButton -Text 'Добавить' -Background $blue -Foreground ([Windows.Media.Brushes]::White) -Height 38 -Width 120
    $cancel = New-FlatButton -Text 'Отмена' -Background (Brush '#232936') -Foreground $fgMuted -Height 38 -Width 96
    $cancel.Margin = [Windows.Thickness]::new(8, 0, 0, 0)
    $btns.Children.Add($cancel) | Out-Null
    $btns.Children.Add($ok) | Out-Null

    $cancel.Add_MouseLeftButtonUp({ $dlg.Close() })
    $ok.Add_MouseLeftButtonUp({
        $sel = $lb.SelectedIndex
        if ($sel -lt 0) { return }
        $cand = $script:AddCandidates[$sel]
        $state.AddQueue.Enqueue(@{ Id = [string]$cand.Id; Title = [string]$cand.Title })
        $state.Ignored.Remove([string]$cand.Id)
        $script:Dirty = $true
        $dlg.Close()
    })

    $dlg.Content = $dg
    [void]$dlg.ShowDialog()
}

# --- таймер интерфейса ---
$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
    $drained = 0
    $lines = @()
    while ($drained -lt 40) {
        $line = $null
        if (-not $state.Log.TryDequeue([ref]$line)) { break }
        $lines += $line
        $drained++
    }
    foreach ($line in $lines) {
        Add-LogLine $line
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
    }

    $sig = (@($state.Chats | ForEach-Object { $_.Id }) -join '|')
    if ($sig -ne $script:LastSig) {
        $script:LastSig = $sig
        Build-ChatRows
        $script:Dirty = $true
    }

    foreach ($chat in $state.Chats) {
        $ref = $script:RowRefs[$chat.Id]
        if (-not $ref) { continue }
        if ($ref.Status.Text -ne [string]$chat.Status) { $ref.Status.Text = [string]$chat.Status }
        $cnt = [string]$chat.Count
        if ($ref.Count.Text -ne $cnt) { $ref.Count.Text = $cnt }

        switch ($chat.Phase) {
            'running' { $ref.Status.Foreground = $amber }
            'sent' { $ref.Status.Foreground = $blue }
            { $_ -eq 'waiting' -and $chat.Status -like 'ответ получен*' } { $ref.Status.Foreground = $green }
            default { $ref.Status.Foreground = $fgMuted }
        }
    }

    Update-ToggleVisual

    if ($script:Dirty) {
        Save-Settings
    }
})
$timer.Start()

$msgBox.Add_TextChanged({
    $state.Message = $msgBox.Text
    $script:Dirty = $true
})
$autoChk.Add_Click({
    $state.AutoAdd = [bool]$autoChk.IsChecked
    $state.Log.Enqueue("$((Get-Date).ToString('HH:mm:ss'))  Авто-добавление: $(if ($state.AutoAdd) { 'вкл' } else { 'выкл' })")
    $script:Dirty = $true
})
$addBtn.Add_MouseLeftButtonUp({ Show-AddDialog })
$addBtn.Add_MouseEnter({ $this.Background = Brush '#2c3444' })
$addBtn.Add_MouseLeave({ $this.Background = Brush '#232936' })

$mainBtn.Add_MouseLeftButtonUp({ Toggle-Run })
$mainBtn.Add_MouseEnter({ if ($state.Stop) { $this.Background = Brush '#2ee06b' } else { $this.Background = Brush '#ff5a5a' } })
$mainBtn.Add_MouseLeave({ Update-ToggleVisual })

$clearBtn.Add_MouseLeftButtonUp({
    $logBox.Clear()
    $script:LogCount = 0
})
$clearBtn.Add_MouseEnter({ $this.Background = Brush '#2c3444' })
$clearBtn.Add_MouseLeave({ $this.Background = Brush '#232936' })

$closeBtn.Add_MouseLeftButtonUp({ $window.Close() })
$closeBtn.Add_MouseEnter({ $this.Background = Brush '#2c3444' })
$closeBtn.Add_MouseLeave({ $this.Background = Brush '#232936' })

$window.Add_Loaded({
    $wa = [Windows.SystemParameters]::WorkArea
    if ($window.Width -gt $wa.Width) { $window.Width = $wa.Width - 40 }
    if ($window.Height -gt $wa.Height) { $window.Height = $wa.Height - 40 }
    $window.Left = $wa.Left + [Math]::Max(0, ($wa.Width - $window.ActualWidth) / 2)
    $window.Top = $wa.Top + [Math]::Max(0, ($wa.Height - $window.ActualHeight) / 2)
    $window.Activate()
})

$window.Add_Closed({
    $state.Stop = $true
    $timer.Stop()
    if ($script:TrayIcon) {
        try { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() } catch { }
    }
})

# --- значок в трее ---
$script:TrayIcon = $null
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $trayIcon = New-Object System.Windows.Forms.NotifyIcon
    $trayIcon.Icon = [System.Drawing.SystemIcons]::Application
    $trayIcon.Text = 'OpenCode AutoContinue — работает'
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

Build-ChatRows
$script:LastSig = (@($state.Chats | ForEach-Object { $_.Id }) -join '|')
Update-ToggleVisual
Add-LogLine ("{0}  Окно запущено. Поток: {1}" -f (Get-Date -Format 'HH:mm:ss'), $state.PollMs)

[void]$window.ShowDialog()

# ---------------------------------------------------------------- cleanup ----

$state.Stop = $true
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
