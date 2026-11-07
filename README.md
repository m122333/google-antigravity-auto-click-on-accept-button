# Google Antigravity Auto Click on Accept Button

Auto Click clicks **Accept all** in [Google Antigravity IDE](https://antigravity.google) for you. When the agent finishes a task and leaves file changes waiting for review, the button is clicked within a few milliseconds, even if the window is minimized or hidden behind other apps.

It is a small Antigravity extension plus an optional Windows installer that sets everything up, including Antigravity itself.

## Install

### Windows (recommended)

1. Download `Antigravity-Auto-Click-<version>.zip` from the [Releases](https://github.com/m122333/google-antigravity-auto-click-on-accept-button/releases) page and extract it.
2. Double-click `Install.cmd`.

The installer:

| Step | What happens |
|---|---|
| Checks the computer | Needs Windows 10 or 11, 64-bit (x64 or ARM64). |
| Finds Antigravity IDE | Reads Antigravity's own `product.json`, so it is not confused by other Google apps named "Antigravity". |
| Installs Antigravity IDE if it is missing | Only after you agree. Uses `winget install Google.AntigravityIDE`. If winget is not available, it downloads the official installer from Google's servers (about 220 MB) and checks its SHA256 fingerprint against the [winget catalog](https://github.com/microsoft/winget-pkgs/tree/master/manifests/g/Google/AntigravityIDE) before running it. Installation is per-user and needs no administrator rights. |
| Opens a local debug port | Adds `"remote-debugging-port": "9333"` to Antigravity's `argv.json`. |
| Installs the extension | Through Antigravity's own command line. |
| Adds a desktop switch | A **Google Antigravity Auto Click on Accept Button** shortcut that turns auto-accept on or off. |
| Registers an uninstaller | The tool shows up in **Windows Settings > Apps**. |
| Restarts Antigravity if needed | Only after asking, so you don't lose unsaved work. |

Nothing else is downloaded. No background programs, startup entries, or scheduled tasks are created.

You still sign in to Antigravity with your own Google account. The installer never asks for or handles passwords.

### Any platform (manual)

In Antigravity, open the Extensions view, click `...`, choose **Install from VSIX...** and pick `antigravity-auto-click-<version>.vsix`. On first start the extension adds the debug port to `argv.json` and asks you to restart Antigravity once.

## Use

- **Status bar**: `Auto Click` with a check mark means it is on. Click it to turn it off or on.
- **Desktop switch** (Windows installer): open the **Google Antigravity Auto Click on Accept Button** shortcut to toggle. Antigravity shows "Auto Click is ON" or "Auto Click is OFF". The first time, Antigravity asks *"Allow 'Google Antigravity Auto Click on Accept Button' extension to open this URI?"*. Tick **Do not ask me again for this extension** and click **Open**. The tool never approves this for you.
- **Command Palette**: `Auto Click: Turn On/Off` and `Auto Click: Show Log`.

### Settings

| Setting | Default | Meaning |
|---|---|---|
| `autoClick.enabled` | `true` | Turn auto-accept on or off. |
| `autoClick.buttons` | `["Accept all"]` | Exact button labels to click, not case-sensitive. Adding `"Run"` would also run terminal commands the agent suggests without asking you, so think twice. |
| `autoClick.debugPort` | `9333` | Port to add to `argv.json` when it has none yet. |

## How it works

Antigravity is built on Electron. The `remote-debugging-port` entry in `argv.json` makes it accept DevTools connections on `127.0.0.1`. The extension connects to each Antigravity window, and to the agent panel (which Antigravity renders in its own frame served by its local language server), through that port. In each one it installs a small `MutationObserver` that clicks a button as soon as its text matches one of the configured labels. Webviews of other extensions are left alone.

The page script stops by itself if the extension does not check in for 10 seconds, so turning the extension off, uninstalling it, or a crash never leaves anything clicking in the background.

## Security

The debug port only listens on `127.0.0.1`, so nothing on your network or the internet can reach it. But any program already running on your computer could use it to control Antigravity. If that is a concern for you, don't use this tool. Uninstalling removes the port setting again.

## Windows SmartScreen and antivirus

The scripts are plain, readable PowerShell. They don't use encoded commands, hidden windows, `Invoke-Expression`, autostart entries, or scripts that run in the background, which are the patterns security software looks for. Even so, Windows may show **"Windows protected your PC"** or a security warning the first time you open `Install.cmd` from a downloaded zip, because the files are not code-signed. Choose **More info > Run anyway**, or right-click the zip, open **Properties** and tick **Unblock** before extracting.

The only way to remove that warning completely is to sign the release with a paid code-signing certificate.

## Uninstall

Use **Windows Settings > Apps > Google Antigravity Auto Click on Accept Button > Uninstall**, or run `%LOCALAPPDATA%\Antigravity Auto Click\Uninstall.cmd`. This removes the extension, the desktop switch, the uninstaller entry and the `remote-debugging-port` line from `argv.json`. Restart Antigravity afterwards.

Uninstalling only the extension from inside Antigravity also removes the port setting the next time Antigravity starts.

## Build from source

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
```

This writes `dist/Antigravity-Auto-Click-<version>/` and `dist/Antigravity-Auto-Click-<version>.zip`. No Node.js, npm or other tools are needed.

```
extension/   Antigravity extension (plain JavaScript, no dependencies)
installer/   Windows installer and uninstaller (PowerShell)
assets/      Icons
build.ps1    Packs the .vsix and the release zip
```

## Notes

- Auto Click is not made by, affiliated with, or endorsed by Google.
- It depends on the button text Antigravity shows today. If a future version renames the button, update `autoClick.buttons`.
- If you use another auto-accept extension, turn one of them off so they don't both handle the same button.

## License

[MIT](LICENSE)
