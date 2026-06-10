# Open Watch Platform

Open Watch Platform is an open-source watch-first interface for your personal AI agents. It lets you talk to an agent from your wrist, send a voice command, receive a response, and hear it in your headphones without opening a computer or holding a phone.

The goal is simple: anyone with a watch that has internet access should be able to reach their own AI agents anywhere. The agent can be OpenClaw, Nanoclaw, Hermes, or any other personal agent stack. The watch is just the natural access point.

If you want your AI assistant to feel always available, mobile, and close to you instead of trapped inside a desktop or phone chat window, this is it.

Current implementation: Apple Watch + iPhone companion for voice commands to an **OpenClaw** agent.

Docs: [Product](docs/PRODUCT.md) · [Pairing](docs/PAIRING.md)

New install? Start here: [Pairing](docs/PAIRING.md)

Preferred setup: run your own agent gateway, generate a setup code, pair the iPhone app, approve the device, then speak to your agent from Apple Watch. Open Watch Platform is designed so the community can extend it to more watches, more platforms, and more agent backends.

## Why

Most AI-agent workflows still assume that you are sitting at a computer or holding a phone. You open Telegram, WhatsApp, Slack, or another interface, press and hold a recording button, speak, wait, and read or listen to the reply.

That works at a desk. It does not work well on a bike, during training, on a walk, in a sauna, while traveling, or in any situation where your hands are busy and pulling out a phone is unsafe, awkward, or just too much friction.

Open Watch Platform turns the watch into the shortest path to your agent. Raise your wrist, tap one button, speak, send, and hear the response in AirPods or other headphones.

## Philosophy

An AI agent should not be a tool you have to go to. It should be a helper that is available when you need it, where you already are.

Open Watch Platform exists to make access to personal AI agents more natural, mobile, and independent from any single device. The project is open source so the community can improve it, adapt it, and expand it to any platform where a person may want a direct voice link to their agent.

The original idea came from a simple moment: riding a bike to training while an OpenClaw agent was working on a project. The agent kept sending updates, but interacting with it through a phone chat while cycling was unsafe and inconvenient. The watch was already on the wrist. The missing piece was obvious: tap, speak, send, listen.

## Supported Agents

Open Watch Platform is intended to work with any personal AI-agent backend.

Current focus:

- OpenClaw

Planned by design:

- Nanoclaw
- Hermes
- Any gateway or agent API the community wants to connect

## Status

- **iPhone:** setup code pairing, approval screen, home + job list, speech on phone.
- **Watch:** tap Listen, tap Send, job list/detail, TTS on done.
- **Bridge:** WatchConnectivity, so watch commands can reach the iPhone companion.
- **Jobs:** placeholder response until OpenClaw agent RPC is wired (`GatewayJobClient`).

## Requirements

- Apple Watch with watchOS 10+.
- iPhone with iOS 18+.
- Xcode 16+.
- A self-hosted OpenClaw Gateway for the current implementation.
- Pairing through a setup code from `openclaw qr --setup-code-only`, followed by `openclaw devices approve`.

## Run on a real iPhone

1. Open `OpenWatch.xcodeproj` in Xcode 16+.
2. In **Xcode -> Settings -> Accounts**, sign in with your Apple ID.
3. Select target **OpenWatch** -> **Signing & Capabilities** -> enable **Automatically manage signing** -> choose your Team.
4. Repeat the same signing setup for **OpenWatch Watch App**.
5. Run scheme **OpenWatch** on a connected iPhone.
6. Run scheme **OpenWatch Watch App** on a paired Apple Watch.

Bundle IDs in this repo:

- iPhone: `com.alexeyignatov.OpenWatch`
- Watch: `com.alexeyignatov.OpenWatch.watchkitapp`

Paid Apple Developer Program is optional for your own device. A free Apple ID works with the usual development certificate limits.

## Watch Install Notes

The **INSTALL** button in the iPhone **Watch** app often fails for development builds. Use Xcode instead:

1. Delete **OpenWatch** on iPhone and Apple Watch if needed.
2. Use **Product -> Clean Build Folder**.
3. Run scheme **OpenWatch Watch App** directly on Apple Watch.
4. Keep the watch unlocked, paired, and near the iPhone/Mac.
5. Make sure Developer Mode is enabled on the watch.
