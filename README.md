# Switcheroo

A small native Mac menu bar app for opening links in the right browser or profile.

Click a web link in Mail, Slack, or another app, then pick a browser or profile from a horizontal strip near your pointer. Remember a choice for an exact website hostname when you want automatic routing.

## Install or update

Requires macOS 14 or later and Xcode's Swift 6 toolchain. There are no third-party package dependencies.

```sh
./scripts/install.sh
```

This one command builds, signs, installs, and opens Switcheroo. **Run the same command after changing or updating the source** to install the latest version. Your profiles, ordering, website rules, and other settings are preserved.

The installer updates an existing copy in `/Applications` or `~/Applications`. For a new install it uses `/Applications` when writable, otherwise your personal `~/Applications` folder. To choose explicitly, run `./scripts/install.sh "$HOME/Applications"`.

Updates stage and verify the new app before gracefully quitting the running copy and replacing it. If Switcheroo has pending links, finish them or approve its Quit dialog. If it stays open, the installer stops without replacing it. It never forces the app to quit, and restores the previous bundle if replacement fails. The installer does not change your default browser or login-item setting.

For a build without installing, use `./scripts/build.sh`. It produces `dist/Switcheroo.app` with an ad-hoc signature.

This is a local build, not a notarized distribution for other Macs. No account, API key, background server, or network service is needed.

## Setup

1. Open Switcheroo. Your browser profiles appear automatically, already selected. Uncheck any you don’t use; the arrows change their order.
2. If macOS needs permission, click **Connect Brave** (or Chrome/Edge), then **Allow**. The correct folder is already open; there is no path to find or type. If a browser has no profiles yet, click **Open Brave**, finish that browser’s setup, and return to Switcheroo.
3. Click **Make Switcheroo my link picker** and approve the macOS prompt. Setup closes when both HTTP and HTTPS handlers are confirmed. Click a link from another app to try it.

Everything is on one setup screen. **Set up later** skips the default-browser change; you can enable it later in **Settings → General**. Manage your profiles anytime in **Settings → Choices**. Switcheroo only reads profile names and locations, and never edits browser data. If macOS continues to block profile access, review **System Settings → Privacy & Security → Files & Folders → Switcheroo**.

Brave, Chrome, and Edge appear as individual profiles. Safari and Firefox appear as ordinary browser choices, with profile behavior managed by those browsers. Uninstalled browsers are omitted. Profiles refresh when you return to Switcheroo, receive a link, or choose **Refresh choices**.

Profile discovery uses each browser's standard data location under `~/Library/Application Support`. Custom `--user-data-dir` installations, guest/incognito modes, and browser extensions are not included in this release.

Links clicked inside a browser are normally handled by that browser and do not reach Switcheroo. Apps that explicitly launch a particular browser also bypass the system default.

## Picker controls

- Click a tile, or press `1`–`9` for the corresponding visible choice.
- Use Left/Right and Return to choose with the keyboard. The strip scrolls when needed.
- Press Space to toggle **Always use this choice for…**.
- Press `⌘C` to copy the full URL or `⌘,` for Settings.
- Escape or clicking outside cancels the current link. Other queued links remain in order.

Opening Settings from the picker preserves the pending link until Settings closes. A launch failure keeps the link available for another choice and does not save the requested rule.

## Website rules

Rules match one exact hostname, regardless of HTTP/HTTPS, port, or path. Hostnames are case-insensitive and a trailing dot is removed. `github.com` does not match `sub.github.com` or `github.com.example.org`. The original URL is passed through without removing query parameters or fragments.

Manage rules in **Website Rules**. A new rule for an existing hostname replaces it. Missing browsers or profiles return the link to the picker. Hiding a choice removes its tile but does not disable existing rules that target it.

**Pause website rules** in the menu bar makes all links show the picker until you unpause or restart Switcheroo.

## Storage and behavior

Settings, ordering, hidden choices, rules, and read-only folder bookmarks are stored locally in UserDefaults under `local.switcheroo.app`, using the `settings.v1` key. Pending URLs stay in memory and are discarded when the app exits. Quitting with unopened links requires confirmation. There is no browsing-history database or URL logging.

The app stays in the menu bar and has no periodic polling. Browser metadata is refreshed at startup, on activation, when a link arrives, and on an explicit refresh. Browser icons are cached for the session.

Chromium profile launches use `/usr/bin/open -n -a <app> --args --user-data-dir=<root> --profile-directory=<directory> -- <url>`. Arguments are passed separately without a shell. Safari and Firefox use `NSWorkspace` with an explicit destination application. A successful handoff means macOS accepted the launch request; it does not prove the website finished loading.

To stop using Switcheroo, choose your previous default browser in **System Settings → Desktop & Dock**, disable launch at login if enabled, and quit Switcheroo.
