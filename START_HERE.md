# PowerBridge — start here

This folder contains the native iPhone app source and the PC companions.

**Using Linux and ESign? Read `docs/LINUX-ESIGN.md` first.** The included GitHub Actions workflow builds an unsigned iPhone-device IPA on a cloud Mac; download it and sign/install through your existing ESign setup. You do not need to own a Mac.

**This ZIP is the source project, not an IPA.** A successful cloud build and valid signing are still required. The steps below are the alternative for someone with access to a Mac. The included iPhone source still needs its first Xcode compilation and hardware tests. The companion passed 22 automated tests.

1. On a Mac, open `ios/PowerBridge.xcodeproj`.
2. In Xcode select the PowerBridge app target → Signing & Capabilities → your Team. Use a unique bundle identifier. Connect your iPhone and press Run.
3. Open `README.md` and follow the companion setup for your PC's current OS. It starts in test mode.
4. In the iPhone app, tap **+** and import the generated private `pairing.json`.
5. Test pairing/countdown/cancel. Enable live mode only after these work.
6. Repeat companion setup in the other OS using the **same machine ID**, then import that OS's pairing file too.
7. For Wake-on-LAN, use an always-on relay, or get Apple's multicast entitlement and enable the optional direct-wake build. See README section 3.

Selecting Linux/Windows before shutdown prepares the next boot. Selecting it while already off wakes the default OS first, then switches after its companion connects. Keep the iPhone app open for that process.

Read `README.md` for exact setup commands, IPA export instructions, hardware requirements, test status, troubleshooting, updates, and removal.
