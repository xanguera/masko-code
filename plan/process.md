# Claude Code Attention Detection Process

This document explains how this repo detects that Claude Code needs user attention and identifies which exact terminal window/session to focus. The goal is to provide enough detail to replicate this behavior in another project.

---

## Overview

The system hooks into Claude Code's event system to receive real-time signals. When a signal requiring attention arrives (e.g., a permission request), the app holds the connection open, updates visual state, and provides enough context to focus the correct terminal window.

```
Claude Code (terminal)
    → hook-sender.sh (bash)
        → POST /hook (localhost:49152)
            → LocalServer
                → SessionStore / PendingPermissionStore
                    → UI / state machine inputs
```

---

## Step 1: Register Hooks in `~/.claude/settings.json`

Claude Code reads `~/.claude/settings.json` and runs a shell command for each registered hook event. The app writes entries like this:

```json
{
  "hooks": {
    "PreToolUse":       [{"matcher": "", "hooks": [{"type": "command", "command": "~/.masko-desktop/hooks/hook-sender.sh"}]}],
    "PostToolUse":      [{"matcher": "", "hooks": [{"type": "command", "command": "~/.masko-desktop/hooks/hook-sender.sh"}]}],
    "PermissionRequest":[{"matcher": "", "hooks": [{"type": "command", "command": "~/.masko-desktop/hooks/hook-sender.sh"}]}],
    "Notification":     [{"matcher": "", "hooks": [{"type": "command", "command": "~/.masko-desktop/hooks/hook-sender.sh"}]}],
    "Stop":             [{"matcher": "", "hooks": [{"type": "command", "command": "~/.masko-desktop/hooks/hook-sender.sh"}]}],
    "SessionStart":     [{"matcher": "", "hooks": [{"type": "command", "command": "~/.masko-desktop/hooks/hook-sender.sh"}]}],
    "SessionEnd":       [{"matcher": "", "hooks": [{"type": "command", "command": "~/.masko-desktop/hooks/hook-sender.sh"}]}]
    // ... and ~10 more event types
  }
}
```

**Relevant source:** `Sources/Services/HookInstaller.swift`

The hook script path and the server port are embedded at generation time. A version number in the script prevents unnecessary regeneration.

---

## Step 2: The Hook Script Injects Terminal Identity

When Claude Code fires a hook, it runs `hook-sender.sh` with the event JSON on stdin. The script does three things before forwarding the event:

### 2a. Check server liveness
```bash
curl --max-time 1 http://localhost:49152/health > /dev/null 2>&1 || exit 0
```
If the app is not running, the script exits silently so Claude Code is not blocked.

### 2b. Walk the process tree to find terminal and shell PIDs

```bash
get_terminal_and_shell() {
    local pid=$$
    local shell_pid="" term_pid=""
    while [ "$pid" -gt 1 ]; do
        local cmd=$(ps -o comm= -p "$pid" 2>/dev/null)
        case "$cmd" in
            zsh|bash|fish|sh|nu|pwsh|elvish)
                shell_pid=$pid ;;
            Terminal|iTerm2|WezTerm|kitty|Cursor|Code|Windsurf|ghostty|alacritty|Warp|Zed)
                term_pid=$pid
                break ;;
        esac
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
    echo "$term_pid $shell_pid"
}
```

Starting from the script's own PID (`$$`), it walks `ppid` links upward until it finds a recognized terminal application. It records both the **terminal app PID** and the **shell PID** separately.

### 2c. Inject PIDs and forward the event

```bash
read -r event_json   # stdin from Claude Code
event_json=$(echo "$event_json" | jq \
  --argjson tpid "$term_pid" \
  --argjson spid "$shell_pid" \
  '. + {terminal_pid: $tpid, shell_pid: $spid}')

# PermissionRequest: block until app responds (up to 120s)
# All other events:  fire-and-forget (2s timeout)
if [ "$hook_event_name" = "PermissionRequest" ]; then
    curl --max-time 120 -X POST http://localhost:49152/hook \
         -H "Content-Type: application/json" -d "$event_json"
else
    curl --max-time 2 -X POST http://localhost:49152/hook \
         -H "Content-Type: application/json" -d "$event_json" &
fi
```

The **blocking behavior on `PermissionRequest`** is how Claude Code is paused until the user decides. The hook script does not return until the HTTP connection closes, and Claude Code does not proceed until the hook returns.

**Relevant source:** `Sources/Services/HookInstaller.swift` (the script template is embedded here)

---

## Step 3: The Local HTTP Server Receives Events

