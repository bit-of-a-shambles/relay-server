# Relay Menu Bar

Thin macOS status-item wrapper for Relay.

## Features

- Start/stop the local Relay daemon
- Fetch and display one-time pairing code
- Open task logs directory (`~/.relay/tasks`)

## Build and run

```bash
cd menubar
xcodegen generate
xcodebuild -project RelayMenuBar.xcodeproj -scheme RelayMenuBar -destination 'platform=macOS' build
open RelayMenuBar.xcodeproj
```

The app appears as a status-bar icon and does not open a dock window.
