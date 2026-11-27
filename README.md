# Voilà

*Start, focus, finish… voilà.*

A native macOS floating panel for your **Google Tasks**: always on top, with start / pause / resume time tracking and a live progress ring against your estimate. It also shows the day's meetings from your **Google Calendar** and brings up a card with a Join button when one starts.

## Features

- **Always on top**: a floating panel visible on every Space and over full-screen apps. Drag it anywhere; it remembers its position and size.
- **Standard macOS window**: real traffic lights, so you get the usual close, minimize (⌘M), zoom and the green button's tiling menu, plus a **Window** menu (Close ⌘W, Minimize, Zoom, Show Voilà ⌘0, Compact ⌘⇧C). Closing hides the panel but Voilà keeps running and timers keep counting. Click the **Dock icon** or the menu bar icon to bring it back. Voilà also shows in the Dock and ⌘-Tab.
- **Compact pill**: collapse to a slim pill showing the running task, a large live timer, a breathing focus dot and a progress line along the bottom edge (raspberry once over the estimate); it keeps the panel's width (⤡ or ⌘⇧C to switch). Starting a task collapses to the pill automatically; pausing it expands back to the full panel.
- **Focus card**: start a task (▶). The card shows a live clock and a ring filling toward your estimate, with an orange overtime arc and a `+12m` chip once you go over.
- **One task at a time**: starting a task pauses the running one. Paused tasks keep their time, so you can resume until done.
- **Complete with a flourish**: click the circle and you get a gradient check, a burst of particles and a *« Voilà ! »* badge. "Today" progress is shown at the top.
- **Now / Later**: **Now** is what you're actively working on: you choose it, and it has nothing to do with due dates. Below it, a collapsed **Later** section holds everything else; click it to expand inline. If Later contains tasks due today or overdue, its header shows a red "N due" hint. Now is saved as a small `now` flag in Voilà's notes line (e.g. `⏱ 24m / 1h · now`), so it syncs across Macs. **Completed** is pinned to the bottom edge of the window (next to the + button); click it to reveal recently completed tasks just above. Each row starts with ▶ (click to start; starting a Later task moves it into Now; the running task shows ⚡ and pauses on click). Hover a Later task for ☀︎ Now; hover any task for a green ✓ to complete it (completing removes it from Now). To send a Now task back to Later, drag it onto Later or right-click → Move to Later. You can also drag a task between Now and Later. New tasks go to Later. The Now header shows how many tasks are in Now and, once you finish some, "✓ N done today". The pill and "Up next" use Now.
- **Today view** (calendar button in the header): today's meetings from your Google Calendar sit above your tasks, in time order, with their duration, whether they are internal or external, where they happen and who is in them. The meeting that is on is highlighted with the minutes left; a "now" line between meetings tells you how long you are free; past meetings are dimmed, and meetings you declined are hidden (see Meetings settings below). A **Today | Tomorrow** switch in the agenda header shows tomorrow's meetings. A **Join** button appears from 10 minutes before the start. Click a meeting to open its card.
- **Meeting card**: when a meeting starts (or a few minutes before, see Meetings settings), a card appears on the monitor where your mouse pointer is, above everything including full-screen apps. It shows the title and time, whether the meeting is **Internal** or **External** (guests from another email domain than yours, which is named), who accepted, said maybe, declined or hasn't replied (in an external meeting, your colleagues and the outside guests are listed in two separate boxes), and the topics (the invite's description and attachments, without the dial-in boilerplate). **Join** opens Zoom or Microsoft Teams directly in their apps and Google Meet, Webex or any other link in your browser; **Close** (Esc) dismisses it, and it goes away by itself when the meeting ends. The card never takes keyboard focus, so it can't swallow what you are typing. Meetings that start at the same time share one card, side by side, each with its own Join button. No card for all-day events, meetings you declined, or events with nobody but you.
- **Meetings settings** (⋯ menu or menu bar icon → **Meetings**): **Show Meeting Card** at start time, 1, 2, 5 or 10 minutes before, or never; and whether to show meetings you haven't answered, answered Maybe, or declined. A hidden meeting is ignored everywhere (list, card, menu bar countdown). Declined meetings, when shown, are struck through and still get no card or countdown.
- **Prep notes**: an event whose title starts with "Prep" and that starts at the same time as a meeting is treated as your preparation for it. Its description becomes the meeting's topics (above the invite's own text) and the Prep event itself is not shown. If several meetings start then, the one named in the Prep title is used.
- **Switchable lists**: click the list title.
- **Due dates**: Today / Tomorrow / Next Week / pick a date. Badges show overdue, today and tomorrow.
- **Quick-add shortcuts**: `Write memo ~45m !tomorrow` (`~` sets the estimate; `!today`, `!tomorrow`, `!week` or `!2026-10-20` set the due date).
- **Reorder**: drag a task onto another to drop it just above, or below the last task to send it to the end. Dropping onto a subtask nests it under the same parent. Right-click also offers **Move to Top / Up / Down**. Order syncs to Google Tasks.
- **Click a task title**: a popover to set the estimate in one click (10m to 4h chips, or type a custom value like `1h20`), pick the **due date** (Today, Tomorrow, the next weekdays, Next week, In 2 weeks, or any date from a calendar; **Remove** clears it), rename the task, or reset its tracked time. Due dates are shown as badges and never move tasks between Now and Later.
- **Right-click a task**: start/pause, set an estimate or due date, reset tracked time, rename, delete.
- **Appearance** (⋯ menu or menu bar icon): Match System (follows macOS light/dark, live), Light, or Dark.
- **Auto-updates** (Sparkle): Voilà checks daily for new versions and asks before installing ("Install Update" downloads, verifies and relaunches). **Check for Updates…** is in the ⋯ and menu bar menus.
- **Show in Dock** (⋯ menu or menu bar icon): turn it off to remove Voilà from the Dock and ⌘-Tab. It keeps running and stays reachable from the menu bar icon.
- **Menu bar icon** (☑︎ / ⏱ while running): show/close the panel, compact, refresh, Launch at Login, sign out. It also counts down to your meetings: a calendar with `12m` from an hour before the next one, then `23m left` while it is on, next to the running task's timer. The menu shows the current or next meeting with a Join shortcut.

