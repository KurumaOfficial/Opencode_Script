# OpenCode AutoContinue

[English](README.md) | [Русский](README.ru.md)

![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)
![Platform: Windows 10/11](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)
![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE)

A small Windows utility that keeps [OpenCode](https://opencode.ai) sessions going. When the assistant finishes a response, the tool sends a preset message to that session, so a long task does not stall while it waits for you to type "continue".

<p>
  <img src="docs/screenshot-main.png" width="360" alt="Main window">
  <img src="docs/screenshot-settings.png" width="360" alt="Settings and log">
</p>

## What it does

OpenCode runs a local service. The tool polls that service for the list of active sessions. When a tracked session goes from working to idle, it posts your message to it. This repeats until you stop it, a limit is reached, or the connection to OpenCode is lost.

Work is split into tabs. A tab is an independent task with its own message, its own sessions, its own run limit and its own start/stop state, so unrelated jobs can run side by side without sharing anything.

The tool does not look at what the assistant wrote and cannot tell whether the task is finished. It only sends the text you set, every time.

## Features

- Tabs, like in a browser: every tab is an independent task with its own message, sessions, limit and start/stop state.
- Tracks several sessions per tab, each with its own status and send counter. A session belongs to one tab only.
- Sessions are identified by ID, so renaming a chat changes nothing.
- Optional auto-add of newly active sessions (off by default, enabled for one tab at a time).
- Run limits per tab: stop after N messages, or at a given time of day.
- Retries with growing delays on errors, pauses itself after repeated failures, and reconnects when OpenCode comes back, including after a restart on a different port.
- Tray icon and a single-instance guard.
- Log file with automatic rotation.

## Requirements

- Windows 10 or 11.
- A running OpenCode. The tool talks to its local service and does nothing without it.
- To run from source: Windows PowerShell 5.1, which ships with Windows. The prebuilt `.exe` needs nothing extra on a stock install.

## Installation

### Prebuilt executable

Download [`dist/OpenCodeAutoContinue.exe`](dist/OpenCodeAutoContinue.exe) and run it.

The binary is produced by ps2exe and is not code-signed, so some antivirus products may flag it. If that bothers you, run the script from source or build the executable yourself (see [Building](#building)).

### From source

```powershell
git clone https://github.com/KurumaOfficial/Opencode_Script.git
cd Opencode_Script
powershell -ExecutionPolicy Bypass -File AutoContinue.ps1
```

Double-clicking `Запустить.cmd` does the same without a console window.

Optional parameters when running the script:

| Parameter | Meaning |
|---|---|
| `-PollMs <n>` | Polling interval in milliseconds. Default 1200, minimum 500. |
| `-StartStopped` | Start paused. |
| `-MessageText <text>` | Message to use when there is no saved setting yet. |
| `-ChatTitles <a>,<b>` | Chats to track by exact title on the first run, before `settings.json` exists. |

## Usage

The interface is currently in Russian only. Labels are translated below.

The main window, top to bottom:

- **Tab strip.** One tab per task. The dot shows its state: green running, grey paused, amber limit reached, red no connection. See [Tabs](#tabs).
- **Message field.** The text sent after every response. Multi-line, up to 4000 characters. Changes apply immediately.
- **Chats.** Tracked sessions with a status line, a send counter and a remove button. `+ Добавить` (Add) opens a picker with the 100 most recent sessions and a search box. Removing a chat also puts it on an ignore list so auto-add will not bring it back; adding it again from the picker clears that.
- **Limit.** `Нет` (none), `Итерации` (iterations) or `До времени` (until a time). Enter a number or `HH:MM` in the field next to it. A thin progress bar shows how far the run is.
- **Large button at the bottom.** Stops and resumes the run.

The title bar shows the state of the current tab, the number of messages it has sent in this run and its run time. The gear button opens the settings view: name and auto-add of the current tab, a button to close it, always-on-top, the log, a button that hides the window to the tray, and a shortcut to the data folder. `Esc` returns to the main view. The close button exits the application; to keep it running in the background, use the tray button in settings. The tray icon menu has Show window, Stop all / Start all and Exit.

| Label | Meaning |
|---|---|
| `РАБОТАЕТ` | Running |
| `ПАУЗА` | Paused by the user |
| `ЛИМИТ` | Run limit reached |
| `НЕТ СВЯЗИ` | OpenCode is unreachable; retrying in the background |
| `ОСТАНОВИТЬ` / `ЗАПУСТИТЬ` | Stop / Start |
| `НОВЫЙ ЗАПУСК` | Start a new run after a limit was reached |
| `ПОВТОРИТЬ` | Retry the connection now |

Per-chat status text:

| Status | Meaning |
|---|---|
| `ожидание ответа` | Waiting for the assistant to start |
| `печатает…` | The assistant is responding; the tool waits |
| `ответ получен, ждём отправки` | Response finished; the message goes out on the next poll |
| `отправлено #N` | Message number N was sent; waiting for the response to start |
| `ответ не начался — повтор` | No response within 45 seconds; will send again |
| `ошибка отправки — повтор` | The server returned an error; a retry is scheduled |
| `ошибка — чат на паузе` | Five send failures in a row; the chat is paused |
| `бот не отвечает` | Three sends in a row got no response; the chat is paused |

A paused chat resumes by itself once the assistant starts working in it again.

### Tabs

Everything below the tab strip belongs to the selected tab: the message, the chats, the limit and the Start/Stop button. Switching tabs does not affect running ones, they keep working in the background.

- A new tab (`+`, `Ctrl+T`) is created paused and with an empty message. Write the message, add chats, then press Start. Starting a tab with an empty message is refused.
- A session can be in one tab only. The chat picker hides sessions that are already tracked in any tab.
- Auto-add can be turned on for one tab at a time (settings, section for the current tab). Enabling it in another tab moves it.
- Rename a tab by double-clicking it or in the settings view. Close it with the `x` on the tab, a middle click, `Ctrl+W` or the button in settings. Closing a tab that has chats asks for confirmation. At least one tab always remains; the maximum is 10.
- With many tabs the inactive ones shrink to a status dot and the strip scrolls with the mouse wheel. The full name is shown in a tooltip.
- A lost connection or a rejected password pauses every running tab; they all resume when the connection is back.

| Shortcut | Action |
|---|---|
| `Ctrl+T` | New tab |
| `Ctrl+W` | Close the current tab |
| `Ctrl+Tab`, `Ctrl+Shift+Tab` | Next, previous tab |
| `Ctrl+1` ... `Ctrl+9` | Go to tab by number |
| `Esc` | Leave the settings view |

### Limits

Each tab has its own limit and its own counter.

- **Iterations.** Counts messages sent successfully during the current run, across all chats of the tab. Pausing and resuming does not reset the counter. Pressing `НОВЫЙ ЗАПУСК` after the limit was hit does.
- **Until time.** Enter `HH:MM`. If that time has already passed today, the deadline is the same time tomorrow. The value can be changed while the tool is running.

When a limit is reached the tool pauses and sends nothing until you start it again.

### Errors and reconnection

| Situation | Behaviour |
|---|---|
| OpenCode does not respond | Logs the error once and retries after 2, 4, 8 and 16 seconds. |
| Fifth failure in a row | Pauses and checks the connection in the background: first after 8 seconds, then every 12. |
| Connection is back | After two successful responses the run resumes on its own. |
| OpenCode was restarted | Re-reads `service.json` and picks up the new address and password. |
| Sending to a chat fails | Retries after 5, 10, 20 and 40 seconds. The fifth failure pauses that chat. |
| No response within 45 seconds of a send | Sends again after a short delay. The third such timeout in a row pauses the chat. |
| HTTP 401 or 403 when sending | Pauses immediately. The service password is out of date. |
| HTTP 404 when sending | The session was deleted; the chat is removed from the list. |

Identical connection errors are logged once instead of on every attempt. Connection problems affect the whole service, so all running tabs are paused together and resumed together.

## Configuration

Settings are stored in `settings.json`. It is created on first run and rewritten by the application, so edit it only while the application is closed.

Top level:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `schema` | number | `3` | Settings format version. Written by the application. |
| `activeTab` | string | first tab | `id` of the tab that was selected on exit. |
| `tabs` | array | one tab | The tabs, in display order. |
| `ignored` | array | `[]` | Session IDs that auto-add must skip. |
| `topmost` | boolean | `true` | Keep the window above others. |
| `winWidth`, `winHeight` | number | `400`, `540` | Window size, remembered on exit. |

Each entry of `tabs`:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `id` | string | generated | Unique tab identifier. |
| `name` | string | `Задача N` | Tab title, up to 24 characters. |
| `message` | string | `Продолжай разработку` | Text sent to the chats of this tab. A new tab starts with an empty one. |
| `paused` | boolean | `false` | Whether the tab was paused by the user. It starts that way next time. |
| `autoAdd` | boolean | `false` | Pick up newly active sessions into this tab. Only one tab can have it. |
| `chats` | array | `[]` | Tracked sessions as `{ "id": "ses_...", "title": "..." }`. An entry with an empty `id` is resolved by its exact title. |
| `limitMode` | string | `none` | `none`, `count` or `time`. |
| `limitCount` | number | `50` | Message limit, 1 to 99999. |
| `limitTime` | string | `18:00` | Deadline as `HH:mm`. |

See [`settings.example.json`](settings.example.json) for a sample.

Location:

- Running from source: next to `AutoContinue.ps1`.
- Running the `.exe`: `%APPDATA%\OpenCodeAutoContinue\`. On first run the executable imports a `settings.json` found next to it, if there is one.

The log is `auto-continue.log` in the same folder. When it grows past 4 MB it is renamed to `auto-continue.log.1` and a new file is started.

Older files are migrated automatically. Versions up to 1.4 kept a single task at the top level of the file; it becomes the first tab, `Задача 1`, and the file is rewritten in the new format. From a 1.3 file auto-add is switched off and the old window size is dropped. Run counters and limit state are not saved: every tab starts a new run when the application starts, except tabs that were paused.

## How it works

The tool reads the address, password and version of the local OpenCode service from `%USERPROFILE%\.local\state\opencode\service.json`, falling back to `%LOCALAPPDATA%\opencode\service.json`. It authenticates with HTTP Basic as `opencode:<password>`.

| Request | Purpose |
|---|---|
| `GET /api/session/active` | Which sessions are working right now. |
| `GET /api/session/{id}` | Session details. Sub-agent and archived sessions are skipped. |
| `GET /api/session?limit=100` | Session list for the picker, and title lookup. |
| `POST /api/session/{id}/prompt` | Sends the message with `delivery: queue`. |

A background worker polls and sends. The window is WPF, built from XAML embedded in the script, and talks to the worker through shared state. The worker goes through the tabs one by one and treats each as a separate job; only the connection to OpenCode is shared.

## Things to know

- **Self-looping.** If auto-add is on and you are working in the very session you use to discuss this tool, that session will be picked up and continued on its own. Keep auto-add off, or remove such sessions from the list.
- **Pausing does not recall a message.** A message that was already sent stays queued in OpenCode. Pausing only stops further sends.
- **Every response costs a request.** The tool sends after each finished response and does not save tokens. Use a limit, and keep an eye on your provider's quota.
- **One instance.** Starting a second copy shows a notice instead of creating a second watcher.

## Troubleshooting

| Symptom | Cause or fix |
|---|---|
| A message says the OpenCode service was not found | OpenCode is not running, so its service file does not exist. |
| "Already running" | Look for the window in the taskbar or the icon in the tray. |
| A chat does not show up | Turn on auto-add in settings for the right tab, or add it with `+ Добавить`. If it is missing from the picker, it is already tracked in another tab. |
| The Start button does nothing | The message of that tab is empty. Write one. |
| Messages are not sent | Check the log in settings, or `auto-continue.log`. |
| It sends too often | Set an iteration limit, or raise `-PollMs` when running from source. |
| Silence after OpenCode restarted | The tool reconnects by itself. If it does not, press `ПОВТОРИТЬ`. |

## Building

```powershell
.\build.ps1
```

The script installs the `ps2exe` module for the current user if it is missing and writes `dist\OpenCodeAutoContinue.exe`. The build uses `-noConsole`, `-STA` (required by WPF) and `-DPIAware`, and embeds `app.ico` and the version information.

## Project layout

```
AutoContinue.ps1        the application (worker, WPF window, tray)
Запустить.cmd           launcher for running from source
build.ps1               builds the executable with ps2exe
app.ico                 application icon, 16 to 256 px
settings.example.json   sample settings file
dist/                   prebuilt executable
docs/                   icon and screenshots
CHANGELOG.md
LICENSE
```

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
