# Codex and Claude Notch Dashboard

<img src="CodexUsageMenuBar/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png" width="128" alt="Agent Usage app icon">

A native macOS utility that turns the display notch into a compact agent-capacity
dashboard. Its idle surface contracts to the physical camera-notch width so it
does not occupy either native menu-bar wing. Hover over the notch to reveal the
selected provider's exact monochrome logo on the left and its remaining
percentage on the right. The counters remain visible for two seconds after the
pointer leaves; click the notch or either revealed wing to open both signals
side by side.

- Remaining weekly Codex usage and its reset time.
- Claude Code **5-hour**, **Weekly**, and **Fable** allowance tabs, following the
  active Claude Code subscription automatically without making the notch larger.
- A native Claude account picker: save multiple logins, view each account's
  allowance, and **Set active…** to switch the default Claude Code subscription.
  No external cswap installation or separate web login is needed.

The app is an `LSUIElement`: it has no Dock icon and creates no legacy status
item. The expanded footer lets you choose whether Codex or Claude Code appears
in the compact state and pin the counters when you want them to remain visible.
Its optional `5m` clock toggle refreshes usage every five minutes while the app
is running; it is off by default so users can avoid the extra Codex subprocesses.
Hovering any footer control shows a short explanation above the button row.
Pinning intentionally keeps the side counters in the menu bar, so leave it off
on crowded menu bars or when a menu-bar organizer such as Ice needs that space.
Both providers remain visible in the expanded two-pane dashboard. Click
outside, press Escape, or use the Close button to collapse it. Closing returns
to the compact counters for two seconds before the idle surface contracts. The
connected surface is always black, matching the physical notch without a
separate light/dark appearance toggle.

Claude's tabs change its remaining percentage, bar, and reset time in place.
The chosen window is remembered across collapse/reopen and app restarts; when
Claude is selected for the compact notch, that counter follows the chosen tab.
Hover a tab to see its last-updated time. An amber dot flags a reported allowance
with 10% or less remaining, even when another tab is selected. Codex stays on its
weekly allowance. Missing or expired windows show **—**, never a guessed 100%.
Fable uses the provider's explicitly labeled model-scoped weekly limit; Opus,
Claude Design, and other model/surface buckets are not relabeled as Fable.

On a Mac without a notch, the same compact surface stays centered at the top of
the screen. It measures that display's menu bar and backing-pixel density, then
scales the synthetic notch's clearance, span, wings, and curves as one form.
The logo and compact counter retain native menu-bar legibility instead of
shrinking with the shell. A real MacBook notch keeps macOS's exact reported
camera-housing dimensions. The initial scope is notch-only—there is no
WidgetKit extension.

The Codex and Claude marks use the supplied monochrome PNG assets. The Codex
mark is from [Lobe Icons](https://github.com/lobehub/lobe-icons) and is bundled
under its MIT license. The provider-neutral Agent Usage app icon is original to
this project; the project is not affiliated with or endorsed by OpenAI or
Anthropic.

## Requirements

- macOS 13 or newer
- Codex installed and signed in
- Claude Code signed into a supported Claude subscription (save or import that login in Agent Usage)

The downloadable preview does not require Xcode. Building from source requires
Xcode 26.3 because the checked-in project uses the current Xcode project format.

The current bundled Codex executable is discovered automatically inside
`/Applications/ChatGPT.app/Contents/Resources/codex-cli`, with the previous
`Contents/Resources/codex` layout retained as a fallback. The resolver also checks
the app registered under bundle identifier `com.openai.codex`, user-level
Applications folders, and common `PATH` locations. For development, an exact
executable can be supplied with `CODEX_USAGE_CODEX_PATH`.

## Install

### Homebrew (recommended)

```sh
brew install --cask brian890809/brim/brim
```

Use the full name: Homebrew 7 only loads casks from taps you trust, and
installing by full name trusts this one. The app isn't notarized yet (that
needs a paid Apple Developer account), so before the first launch run:

```sh
xattr -dr com.apple.quarantine "/Applications/Agent Usage.app"
```

or open it once and choose **Open Anyway** in System Settings → Privacy &
Security. The full source is in this repo if you want to check what it does
first.

Update with `brew upgrade --cask brim`. Uninstall with
`brew uninstall --cask brim`, which keeps your settings and saved Claude
accounts; add `--zap` to remove those too. Claude Code's own `~/.claude`
folder and Keychain items are never touched.

### Manual download