A TCP server listens on port 49152 using `Network.framework` (`NWListener`).

**Routes:**
| Method | Path | Behavior |
|--------|------|----------|
| GET | `/health` | Returns `200 OK` immediately (liveness check) |
| POST | `/hook` | Processes Claude Code event |
| POST | `/input` | Injects custom inputs into animation state machine |

**For `POST /hook`:**
- Reads the full HTTP body (uses `Content-Length` header)
- JSON-decodes into a `ClaudeEvent` struct
- If event is `PermissionRequest`: **holds the TCP connection open** and passes it to `PendingPermissionStore`
- For all other events: sends `200 OK` immediately, then dispatches the event asynchronously

**Relevant source:** `Sources/Services/LocalServer.swift`

---

## Step 4: Session Tracking

Every event carries a `session_id` from Claude Code. The `SessionStore` maintains one `ClaudeSession` record per session:

```swift
struct ClaudeSession {
    let id: String              // session_id from Claude Code
    let projectDir: String?     // cwd when session started
    var phase: Phase            // .idle | .running | .compacting
    var terminalPid: Int?       // terminal app PID (from hook script)
    var shellPid: Int?          // shell PID (from hook script)
    var transcriptPath: String? // path to Claude's JSONL transcript
    var lastEventAt: Date?
    // ...
}
```

Phase transitions:

| Incoming event | New phase |
|----------------|-----------|
| `SessionStart` | `.idle` |
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest` | `.running` |
| `PreCompact` | `.compacting` |
| `Stop` | `.idle` |
| `SessionEnd` | session marked `.ended` |

**Relevant source:** `Sources/Stores/SessionStore.swift`

---

## Step 5: Computing Aggregate Attention State

`OverlayManager` reads all active sessions and pending permissions to produce boolean inputs for the UI state machine:

```swift
let active = sessionStore.activeSessions
let activeSessionIds = Set(active.map(\.id))

let isWorking = active.contains { $0.phase == .running }
let isIdle    = active.allSatisfy { $0.phase == .idle } || active.isEmpty
let isAlert   = pendingPermissionStore.pending.contains { perm in
    guard let sid = perm.event.sessionId else { return false }
    return activeSessionIds.contains(sid)  // ignore permissions from ended sessions
}
let isCompacting = active.contains { $0.isCompacting }
let sessionCount = active.count
```

These values are pushed into the state machine as named inputs:
- `claudeCode::isWorking`
- `claudeCode::isIdle`
- `claudeCode::isAlert`
- `claudeCode::isCompacting`
- `claudeCode::sessionCount`
- `claudeCode::<EventName>` — a momentary `true` for each arriving event

**`isAlert = true`** is the primary "needs attention" signal. It is only `true` when there is a pending permission from a session that is still active (not ended).

**Relevant source:** `Sources/Views/Overlay/OverlayManager.swift`

---

## Step 6: Identifying the Exact Window

When the user needs to act on a session (e.g., navigate to the right terminal tab), the app uses the `terminalPid` and `shellPid` stored on the session.

### For IDEs with extensions (VS Code, Cursor, Windsurf)
The extension exposes an API that accepts a shell PID and focuses the matching terminal tab directly.

### For iTerm2 / Terminal.app
AppleScript is used. Example for iTerm2:
```applescript
tell application "iTerm2"
    repeat with w in windows
        repeat with t in tabs of w
            repeat with s in sessions of t
                if pid of s = shellPid then
                    select s
                    return
                end if
            end repeat
        end repeat
    end repeat