### Where the data lives

Everything is in Google Tasks. Time tracking is a single line appended to the task's notes, so it syncs across devices and survives reinstalls:

```
⏱ 42m10s / 1h ▶ 2026-10-03T16:02:11Z
```

`42m10s` is the time spent, `1h` is the estimate, and `▶ <time>` means the timer is running since that time. A timer keeps running even if you quit the app or close your laptop. The app syncs every 60 s, on wake (retrying quietly until the network is back), and on every action.

## 1. Create your Google OAuth client (~5 min, one time)

1. Go to <https://console.cloud.google.com/> and create a project (e.g. "Voila").
2. **APIs & Services → Library**: search **Google Tasks API** and click **Enable**, then do the same for **Google Calendar API** (for the Today view and meeting cards).
3. **APIs & Services → OAuth consent screen** (or "Google Auth Platform"):
   - User type **External**, app name "Voilà", your email as support/developer contact.
   - **Audience / Test users**: add your own Gmail address.
   - Scopes: you can skip this; the app requests `.../auth/tasks` and `.../auth/calendar.events.readonly` (read-only) itself.
4. **APIs & Services → Credentials → Create credentials → OAuth client ID**:
   - Application type: **Desktop app**, name "Voilà Mac".
   - Copy the **Client ID** and **Client secret**.
5. Launch Voilà, paste both and click **Connect Google Account**. Your browser opens: pick your account and accept. You'll see "Unverified app" because it's your own app in testing mode. Click *Continue*.

> **Which Google account should own the project?** It only *hosts* the OAuth client; every user signs in with their own account and sees their own tasks.
> - **Only ThoughtSpot colleagues**: create it with your Workspace account and choose user type **Internal**. No unverified-app warning, no 7-day expiry, no user cap. Your IT admin may need to allow it.
> - **Anyone**: create it with a dedicated Gmail account (easier to hand over or share ownership via IAM), user type **External**.
>
> In "Testing" status, Google expires refresh tokens after 7 days, so you'd need to reconnect weekly. Set the publishing status to **In production** to avoid that. Without Google verification, an External app shows an "unverified app" warning and is capped at 100 users in total, because the Tasks and Calendar scopes are *sensitive*. Beyond that, submit it for verification (homepage, privacy policy, verified domain, demo video).

The client secret and refresh token are stored in your macOS Keychain.

If you connected Voilà before it had the Today view, open it (calendar button) and click **Connect Google Calendar**: Google asks once more, now with the read-only calendar permission. Meetings come from your primary calendar and refresh every 5 minutes, and also when you open the panel, switch to the Today view, click Refresh, or wake the Mac.

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

## Release (DMG)

```bash
./scripts/release.sh
```

This produces `dist/Voila-<version>.dmg`: a universal (Apple Silicon + Intel) app signed with your Developer ID and a secure timestamp, plus a drag-to-Applications layout. The version comes from `Resources/Info.plist` (`CFBundleShortVersionString` / `CFBundleVersion`).

To share it with other Macs without Gatekeeper warnings, notarize it. Store your credentials once:

```bash
xcrun notarytool store-credentials voila-notary --apple-id <you@example.com> --team-id 8LDY3JKFJX
```

Then build with `NOTARY_PROFILE=voila-notary ./scripts/release.sh`, which notarizes and staples the DMG.

### Publishing a new version
1. Bump `CFBundleShortVersionString` (e.g. `1.2`) **and** `CFBundleVersion` (build number, always increasing) in `Resources/Info.plist`, then commit.
2. Tag and push: `git tag v1.2 && git push origin v1.2`.
3. The **Release** workflow builds, notarizes, signs the update with the `SPARKLE_PRIVATE_KEY` secret, publishes the GitHub release and adds it to `docs/appcast.xml`, the feed installed copies check for updates.

## Project layout

```
Sources/Voila/
  App/    VoilaApp.swift (entry, menu bar, AppModel), FloatingPanel.swift (always-on-top NSPanel)
  Auth/   GoogleAuth.swift (OAuth + PKCE), LoopbackServer.swift (redirect catcher), Keychain.swift
  Data/   TasksAPI.swift (REST client), TaskStore.swift (state + actions), TimeTracking.swift (notes codec)
  Views/  MainView, TaskRow, CompactPill, OnboardingView, RootView, Theme
scripts/  build.sh, release.sh, make_icon.swift
```

## License

[MIT](LICENSE) © 2026 Francois Lopitaux