Download the latest `.zip` from
[Releases](https://github.com/brian890809/codex-usage-menubar/releases), unzip
it, and move the app to `/Applications`. Because it isn't notarized, macOS
blocks the first launch. Either run:

```sh
xattr -dr com.apple.quarantine "/Applications/Agent Usage.app"
```

or try to open the app once, then go to **System Settings → Privacy &
Security** and choose **Open Anyway**. Only do this for builds downloaded from
this repository.

Share suggestions and bugs through
[Issues](https://github.com/brian890809/codex-usage-menubar/issues/new/choose).

## Build and open from source

Open `CodexUsageMenuBar.xcodeproj` in Xcode, select the **CodexUsageMenuBar**
scheme and **My Mac**, then Run. Hover over the notch to reveal the compact
counters, or click the idle notch to open the dashboard directly. The idle
notch is also exposed to VoiceOver as **Open usage dashboard**; reopening the
running app from Spotlight provides a keyboard-only way to expand it.

The same build can be produced from Terminal:

```sh
xcodebuild \
  -project CodexUsageMenuBar.xcodeproj \
  -scheme CodexUsageMenuBar \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/FinalDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build

open .build/FinalDerivedData/Build/Products/Debug/CodexUsageMenuBar.app
```

If an older build is already running, quit it from its popup before opening the
new build.

### Preview fixed percentages

To check how the notch renders a specific value (for example the wide `100%`
label) without live data, launch the app with preview arguments:

```sh
.build/FinalDerivedData/Build/Products/Debug/CodexUsageMenuBar.app/Contents/MacOS/CodexUsageMenuBar \
  -PreviewCodexPercent 100 -PreviewClaudePercent 100
```

Each argument is independent and clamps to 0–100; a provider without one keeps
its live data. In Xcode, add the same arguments under **Product → Scheme →
Edit Scheme… → Run → Arguments** instead.

## Claude accounts

Preview 12 brings cswap-style account switching directly into the notch app.
Saved logins are stored persistently in macOS Keychain. Switching
between saved accounts normally reuses their credentials rather than asking for
your Claude email and password again. Keychain authorization and revoked or
expired credentials can still require action; see the limits below.

### Quick start

1. Open the notch dashboard and click **Claude accounts** in its footer.
2. Choose **Save current login…** to save the account already signed into Claude
   Code, or **Import** an existing cswap account. Approve any macOS Keychain
   request yourself.
3. Use **Check usage** to compare saved accounts, then **Set active…** on the
   account you want. Confirm the switch; the notch follows that account.
4. Restart existing Claude Code terminal chats or the VS Code extension to pick
   up the new login. Claude Desktop and browser sessions are not switched.

To add another account without cswap, sign into that account through Claude Code
and choose **Save current login…** again. Discovery lists the default Claude Code
login and compatible cswap backups, not arbitrary browser sessions or every
historical account on the computer.

### Upgrading from Preview 11

The separate Claude web connection has been retired from the normal UI. Save or
import your Claude Code account once; no new website sign-in is required. Old web
session data is left untouched but is never used as a fallback.

### Upgrading from Preview 12 or 13

Preview 14 moves saved logins to system-helper-backed Keychain storage so app
updates no longer change the Keychain client. Existing saved accounts require a
one-time migration: open **Claude accounts → Allow active account…** and approve
the macOS request yourself. Inactive accounts migrate when you explicitly choose
**Set active…**. Original entries remain available for rollback. Accounts already
migrated by the local test build do not need to be saved again.

The broad **Unlock saved logins** action is replaced with account-specific
authorization. See the persistence section below for the system-tool trust
tradeoff and remaining Keychain/token-expiry limitations.

### Usage and switching behavior

Open **Claude accounts** in the dashboard footer, then **Save current login…**
or **Import** an existing cswap subscription. The notch automatically follows
the default Claude Code account. There is no separate web sign-in or source
selector. The active account's email is shown in the dashboard; 8% used in Claude
Code is 92% remaining here. Importing the active account is sufficient—there is
no second "Follow" action.

An account must be saved/imported before its usage can be read. If the default
login changes to an unsaved account, the notch shows setup guidance, not another
account's usage. Old web-session preferences are ignored; existing browser data
is left untouched and is not used as fallback. Existing terminal chats can keep
their previous identity until restarted.

The app fetches on launch and when the dashboard opens (at most once a minute);
the optional **5m** control refreshes both providers every five minutes.

The **Claude accounts** window can manage the default Claude Code subscription
without installing or executing cswap, Python, uv, or a shell wrapper. Codex
authentication is unchanged.

- **Save current login…**: sign in through Claude Code, then explicitly authorize
  importing that login. The account is verified before it is saved.
- **Import**: copy one saved cswap subscription into Agent Usage's own Keychain.
  Source files and the active Claude Code login stay untouched. Entries without
  a valid subscription identity remain visible with recovery instructions;
  API-key accounts are not treated as subscriptions.
- **Check usage**: check each imported account's five-hour allowance. Credentials
  stay in the app's Keychain; metadata and percentages are the only UI data.
- **Set active…**: confirm a default-login switch. The app verifies the target,
  backs up the current login, preserves Claude Code project/settings data and
  shared MCP credentials, takes Claude Code's advisory locks, and reads back the
  result. Failed switches roll back; an interrupted rollback requires explicit
  **Restore previous login**. Recovery refuses to overwrite a newer external login.
- The **Active** badge, notch account label, and usage source refer to the same
  default Claude Code subscription, with identity checked before and after each
  usage fetch. No web account is substituted if that request fails.

### Credential persistence and limitations

Agent Usage now uses Apple's `/usr/bin/security` helper for its persistent
Keychain storage, without a cswap/Python dependency or paid signing membership.
The helper remains the Keychain client when the notch app is rebuilt. This
authorizes the system tool rather than granting access exclusively to Agent
Usage; other programs running as your user can invoke that same tool.

An existing account needs one explicit migration through **Allow active
account…** (or **Set active** for an inactive account). It reads only that
account's old item with your permission, writes and verifies the new helper-owned
copy, and retains the old item. It never migrates all saved accounts on startup.
**Save current login…** reads the Claude Code source item; migrate an existing
saved copy first to avoid chaining separate authorization requests.

Secrets go through private process pipes, never shell interpolation, logs,
command-line arguments, or plaintext fallback files. Large app-owned values are
split into encrypted Keychain items with a verified manifest committed last.
The helper's stdin command limit is checked before writing. Oversized **live
Claude Code** credentials are rejected before replacing the login; they are not
silently truncated or exposed via an argv fallback.

Before background helper access, a metadata-only check requires an unlocked
login Keychain and existing authorization for `/usr/bin/security`, including its
Keychain partition. Unknown/denied states stop without launching the helper.
The CLI has no public per-call "never prompt" flag: a lock/permission change
between that check and access can still cause a prompt. Calls are bounded and
a failed helper request is not automatically retried for that item in the same
process. Explicit authorization can retry. Legacy migration reads retain both
the Security.framework query-level and process-level interaction guards.

Healthy background checks use only Agent Usage's own saved items. If an
already-saved active account's token expires or receives HTTP 401, the app
attempts one guarded sync of Claude Code's refreshed credential. The
app verifies the credential's account and organization, then rechecks the active
login under Claude Code's advisory locks before updating its own saved copy.
It never imports a different account, writes Claude Code's login, or renews a
shared token during background checks.
Migrating an old app-owned item can require approval because its original app
identity differs from the current build. Normal reads after migration use the
system helper instead of depending on each new app binary's signature.

For this first version, an expired inactive login renews only during an explicit
switch. Once Keychain access is authorized, automatic sync picks up credentials
already refreshed by Claude Code for the active account; repeated **Save current
login…** actions are not needed for ordinary token refreshes. No automatic
rotation or background OAuth renewal is enabled. If Claude Code has not refreshed
its own login yet, the app asks you to open Claude Code, then refresh usage.
If the preflight check blocks the read, the app instead asks for explicit
**Save current login…** authorization without launching the helper. The
lock/permission race described above still applies after a successful preflight.
The notch and saved-account row clear unavailable percentages. If Claude Code
itself is signed out, sign in there first. This version does not promise
unattended credential renewal or eliminate all future authorization prompts.
If a saved refresh credential is revoked or
no longer accepted, sign into that account through Claude Code and save it again.
Stop other account switchers and isolated sessions using the target account
before switching: multiple owners can invalidate one another's refresh
tokens. Already-running chats/VS Code may need restarting; separate
`CLAUDE_CONFIG_DIR` sessions, Claude Desktop, and browser logins are unaffected.

This preview fails closed for custom config directories, a credentials-file
fallback, API-key overrides, incompatible managed login settings, or an
unverifiable identity. It never edits Keychain permissions or falls back to
unencrypted credential storage. Nonsecret metadata and the recovery marker use
user-only files in `~/Library/Application Support/com.bchen.CodexUsageMenuBar/ClaudeAccounts`.
Rollback secrets are stored in the app's Keychain, not in those files.

### Stable signing for subsequent builds

Certificate signing is optional for local helper-backed persistence; it does
not replace testing actual Keychain access. For certificate-signed builds,
`scripts/sign-app.sh` refuses ad-hoc fallback. Set
`AGENT_USAGE_SIGNING_IDENTITY` to the existing identity's 40-character SHA-1
fingerprint, or store that fingerprint alone in the ignored
`.local-signing-identity` file for local builds. This file contains no private
key. Use `zsh scripts/sign-app.sh '/path/to/Agent Usage.app' local` after building.
Keep the bundle identifier and signing channel stable. Do not delete/recreate
Keychain entries or weaken their access controls to suppress prompts.

**A self-signed certificate alone is not a proven persistence fix.** On the
tested macOS 15.6.1 machine, two binaries signed with the same `Agent Usage Local`
certificate had identical designated requirements, but the second binary was
denied access to the first binary's synthetic Keychain item (`errSecAuthFailed`,
-25293). The system log showed a `cdhash`-based ACL partition mismatch. A fresh
launch of the original binary passed. Consequently, this local certificate is
not sufficient to promise prompt-free updates, and the installed app has not
been migrated to it. No existing login ACL or system trust setting was changed.
See Apple's [Keychain partition identity implementation](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp)
for the separate binary-hash fallback; a stable designated requirement alone
does not test that gate.

`scripts/package-preview.sh` uses a configured **Developer ID Application**
identity via `AGENT_USAGE_SIGNING_IDENTITY`, or explicitly reports an unnotarized,
ad-hoc-signed test preview when none is configured. The system-helper storage
does not depend on that choice. Notarization remains a separate release step.

The opt-in `tests/KeychainPersistenceProbe.swift` integration fixture exercises
two certificate-signed binaries with different contents and the same signing
requirement. It creates, reads, and removes only a UUID-scoped synthetic item;
it never reads actual Claude credentials or permits interactive Keychain UI.
Passing it verifies cross-build Keychain access, not the authorization state of
existing user logins or an overnight token refresh.

`tests/SystemKeychainPersistenceProbe.swift` instead compiles the production
system-helper storage code into two different binaries. On macOS 15.6.1 it
passed create, separate-process read, different-build read/update, and read-back
from the original build with a 10 KB synthetic value. The test item was removed.
This tests process restarts and a changed binary, not a Mac reboot, overnight
refresh, or user approval of existing real-account migration. Separately, after
the user approved a real account's migration, quitting and relaunching the local
app loaded that account's usage without another Save action or password prompt.

The OAuth profile/usage endpoints and cswap file format are compatibility
interfaces, not stable provider APIs. Adapted conventions are credited under
`ClaudeSwap-LICENSE.txt`. Unit tests use synthetic credentials and injected
Keychain/network implementations; no test switches a real subscription.

### Legacy status-line bridge

The bundled capture script remains available for offline development and
testing; it is no longer required by the normal app. To use it, add this entry to
`~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/bin/zsh '/Applications/Agent Usage.app/Contents/Resources/ClaudeContextCapture.sh'"
  }
}
```

For a local source build, replace the command with the script at:

```text
.build/FinalDerivedData/Build/Products/Debug/CodexUsageMenuBar.app/Contents/Resources/ClaudeContextCapture.sh
```

Claude Code reloads settings automatically and updates the counter after the
next API response. The `rate_limits` fields are available for Claude.ai Pro and
Max subscribers; when several sessions are running, any of them can refresh the
same account-level allowance.

## Test

Run the deterministic suite with:

```sh
xcodebuild \
  -project CodexUsageMenuBar.xcodeproj \
  -scheme CodexUsageMenuBar \
  -destination 'platform=macOS' \
  -derivedDataPath .build/FinalDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

The browser-request contract has a separate offline test suite (Node.js is only
a development dependency, not required to build or run the app):

```sh
node --test tests/claude-web-usage.test.mjs
```

The installed-Codex integration check stays opt-in so normal tests do not depend
on a local sign-in. Run it explicitly with:

```sh
xcodebuild \
  -project CodexUsageMenuBar.xcodeproj \
  -scheme CodexUsageMenuBarLive \
  -destination 'platform=macOS' \
  -derivedDataPath .build/FinalDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:CodexUsageMenuBarTests/CodexAppServerAdapterTests/testLiveInstalledCodexWhenRequested \
  test
```

## How Codex usage is read

`CodexAppServerAdapter` launches the resolved executable directly with
`app-server --stdio`, completes the newline-delimited initialization handshake,
and makes one `account/rateLimits/read` request. Each refresh uses a fresh child
process and closes its input after receiving the matching response.

The app decodes only the rate-limit fields it needs. It prefers the `codex`
entry in `rateLimitsByLimitId`, falls back to the legacy `rateLimits` snapshot,
and identifies the weekly window by duration rather than assuming it is always
in `primary` or `secondary`. The app refreshes Codex at launch, again when the
current snapshot is at least one minute old as the dashboard opens, immediately
when the Refresh button is used, or every five minutes when the opt-in `5m`
clock toggle is enabled. An automatic tick skips the Codex subprocess when a
newer manual snapshot exists.

The adapter does not read Codex configuration, auth files, Keychain items, or
environment credentials. It passes no tokens and stores no raw protocol output.
Codex itself uses the user's existing sign-in. App-server stderr is discarded,
and server errors are reduced to a code before they reach the UI.

The app-server API is experimental, so protocol-specific types, handshake code,
and process handling stay under `CodexUsageMenuBar/AppServer`.

## Legacy web-connected Claude usage (Preview 11)

The following adapter is retained for legacy protocol tests, but is no longer
instantiated by the default account controller or exposed by the account UI.
The current build uses the active saved Claude Code account instead.

`ClaudeWebUsageAdapter` owns an app-private, persistent WebKit session. The user
signs in directly on `https://claude.ai` inside the connection window. Neither
native code nor the bundled script reads cookies, passwords, local storage,
Claude Code credentials, or access tokens. WebKit alone persists and sends its
normal website session cookies; no cookies are imported from other browsers.

`ClaudeWebUsage.js` runs in WebKit's isolated client world, only on the exact
HTTPS `claude.ai` origin. It performs same-origin GETs to `/api/organizations`
and `/api/organizations/{selected-uuid}/usage`, with browser-managed credentials,
no caching, no custom authentication header, and redirects rejected. Only the
five-hour utilization/reset and minimal organization-selection metadata cross
back to Swift. These website endpoints are internal and may change; protocol
details stay isolated behind `ClaudeUsageProviding`.

Requests are bounded by a 20-second JavaScript abort and 25-second native timeout.
Rate limits back off for at least a minute, up to an hour. Login, verification,
network, and API failures show safe recovery guidance, never raw response bodies.
Disconnect invalidates in-flight results and clears the app's own web storage.
No foreign Keychain reads, credential refreshes, permission edits, model requests,
or raw-response logs are involved.

When Claude explicitly reports zero used with a null reset, the five-hour session
has not started. The dashboard shows **100% remaining** and **Starts with your
first message**, with no invented reset time. That idle reading expires after
five minutes unless refreshed. A missing window or malformed response remains
unavailable; it is never inferred to mean a full allowance.

The legacy `ClaudeContextCapture.sh` receives Claude Code's status-line JSON on
stdin and reduces it to only the account-level five-hour used percentage, reset
time, and update time. It atomically writes that reduced payload with user-only
permissions under:

```text
~/Library/Caches/com.bchen.CodexUsageMenuBar/claude-usage.json
```

Offline previews and cache-based tests can watch that cache once per second and
convert used percentage to remaining percentage. If a new Claude session has not received its first API
response yet, the bridge preserves the last valid snapshot; expired windows are
not displayed. The bridge uses macOS's built-in `plutil`, so testers do not need
Homebrew or `jq`. It does not invoke Claude, consume model tokens, inspect
transcripts or workspace paths, or read credential files.

## Package a friend preview

Run the deterministic packaging script to build both Apple Silicon and Intel
architectures, apply an ad-hoc signature, and create the ZIP under
`.build/releases`:

```sh
./scripts/package-preview.sh 0.1.0-preview.14
```

The script verifies the app's code-signature seal and both architectures before
creating the archive. This artifact is intended only for trusted preview
testers; a general release should use Developer ID signing and notarization.

## License

MIT. See [LICENSE](LICENSE). Bundled third-party code keeps its own MIT
notices: the Codex mark from [Lobe Icons](https://github.com/lobehub/lobe-icons)
(`CodexUsageMenuBar/Resources/LobeIcons-LICENSE.txt`) and Claude account
compatibility adapted from [claude-swap](https://github.com/realiti4/claude-swap)
(`CodexUsageMenuBar/Resources/ClaudeSwap-LICENSE.txt`).

The license covers this code, not the Codex, OpenAI, Claude, or Anthropic names
and marks, which belong to their owners. This project is not affiliated with or
endorsed by OpenAI or Anthropic.
