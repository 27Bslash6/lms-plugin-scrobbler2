# Last.fm Scrobbler 2.0 for Lyrion Music Server

A modern Last.fm scrobbling plugin for [Lyrion Music Server](https://lyrion.org/) (formerly Logitech Media Server / Squeezebox Server).

Replaces the built-in AudioScrobbler plugin with the [Scrobbling 2.0 API](https://www.last.fm/api/scrobbling) — HTTPS, web-based auth, proper error handling, and streaming service support.

## Why?

The built-in AudioScrobbler plugin uses the deprecated [Submissions Protocol 1.2.1](https://www.last.fm/api/submissions) from 2007:

- Sends credentials as MD5 hashes over **plain HTTP**
- Uses a legacy protocol that Last.fm could discontinue at any time
- No structured error handling or retry logic
- Breaks with streaming services like TIDAL

This plugin fixes all of that.

## Features

- **Scrobbling 2.0 API** with HTTPS everywhere
- **Web-based authentication** — no passwords stored, just session keys
- **Multi-account support** — configure multiple Last.fm accounts
- **Per-player account selection** — different players can scrobble to different accounts
- **Streaming support** — works with TIDAL, Qobuz, and other protocol handler-based services
- **Batch scrobbling** — up to 50 tracks per request
- **Persistent queue** — pending scrobbles survive server restarts
- **Smart error handling** — exponential backoff for transient errors, immediate drop for permanent failures
- **Now Playing** updates on track start

## Requirements

- Lyrion Music Server **8.3+**
- A [Last.fm API account](https://www.last.fm/api/account/create) (free)

## Installation

### From the Plugin Manager (recommended)

1. Open Lyrion **Settings** > **Plugins**
2. Scroll to the bottom and add this repository URL:

   ```
   https://raw.githubusercontent.com/27Bslash6/lms-plugin-scrobbler2/main/repo/repo.xml
   ```

3. Find **Last.fm Scrobbler 2.0** in the plugin list and click **Install**
4. Restart Lyrion when prompted

### Manual Installation

Download the latest `Scrobbler2.zip` from [Releases](https://github.com/27Bslash6/lms-plugin-scrobbler2/releases) and extract it to your Lyrion plugin directory.

## Setup

### 1. Get a Last.fm API Key

1. Go to [last.fm/api/account/create](https://www.last.fm/api/account/create)
2. Fill in any application name and description
3. Note your **API Key** and **Shared Secret**

### 2. Configure the Plugin

1. Open Lyrion **Settings** > **Plugins** > **Last.fm Scrobbler 2.0**
2. Enter your **API Key** and **API Secret**
3. Click **Apply**

### 3. Authorize Your Account

1. Click **Add Account**
2. Click the **Authorize on Last.fm** link — a new tab opens
3. Authorize the application on Last.fm
4. Return to the Lyrion settings page and click **Complete Authorization**

### 4. Assign to a Player

1. Go to **Player Settings** (select your player at the top)
2. Find **Last.fm Scrobbler 2.0** in the player settings
3. Select your Last.fm account from the dropdown
4. Click **Apply**

### 5. Disable the Built-in AudioScrobbler

If you had the built-in AudioScrobbler enabled, disable it in **Settings** > **Plugins** to avoid duplicate scrobbles.

## Scrobble Rules

Per the [Last.fm scrobbling spec](https://www.last.fm/api/scrobbling):

- Track must be longer than **30 seconds**
- Must play for at least **50% of its duration** or **4 minutes**, whichever comes first
- Skipped tracks that don't meet the threshold are not scrobbled

## Troubleshooting

### Enable Debug Logging

Add to `/config/prefs/log.conf` (or via Settings > Advanced > Logging):

```
log4perl.logger.plugin.scrobbler2 = DEBUG
```

Logs appear in `/config/logs/server.log`.

### Common Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| Plugin installed but not scrobbling | No per-player account set | Assign account in Player Settings |
| 400 Bad Request errors | Old plugin version with UTF-8 bug | Update to 1.0.4+ |
| "Session expired" warning | Last.fm session key invalidated | Re-authorize in plugin settings |
| No plugin in settings | Wrong install.xml format | Update to latest release |

## Compatibility

Tested with:

- Lyrion Music Server 9.x
- TIDAL (via lms-plugin-tidal)
- WiiM Ultra
- Local library (FLAC, MP3, etc.)

## License

GPL v2 — same as Lyrion Music Server.

## Credits

Built by [27Bslash6](https://github.com/27Bslash6).