end tell
```

### For other terminals (Ghostty, Kitty, Warp, Alacritty, WezTerm, Zed)
The app can only bring the terminal application to the foreground using its PID; it cannot select a specific tab. It uses `NSRunningApplication(processIdentifier: terminalPid)?.activate()`.

**Relevant source:** `Sources/Services/IDETerminalFocus.swift`

---

## Step 7: Resolving a Permission Request

Once the user makes a decision, the app sends the HTTP response on the still-open connection:

```
HTTP/1.1 200 OK          ← allow
HTTP/1.1 403 Forbidden   ← deny
```

The response body follows Claude Code's protocol format (tool use result JSON). Closing the connection unblocks the hook script, which unblocks Claude Code, which proceeds with or without the tool.

The connection is also monitored for unexpected closure (client crash/SIGKILL). If the connection dies before the user decides, the permission is auto-dismissed.

**Relevant source:** `Sources/Stores/PendingPermissionStore.swift`

---

## Step 8: Interrupt Detection (Polling-Based Fallback)

Claude Code does not fire a hook when the user interrupts a running request (Ctrl+C). To detect this, the app polls the transcript JSONL file:

- **Interval:** every 3 seconds
- **Target sessions:** active sessions in `.running` phase
- **Method:** read the last 4 KB of the transcript, walk lines backward, look for a user message containing `"[Request interrupted by user]"`
- **Result:** transition the session phase to `.idle`

**Relevant source:** `Sources/Stores/SessionStore.swift`

---

## Step 9: Crash / Stale Session Recovery

Two mechanisms handle the case where Claude Code crashes without firing `SessionEnd`:

1. **Periodic check (every 2 minutes):** run `pgrep claude`. If no process is found, mark all active sessions as ended.
2. **On app activation:** the same check runs (throttled to once per 30 seconds) when the user brings the app to the foreground.

A session is also considered stale if it has received no events for 10+ minutes.

**Relevant source:** `Sources/Stores/SessionStore.swift`

---

## Replication Checklist

To replicate this behavior in another project:

1. **Write a hook script** that:
   - Checks your server is alive before doing anything
   - Walks `ppid` from `$$` to find the terminal app PID and shell PID
   - Injects those PIDs into the event JSON
   - Blocks on permission events, fires-and-forgets on all others

2. **Register the hook** for every relevant event type in `~/.claude/settings.json`

3. **Run an HTTP server** (any language) on a local port that:
   - Responds to `GET /health` immediately
   - For `PermissionRequest`: holds the connection and queues it for user action
   - For other events: responds `200 OK` immediately and processes asynchronously

4. **Track sessions** keyed on `session_id`, storing `terminal_pid` and `shell_pid` from each event

5. **Compute attention state** as: `isAlert = any pending permission whose session_id is still active`

6. **Focus the right window** using the stored `terminal_pid`/`shell_pid`:
   - IDE extensions: tab-level focus via shell PID
   - iTerm2/Terminal.app: AppleScript with shell PID
   - Other terminals: `activate()` the app by terminal PID

7. **Resolve permissions** by sending `200 OK` or `403 Forbidden` on the held connection

8. **Poll transcripts** every ~3 seconds to catch user interrupts (no hook fires for these)

9. **Recover from crashes** by periodically checking `pgrep claude` and marking stale sessions ended

---

## Replicating the Behavior with macOS System Notifications

**Goal:** show a macOS notification whenever Claude Code needs attention, and when the user clicks it, focus the exact terminal or IDE window where that session is running.

This is a well-scoped goal and is fully achievable. The blocking/interactive permission UI from this repo is not needed. Claude Code will auto-proceed on permission events (using its default behavior); the user is simply alerted and can switch to the right window immediately.

---

### What you still need (and what you don't)

| Component | Still needed? | Notes |
|-----------|--------------|-------|
| Hook registration in `~/.claude/settings.json` | **Yes** | Identical to this repo — no way around it |
| Process-tree walk for terminal/shell PIDs | **Yes** | This is how you know which window to focus |
| Local HTTP server | **No** | Replaced by a Unix domain socket (simpler) |
| Holding the connection open for permissions | **No** | Claude Code auto-proceeds; you just get notified |
| Interactive permission overlay | **No** | The notification banner is the entire UI |
| Session phase tracking | **Simplified** | Only need to know which sessions are active and their PIDs |

---

### Architecture

```
Claude Code (terminal)
    │  fires hook
    ▼
hook-sender.sh
    │  1. walk ppid chain → terminal_pid, shell_pid
    │  2. inject into JSON
    │  3. nc -U ~/.local/share/claude-notify/hook.sock
    ▼
background daemon (Swift / Python / Node)
    │  reads event from Unix socket
    │  stores: session_id → { terminal_pid, shell_pid, project_name }
    │  if event warrants attention →
    ▼
UNUserNotificationCenter
    │  banner: "Claude needs attention — <project_name>"
    │  userInfo: { session_id, terminal_pid, shell_pid, terminal_app }
    │  user clicks →
    ▼
UNUserNotificationCenterDelegate.didReceive()
    │  reads terminal_pid + terminal_app from userInfo
    ▼
window focus
    ├── iTerm2 / Terminal.app  →  AppleScript (focus exact tab by shell_pid)
    ├── VS Code / Cursor / Windsurf  →  IDE extension API (focus tab by shell_pid)
    └── other terminals  →  NSRunningApplication(processIdentifier: terminal_pid)?.activate()
