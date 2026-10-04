# Voilà

*Start, focus, finish… voilà.*

A native macOS floating panel for your **Google Tasks**: always on top, with start / pause / resume time tracking and a live progress ring against your estimate.

## Features

- **Always on top**: a floating panel visible on every Space and over full-screen apps. Drag it anywhere; it remembers its position and size.
- **Standard macOS window**: real traffic lights, so you get the usual close, minimize (⌘M), zoom and the green button's tiling menu, plus a **Window** menu (Close ⌘W, Minimize, Zoom, Show Voilà ⌘0, Compact ⌘⇧C). Closing hides the panel but Voilà keeps running and timers keep counting. Click the **Dock icon** or the menu bar icon to bring it back. Voilà also shows in the Dock and ⌘-Tab.
- **Compact pill**: collapse to a slim pill showing the running task, its live timer and progress (⤡ or ⌘⇧C to switch).
- **Focus card**: start a task (▶). The card shows a live clock and a ring filling toward your estimate, with an orange overtime arc and a `+12m` chip once you go over.
- **One task at a time**: starting a task pauses the running one. Paused tasks keep their time, so you can resume until done.
- **Complete with a flourish**: click the circle and you get a gradient check, a burst of particles, a sound and a *« Voilà ! »* badge. "Today" progress is shown at the top.
- **Today / Later**: the list shows **Today** (tasks due today or overdue). Below it, a collapsed **Later** section holds everything else (no date or a future date); click it to expand inline. **Completed** is pinned to the bottom edge of the window (next to the + button); click it to reveal recently completed tasks just above. Each row starts with ▶ (click to start; the running task shows ⚡ and pauses on click). Hover a task for ☾ (send to Later) or ☀︎ (pull into Today) and a green ✓ to complete it. You can also drag a task between Today and Later. New tasks go to Today. Progress, the pill and "Up next" count only Today.
- **Switchable lists**: click the list title.
- **Due dates**: Today / Tomorrow / Next Week / pick a date. Badges show overdue, today and tomorrow.
- **Quick-add shortcuts**: `Write memo ~45m !tomorrow` (`~` sets the estimate; `!today`, `!tomorrow`, `!week` or `!2026-10-20` set the due date).
- **Reorder**: drag a task onto another to drop it just above, or below the last task to send it to the end. Dropping onto a subtask nests it under the same parent. Right-click also offers **Move to Top / Up / Down**. Order syncs to Google Tasks.
- **Click a task title**: a popover to set the estimate in one click (10m to 4h chips, or type a custom value like `1h20`), pick the **day** (Today, Tomorrow, the next weekdays, Next week, Someday, or any date from a calendar), rename the task, or reset its tracked time. A task set for a future day waits in Later and shows up in Today automatically on that day.
- **Right-click a task**: start/pause, set an estimate or due date, reset tracked time, rename, delete.
- **Show in Dock** (⋯ menu or menu bar icon): turn it off to remove Voilà from the Dock and ⌘-Tab. It keeps running and stays reachable from the menu bar icon.
- **Menu bar icon** (☑︎ / ⏱ while running): show/close the panel, compact, refresh, Launch at Login, sign out.

### Where the data lives

Everything is in Google Tasks. Time tracking is a single line appended to the task's notes, so it syncs across devices and survives reinstalls:

```
⏱ 42m10s / 1h ▶ 2026-10-03T16:02:11Z
```

`42m10s` is the time spent, `1h` is the estimate, and `▶ <time>` means the timer is running since that time. A timer keeps running even if you quit the app or close your laptop. The app syncs every 60 s, on wake, and on every action.

## 1. Create your Google OAuth client (~5 min, one time)

1. Go to <https://console.cloud.google.com/> and create a project (e.g. "Voila").
2. **APIs & Services → Library**: search **Google Tasks API** and click **Enable**.
3. **APIs & Services → OAuth consent screen** (or "Google Auth Platform"):
   - User type **External**, app name "Voilà", your email as support/developer contact.
   - **Audience / Test users**: add your own Gmail address.
   - Scopes: you can skip this; the app requests `.../auth/tasks` itself.
4. **APIs & Services → Credentials → Create credentials → OAuth client ID**:
   - Application type: **Desktop app**, name "Voilà Mac".
   - Copy the **Client ID** and **Client secret**.
5. Launch Voilà, paste both and click **Connect Google Account**. Your browser opens: pick your account and accept. You'll see "Unverified app" because it's your own app in testing mode. Click *Continue*.

> **Which Google account should own the project?** It only *hosts* the OAuth client; every user signs in with their own account and sees their own tasks.
> - **Only ThoughtSpot colleagues**: create it with your Workspace account and choose user type **Internal**. No unverified-app warning, no 7-day expiry, no user cap. Your IT admin may need to allow it.
> - **Anyone**: create it with a dedicated Gmail account (easier to hand over or share ownership via IAM), user type **External**.
>
> In "Testing" status, Google expires refresh tokens after 7 days, so you'd need to reconnect weekly. Set the publishing status to **In production** to avoid that. Without Google verification, an External app shows an "unverified app" warning and is capped at 100 users in total, because the Tasks scope is *sensitive*. Beyond that, submit it for verification (homepage, privacy policy, verified domain, demo video).

The client secret and refresh token are stored in your macOS Keychain.

### Embed the client in the app (so users just click "Connect")

In **Credentials**, click the download icon (⬇) next to your Desktop OAuth client and save the file as `GoogleOAuthClient.json` in the project root (or point `GOOGLE_OAUTH_JSON=/path/to/file.json` at it). `scripts/build.sh` validates it and bundles it into `Voilà.app/Contents/Resources`. The app then skips the Client ID/secret fields entirely. The file is git-ignored, so the credentials never land in source control.

> For installed (desktop) apps, Google treats the client secret as non-confidential: it ships inside every copy of the app, and security comes from the user's own consent plus PKCE. Still, don't post it publicly, so nobody can impersonate your app's consent screen.

## 2. Build & run

Requires macOS 26+ and Xcode 26+ (Swift 6 toolchain).

```bash
./scripts/build.sh --install
```

This builds a release `Voilà.app`, signs it with your Developer ID (ad-hoc if none), installs it to `~/Applications` and launches it. Then turn on **Launch at Login** from the ⋯ menu or the menu bar icon.

For development:

```bash
swift build && VOILA_DEMO=1 .build/debug/Voila
```

`VOILA_DEMO=1` (debug builds only) shows sample tasks without a Google account.

## Project layout

```
Sources/Voila/
  App/    VoilaApp.swift (entry, menu bar, AppModel), FloatingPanel.swift (always-on-top NSPanel)
  Auth/   GoogleAuth.swift (OAuth + PKCE), LoopbackServer.swift (redirect catcher), Keychain.swift
  Data/   TasksAPI.swift (REST client), TaskStore.swift (state + actions), TimeTracking.swift (notes codec)
  Views/  MainView, TaskRow, CompactPill, OnboardingView, RootView, Theme
scripts/  build.sh, make_icon.swift
```
