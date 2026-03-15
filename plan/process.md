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

## Alternative: Replacing the HTTP Server with macOS Notifications

This section evaluates whether the same behavior could be achieved using the macOS notification system instead of a local HTTP server.

### What the HTTP server actually does

Before evaluating alternatives it helps to separate the server's two distinct jobs:

| Job | Description |
|-----|-------------|
| **Event ingestion** | Receive events from the hook script (one-way, fire-and-forget for most events) |
| **Permission blocking** | Hold a connection open until the user decides, then reply to unblock Claude Code (bidirectional, blocking) |

These two jobs have different requirements, and a notification-only approach handles them very differently.

### Can macOS notifications replace event ingestion?

For most events (everything except `PermissionRequest`) the hook script just needs to hand data to the app and move on. Several macOS-native mechanisms can do this without a TCP server:

**`NSDistributedNotificationCenter`**
The system-wide notification bus (`notifyd`) already runs on every Mac. An app can subscribe to a named notification and receive a dictionary payload. From a bash script you can post to it via `osascript`:
```bash
osascript -e "do shell script \"\"" # not ideal
```
In practice, posting from bash requires either a tiny compiled helper binary or going through `osascript`, which adds overhead. Payload size is also limited (a few KB) and the API does not guarantee delivery if the receiving app is not running.

**Unix domain socket**
A UNIX socket file (e.g. `~/.masko-desktop/hook.sock`) works like the TCP server but without a port number and without going through the network stack. The hook script connects with `nc -U` or `curl --unix-socket`. This is arguably simpler than TCP and sidesteps port-conflict issues, but it is still a server — just not an HTTP one.

**Named pipe (FIFO)**
The hook script writes the event JSON to a FIFO file; the app reads from it in a background thread. Simple, zero dependencies, but strictly one-directional. Fine for fire-and-forget events; not usable for blocking permission requests.

**File drop + FSEvents watch**
The hook script writes each event to a temp file in a watched directory; the app uses `FSEvents` or `DispatchSource` to detect new files and process them. Similar tradeoffs to named pipes.

**Verdict on event ingestion:** Yes, you could replace the HTTP server for plain event delivery using any of the above. A Unix domain socket is the closest drop-in replacement. `NSDistributedNotificationCenter` works but has payload size limits and no delivery guarantee.

---

### Can macOS notifications replace permission blocking?

This is where a pure-notification approach breaks down.

The current system works because the hook script's `curl` call **does not return** until the app closes the HTTP connection. Claude Code waits for the hook to return before proceeding. The decision (allow/deny) is carried in the HTTP response status code.

macOS `UNUserNotificationCenter` notifications are **fire-and-forget from the sender's perspective**. There is no built-in mechanism to:
- Block the sender until the user taps an action button
- Send a structured response back to the originating process

To replicate the blocking behavior you would still need a second IPC channel. A workable hybrid looks like this:

```
hook-sender.sh
  1. Write event JSON to Unix socket (or named pipe)       ← replaces POST /hook
  2. For PermissionRequest: open a named pipe for response
     e.g.  mkfifo /tmp/masko-response-$$
           echo $response_pipe_path >> event
  3. cat $response_pipe_path                               ← blocks here
  4. Read "allow" or "deny" from pipe, exit with code

App (Swift)
  1. Reads event from socket
  2. Shows UNUserNotification with "Allow" / "Deny" actions
  3. UNUserNotificationCenterDelegate.didReceive() fires when user taps
  4. Writes "allow" or "deny" to the named pipe path from the event
  5. Hook script unblocks and exits
```

This works, but the notification subsystem is now only the user-facing alert layer. The actual blocking/response mechanism is a named pipe or Unix socket — which is still a custom IPC channel, just a simpler one than HTTP.

---

### Limitations of using macOS notifications as the primary UI

Even if the IPC problem is solved, using `UNUserNotificationCenter` as the main attention UI has real constraints:

| Limitation | Impact |
|------------|--------|
| **Action buttons are text-only, max ~4** | Cannot show a numbered list of tool options like the current prompt does |
| **No interactive input** | User cannot type a custom response |
| **Notification grouping / collapsing** | Multiple pending permissions can get stacked and hidden |
| **Do Not Disturb / Focus mode** | Notifications can be suppressed entirely |
| **Banner auto-dismiss** | If the user doesn't act quickly, the banner disappears (though it stays in Notification Center) |
| **Cannot update a delivered notification** | If the session ends while a permission is pending, you cannot retract the notification |
| **No rich layout** | Cannot render the tool name, arguments, or multi-option selection UI |
| **Requires notification permission from the user** | The app must request and be granted notification authorization |

The current overlay approach sidesteps all of these: the app draws its own window, controls exactly what is shown, and the connection stays open until the user explicitly acts.

---

### What could realistically be done with notifications

A notification-based approach is viable for a **simpler, lower-fidelity version** of the behavior:

- **Attention signal:** Show a system notification when `isAlert` becomes true. The user sees a banner and clicks it to bring the app (or terminal) to focus. Good enough if you don't need an in-app permission UI.
- **Task completion:** `Stop` events can trigger a notification ("Claude finished your task") with zero IPC complexity — just `UNUserNotificationCenter.add(request)` in response to the event.
- **Status summary:** A notification on `SessionEnd` summarizing what was done.

For these read-only, non-blocking alerts, macOS notifications work well and require no server at all. The hook script posts the event to a Unix socket or named pipe, the app processes it, and calls `UNUserNotificationCenter`.

---

### Summary

| Requirement | HTTP server | Notifications only | Notifications + Unix socket/pipe |
|-------------|-------------|--------------------|----------------------------------|
| Receive events from hook | Yes | Partially (size/delivery limits) | Yes |
| Block Claude Code for permission | Yes (holds connection) | No | Yes (pipe blocks hook script) |
| Rich permission UI | Yes (custom overlay) | No (buttons only) | No (buttons only) |
| Non-blocking alerts (task done, etc.) | Yes | Yes | Yes |
| Works under Do Not Disturb | Yes | No | Partially |
| No port conflicts | No | Yes | Yes |
| Zero server code | No | Yes | Small (socket listener only) |

**Bottom line:** You can remove the HTTP server by replacing TCP with a Unix domain socket (for event delivery) and a named pipe (for permission responses). macOS notifications can handle the user-visible alert side for simple cases, but they cannot replace the interactive permission UI — you still need a custom overlay or equivalent for that. A pure-notification approach with no custom IPC is only sufficient if you are willing to drop the blocking permission flow entirely and accept that Claude Code will auto-proceed without waiting for user input.

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