```

---

### Step-by-step implementation

#### 1. Hook script (identical to this repo for PID walking)

The hook script must still walk the process tree. The only change from this repo is the transport: instead of `curl http://localhost:49152/hook`, use a Unix socket.

```bash
#!/usr/bin/env bash
SOCK="$HOME/.local/share/claude-notify/hook.sock"

# Check daemon is alive
[ -S "$SOCK" ] || exit 0

# Walk ppid chain to find terminal and shell
get_pids() {
    local pid=$$ shell_pid="" term_pid=""
    while [ "$pid" -gt 1 ]; do
        local cmd; cmd=$(ps -o comm= -p "$pid" 2>/dev/null)
        case "$cmd" in
            zsh|bash|fish|sh)          shell_pid=$pid ;;
            Terminal|iTerm2|WezTerm|kitty|\
            Cursor|Code|Windsurf|ghostty|\
            alacritty|Warp|Zed)        term_pid=$pid; break ;;
        esac
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
    echo "$term_pid $shell_pid"
}

read -r term_pid shell_pid <<< "$(get_pids)"

# Read event JSON from stdin (Claude Code writes it here)
event_json=$(cat)

# Inject PIDs and terminal app name
term_app=$(ps -o comm= -p "$term_pid" 2>/dev/null)
event_json=$(echo "$event_json" | jq \
  --argjson tpid "${term_pid:-0}" \
  --argjson spid "${shell_pid:-0}" \
  --arg tapp "$term_app" \
  '. + {terminal_pid: $tpid, shell_pid: $spid, terminal_app: $tapp}')

# Fire-and-forget — never block Claude Code
echo "$event_json" | nc -U "$SOCK" &
```

Register this script for the events you care about in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PermissionRequest": [{"matcher": "", "hooks": [{"type": "command", "command": "~/.local/share/claude-notify/hook.sh"}]}],
    "Notification":      [{"matcher": "", "hooks": [{"type": "command", "command": "~/.local/share/claude-notify/hook.sh"}]}],
    "Stop":              [{"matcher": "", "hooks": [{"type": "command", "command": "~/.local/share/claude-notify/hook.sh"}]}],
    "SessionStart":      [{"matcher": "", "hooks": [{"type": "command", "command": "~/.local/share/claude-notify/hook.sh"}]}],
    "SessionEnd":        [{"matcher": "", "hooks": [{"type": "command", "command": "~/.local/share/claude-notify/hook.sh"}]}]
  }
}
```

You can add more event types, but the above cover the attention-relevant signals.

> **Note on `PermissionRequest`:** because the hook script no longer blocks, Claude Code will apply its default permission behavior (typically deny) and keep running. The notification tells you what happened but you are not gating the action. If you need to actually approve/deny tools interactively, the full HTTP + blocking approach from this repo is required.

---

#### 2. Background daemon: receive events and track sessions

A small always-running process listens on the Unix socket, maintains a session map, and triggers notifications. Swift is the natural choice on macOS for `UNUserNotificationCenter`, but Python with `terminal-notifier` or a Rust binary work too.

**Session map** (kept in memory, optionally persisted to a JSON file):
```
session_id → {
    terminal_pid:   Int,
    shell_pid:      Int,
    terminal_app:   String,   // "iTerm2", "Terminal", "Cursor", etc.
    project_name:   String,   // last path component of cwd
    phase:          "idle" | "running",
    started_at:     Date
}
```

**Phase transitions** (only what matters for attention detection):

| Event | Action |
|-------|--------|
| `SessionStart` | Create entry, phase = `idle`, store `cwd` as project name |
| `UserPromptSubmit` | phase = `running` |
| `PermissionRequest` | Show notification ("needs approval"), phase stays `running` |
| `Notification` with `idle_prompt` subtype | Show notification ("waiting for input") |
| `Stop` | Show notification ("task finished") if desired, phase = `idle` |
| `SessionEnd` | Remove entry |

**When to fire a notification:**
```
PermissionRequest  →  "Claude needs your approval"   (urgent)
Notification       →  "Claude is waiting for input"  (high)
Stop               →  "Claude finished"              (normal, optional)
```

---

#### 3. Notification payload

Embed the routing data in `userInfo` so the click handler has everything it needs:

```swift
let content = UNMutableNotificationContent()
content.title = "Claude needs attention"
content.body  = projectName          // e.g. "my-app"
content.sound = .defaultCritical
content.userInfo = [
    "session_id":    event.sessionId,
    "terminal_pid":  session.terminalPid,
    "shell_pid":     session.shellPid,
    "terminal_app":  session.terminalApp   // "iTerm2", "Cursor", etc.
]

