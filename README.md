<p align="center">
  <img src="docs/images/open-watch-logo.png" width="260" alt="Open Watch logo">
</p>

# Open Watch Agent

Open Watch Agent is an AI wrist-first interface. It lets you manage your AI agents from your wrist. If you want your AI assistant to feel always available, this is it. Anyone with a watch that has internet can access their own AI agents.

This is fully open-source

<p>
  <img src="docs/images/watch-speak.png" width="220" alt="Open Watch Platform Speak screen on Apple Watch">
  <img src="docs/images/watch-recording.png" width="220" alt="Open Watch Platform recording screen on Apple Watch">
  <img src="docs/images/watch-agents.png" width="220" alt="Open Watch Platform agents screen on Apple Watch">
</p>

<p>
  <img src="docs/images/watch-sessions.png" width="220" alt="Open Watch Platform sessions screen on Apple Watch">
  <img src="docs/images/watch-usage-overview.png" width="220" alt="Open Watch Platform usage overview screen on Apple Watch">
  <img src="docs/images/watch-usage-tokens.png" width="220" alt="Open Watch Platform usage tokens screen on Apple Watch">
</p>

## Why

Most AI-agent workflows still assume that you are sitting at a computer or holding a phone. Your AI agent can be closer to you. This feel is not native. Open Watch Agent works while you're cycling or in a sauna.

Raise your wrist -> speak -> send -> get shit done. Working with AirPods & Apple Watch

## Supported Platforms

- [x] Apple Watch (watchOS 10+)
- [x] iPhone (iOS 18+)
- [ ] Android
- [ ] Samsung Galaxy Watch
- [ ] Google Pixel Watch
- [ ] OnePlus Watch 2
- [ ] Other Wear OS watches with Network

Agent backends:

- [x] OpenClaw
- [ ] Nanoclaw
- [ ] Hermes
- [ ] Other agent with gateway

## OpenClaw Pairing Example

```text
Gateway address:
wss://openclaw.example.com:18789

Setup code:
<the full output from openclaw qr --setup-code-only>
```

## Run on iPhone & Watch

1. Open `OpenWatch.xcodeproj` in Xcode 16+.
2. In **Xcode -> Settings -> Accounts**, sign in with your Apple ID.
3. Select target **OpenWatch** -> **Signing & Capabilities** -> enable **Automatically manage signing** -> choose your Team.
4. Repeat the same signing setup for **OpenWatch Watch App**.
5. Run scheme **OpenWatch** on a connected iPhone.
6. Run scheme **OpenWatch Watch App** on a paired Apple Watch.

Bundle IDs in this repo:

- iPhone: `com.openwatchagent` (display name: Open Watch Agent)
- Watch: `com.openwatchagent.watchkitapp` (display name: Open Watch Agent)
