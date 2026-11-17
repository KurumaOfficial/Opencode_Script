# Changelog

## Unreleased

### Changed
- License changed from MIT to GPL-3.0.

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