let request = UNNotificationRequest(
    identifier: "claude-\(event.sessionId)",  // one notification per session
    content: content,
    trigger: nil   // deliver immediately
)
UNUserNotificationCenter.current().add(request)
```

Using `session_id` as the notification identifier means a second event for the same session **replaces** the previous notification rather than stacking.

---

#### 4. Click handler: focus the right window

```swift
func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
) {
    let info = response.notification.request.content.userInfo
    let termPid  = info["terminal_pid"] as? Int32 ?? 0
    let shellPid = info["shell_pid"]    as? Int32 ?? 0
    let termApp  = info["terminal_app"] as? String ?? ""

    focusWindow(terminalApp: termApp, terminalPid: termPid, shellPid: shellPid)
    completionHandler()
}

func focusWindow(terminalApp: String, terminalPid: Int32, shellPid: Int32) {
    switch terminalApp {

    case "iTerm2":
        // AppleScript: find the session whose tty PID matches shellPid, select it
        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (pid of s) = \(shellPid) then
                            tell w to select
                            tell t to select
                            tell s to select
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
        NSAppleScript(source: script)?.executeAndReturnError(nil)

    case "Terminal":
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if (processes of t) contains \(shellPid) then
                        set selected tab of w to t
                        activate
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
        NSAppleScript(source: script)?.executeAndReturnError(nil)

    case "Cursor", "Code", "Windsurf":
        // These IDEs expose a URI handler or extension API.
        // Simplest fallback: just activate the app by PID.
        NSRunningApplication(processIdentifier: termPid)?.activate(options: .activateIgnoringOtherApps)

    default:
        // Ghostty, WezTerm, Kitty, Alacritty, Warp, Zed — app-level focus only
        NSRunningApplication(processIdentifier: termPid)?.activate(options: .activateIgnoringOtherApps)
    }
}
```

---

### What this approach gives you vs. this repo

| Behavior | This repo | Notification approach |
|----------|-----------|-----------------------|
| Notified when Claude needs attention | Yes (visual overlay) | Yes (system notification) |
| Click → focus exact terminal tab | Yes | Yes (same PID logic) |
| Works while app is in background | Yes | Yes |
| Works in full-screen apps / other spaces | Yes | Yes (notification appears on top) |
| Approve/deny tool use interactively | Yes (blocks Claude) | No (Claude auto-proceeds) |
| Custom mascot animation | Yes | No |
| Multiple simultaneous sessions | Yes (overlay shows count) | Partial (one notification per session_id) |
| No TCP port required | No | Yes |
| Implementation size | Large (full macOS app) | Small (~300 lines Swift or equivalent) |

---

### Minimal viable implementation checklist

1. Write `hook.sh` with the `ppid` walk and Unix socket delivery (shown above)
2. Register hooks in `~/.claude/settings.json` for `PermissionRequest`, `Notification`, `Stop`, `SessionStart`, `SessionEnd`
3. Write a background daemon that:
   - Creates and listens on a Unix socket at a fixed path
   - Maintains a `[String: SessionInfo]` dictionary keyed on `session_id`
   - Requests `UNUserNotificationCenter` authorization on first launch
   - Fires a notification with `userInfo` containing `terminal_pid`, `shell_pid`, `terminal_app`
   - Implements `UNUserNotificationCenterDelegate.didReceive()` to call `focusWindow()`
4. Implement `focusWindow()` with AppleScript for iTerm2/Terminal.app and `NSRunningApplication.activate()` for everything else
5. Install the daemon as a `LaunchAgent` so it starts on login (`~/Library/LaunchAgents/com.yourname.claude-notify.plist`)

---

## Key Files in This Repo

| File | Role |
|------|------|
| `Sources/Services/HookInstaller.swift` | Writes `~/.claude/settings.json` and generates `hook-sender.sh` |
| `Sources/Services/LocalServer.swift` | TCP HTTP server on port 49152 |
| `Sources/Stores/SessionStore.swift` | Session lifecycle, phase transitions, interrupt polling, crash recovery |
| `Sources/Stores/PendingPermissionStore.swift` | Queue of held permission connections |
| `Sources/Views/Overlay/OverlayManager.swift` | Aggregates session state into attention signals |
| `Sources/Services/IDETerminalFocus.swift` | Focuses the correct terminal window/tab |
| `Sources/Models/ClaudeEvent.swift` | Event struct (all fields Claude Code sends) |
