# Changelog

## 1.5.0

### Added
- Tabs. Each tab is an independent task with its own message, chats, run limit and start/stop state. Tabs are created with `+` or `Ctrl+T` and switched like in a browser (`Ctrl+Tab`, `Ctrl+1` to `Ctrl+9`, mouse wheel on the strip). Rename by double click, close with `x`, middle click or `Ctrl+W`. Up to 10 tabs.
- A status dot on every tab: running, paused, limit reached, no connection.
- Closing a tab that has chats asks for confirmation in a dialog that matches the window style.
- Auto-add can be turned on for one tab at a time.

### Changed
- A session belongs to one tab only. The chat picker hides sessions tracked in any tab, and the worker refuses duplicates.
- New tabs start paused with an empty message; starting a tab with an empty message is refused with a log warning.
- A lost connection or a rejected password pauses all running tabs together and resumes them together.
- The tray menu has Stop all / Start all. The tray tooltip shows how many tabs are running.
- The log shows the tab name next to the chat name when there is more than one tab. Long messages are shortened in the log.
- Settings use format version 3. Files from 1.4 and earlier are migrated: the single task becomes the first tab.
- Default window height is 540 (a row for the tabs was added); minimum height is 480.
- License changed from MIT to GPL-3.0.

### Fixed
- After a pause, a chat that was waiting for a reply sat idle for 45 seconds before the next send. It now returns to waiting and is sent to right away if the assistant is idle. The same applies when a tab resumes after a connection loss.
- The system message boxes in the chat picker are replaced with dialogs in the application style.

## 1.4.0

### Changed
- Interface redesigned around a compact 400x520 window. The message field takes all free vertical space; chats, the run limit and one full-width start/stop button sit below it.
- The log, auto-add and always-on-top moved to a settings view (gear button in the title bar). `Esc` goes back.
- Window styling follows the OpenCode palette: `#0a0a0a`, `#141414`, accent `#fab283`, monospaced font.
- Run state is shown in the title bar instead of a header card.
- New application icon.
- Auto-add is now off by default.
- Settings use format version 2. Files from 1.3 are migrated: auto-add is switched off and the old window size (860x880) is dropped.

### Fixed
- A chat that never started responding was resent forever. The "no response" counter was cleared on every successful send, so the third-timeout pause never triggered. It is now cleared only when the assistant actually starts working.
- A single failed session lookup permanently excluded that session from auto-add. The lookup is now retried after 15 seconds.
- After a pause, the "no response" timer counted the idle time and could pause a healthy chat. The timer is now reset on resume.
- An empty message was replaced with the default one on the next start.
- Maximizing the borderless window pushed it past the screen edges. The maximize button is removed and maximizing is blocked.
- The window icon used the smallest frame of the `.ico`. The icon is now embedded in the script.

### Removed
- Maximize button, the pin button in the title bar (now "Always on top" in settings), and the header card.

## 1.3.0

### Added
- Run limits: stop after N messages or at a given time of day.
- Retries with growing delays, automatic pause after repeated errors, background reconnection.
- Log rotation at 4 MB.
- Redesigned interface and new icon.
