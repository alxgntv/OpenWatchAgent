# OpenWatch

Apple Watch + iPhone companion for voice commands to an **OpenClaw** agent (Coordinator / `main` by default).

## Docs (source of truth)

| Doc | Contents |
|-----|----------|
| [docs/PRODUCT.md](docs/PRODUCT.md) | UX, job model, screens, iPhone vs Watch split |
| [docs/PAIRING.md](docs/PAIRING.md) | **Native OpenClaw pairing** via **setup code** (`openclaw qr --setup-code-only`) |

## Status

- **iPhone:** setup code pairing, approval screen, home + job list, speech on phone.
- **Watch:** tap Listen → tap Send, job list/detail, TTS on done.
- **Bridge:** WatchConnectivity — watch commands use `transferUserInfo` (iPhone in background / locked OK after first permissions).
- **Jobs:** placeholder response until OpenClaw agent RPC is wired (`GatewayJobClient`).
- Open `OpenWatch.xcodeproj` in **Xcode 16+** (stable). Scheme **OpenWatch** → destination **your iPhone** (iOS 18+, not “iOS 26.5 Not Installed”). If Xcode 26 beta asks to download iOS 26.5 — cancel; use stable Xcode or install **iOS 18** platform in Xcode → Settings → Platforms.

## Run on a real iPhone (signing)

1. **Xcode → Settings → Accounts** — sign in with your Apple ID (same as on the iPhone).
2. Select target **OpenWatch** → **Signing & Capabilities** → enable **Automatically manage signing** → **Team** = your Personal Team (or paid team).
3. Repeat for **OpenWatch Watch App** — **same Team**.
4. Bundle IDs in repo: `com.alexeyignatov.OpenWatch` (iPhone) and `com.alexeyignatov.OpenWatch.watchkitapp` (Watch). If registration still fails, pick another unique prefix and update both targets + `WKCompanionAppBundleIdentifier` on the Watch target.
5. **Product → Run** on a connected iPhone (scheme **OpenWatch**, not Watch App only).
6. **Apple Watch:** do not rely on **INSTALL** in the iPhone **Watch** app until Xcode has installed once. Select your **Apple Watch** as the Run destination (or run **OpenWatch** on iPhone with the watch paired and unlocked) so the watch app is signed and embedded. Enable **Developer Mode** on the watch (Settings → Privacy & Security). Minimum **watchOS 10** (project deployment target).

### Watch: “Could not install at this time”

The **INSTALL** button in the iPhone **Watch** app often fails for **development** builds. Use Xcode instead:

1. Delete **OpenWatch** on iPhone and on the watch (if present).
2. **Product → Clean Build Folder**.
3. Scheme **OpenWatch** → destination **your Apple Watch** (not only iPhone) → **Run**.  
   Or scheme **OpenWatch Watch App** → destination **Apple Watch** → **Run** (installs the watch app directly).
4. Do **not** use **INSTALL** in AVAILABLE APPS until step 3 succeeded once.
5. Same **Team** on both targets; iPhone and watch app icons must exist (1024×1024 in asset catalogs).
6. Watch **Developer Mode** on; watch unlocked and paired.

Paid **Apple Developer Program** is optional for your own device; free Apple ID works (~7-day cert, reinstall from Xcode when expired).

## Requirements

- User runs their **own OpenClaw Gateway** (self-hosted). OpenWatch does not host agents.
- Pairing: user enters **setup code** from `openclaw qr --setup-code-only`, then owner runs `openclaw devices approve`.
