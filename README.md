# PowerBridge

A native iPhone remote for your Windows/Linux PC. SwiftUI interface, encrypted pairing, shutdown/restart with cancellation, Wake-on-LAN, and one-time OS selection.

**Delivery status:** complete source project and installers; **not a signed IPA**. The Python companion passed 22 automated tests in a Linux environment. The iOS source has not been compiled with Xcode here, and real Windows firmware, Linux firmware, iPhone networking, and Wake-on-LAN need the hardware acceptance checks below. A macOS GitHub Actions workflow now builds an unsigned iPhone-device IPA for signing in ESign; it has not been run here. No real shutdown or firmware change was executed during development.

## Start here

**Using Linux and ESign without a Mac? Start with [docs/LINUX-ESIGN.md](docs/LINUX-ESIGN.md).** The cloud build needs no certificate or Apple account secrets.

1. Open `ios/PowerBridge.xcodeproj` on a Mac with Xcode. Select your Apple team and a unique bundle ID in Signing & Capabilities. Connect your iPhone (iOS 17+) and Run.
2. Follow the Linux or Windows companion setup below. Start in **test mode**.
3. Transfer the generated private `pairing.json` to your iPhone. Tap **+ → Choose pairing file → Save pairing**. You can also paste its contents.
4. Test the countdown and cancellation. When ready, change `dry_run` to `false` in the installed companion configuration and restart the service.
5. To wake a powered-off PC, configure either an **always-on relay** (standard build) or the **direct-wake entitled build**. Neither can wake a PC whose power supply is unplugged.

## Included features

- Native dark SwiftUI interface with mint accents, app icon, and accessibility labels.
- Multiple computers; one computer can contain Linux, Windows, and relay connections.
- HTTPS with an out-of-band certificate fingerprint; HMAC-authenticated requests with timestamp and nonce checks.
- Secrets stored in the iPhone Keychain with device-only, unlocked access.
- Face ID, Touch ID, or device passcode confirmation for power actions.
- Shutdown/restart countdowns: 10 seconds, 30 seconds, 1 minute, 5 minutes, or 30 minutes.
- Cancel a pending action, see connection status and recent service-session activity.
- One-time Linux/Windows boot selection without rewriting the permanent boot order.
- Wake through a relay, or direct LAN broadcast in the entitled build.
- “Wake → wait for companion → switch OS” while the iPhone app remains open.
- Test mode on by default; no actual power, firmware, or wake operations in that mode.

## What is required

| Feature | Requirement |
|---|---|
| Run on iPhone | iOS 17+, Xcode on macOS, Apple signing configured |
| Export installable IPA | Apple signing identity and provisioning for the intended distribution method/device |
| PC controls | Python 3.11+, companion installed in each OS, LAN/VPN reachability |
| OS selection | Both OSes installed in UEFI mode, active UEFI entries mapped explicitly |
| Reliable wake | Ethernet NIC + firmware support + standby power + correct network path |
| Standard iPhone build wake | Always-on relay on the PC's LAN (Raspberry Pi, NAS with Python, or another computer) |
| Direct iPhone broadcast wake | Apple-approved multicast entitlement and matching signing profile |
| Away from home | An existing private VPN route to PC and relay; VPN configuration is not bundled |

This does not install Windows/Linux, create boot entries, bypass a bootloader password, or unlock full-disk encryption. A Linux firmware entry may still lead to a GRUB menu; configure that entry's normal default to Linux. A BIOS-only installation cannot use the UEFI feature. Do not guess boot entry numbers.

## 1. Linux / Zorin companion

Run from the extracted `PowerBridge` directory. Replace sample addresses and MAC with your actual Ethernet values. Reserve the PC IP in your router first.

```bash
sudo apt update
sudo apt install python3 python3-venv efibootmgr ethtool
python3 -m venv .venv
.venv/bin/python -m pip install -r companion/requirements.txt
ip -br address
ip link
```

Read the UEFI entries (does not modify them):

```bash
sudo .venv/bin/python companion/setup.py --list-boots
```

Example only: if your verified Linux entry is `0001` and Windows is `0002`:

```bash
sudo .venv/bin/python companion/setup.py \
  --dir config-linux --host 192.168.1.50 \
  --name "Anas PC" --machine-id anas-pc \
  --mac AA:BB:CC:DD:EE:FF --broadcast 192.168.1.255 \
  --linux-entry 0001 --windows-entry 0002
sudo bash scripts/install-linux.sh "$PWD/config-linux"
sudo systemctl status powerbridge
```

Omit both `--*-entry` flags for shutdown/restart only. Generated configurations start in test mode. On a network other than `192.168.1.0/24`, use that network's actual directed broadcast address.

To view the private pairing data locally:

```bash
sudo cat config-linux/pairing.json
```

Transfer/paste it privately, then clear the clipboard and remove temporary shared copies. It is a credential, not a public QR/link.

If UFW is enabled, allow only the actual local/VPN subnet (example):

```bash
sudo ufw allow from 192.168.1.0/24 to any port 45831 proto tcp
```

After testing: `sudo nano /etc/powerbridge/config.json`, change `"dry_run": true` to `false`, then:

```bash
sudo systemctl restart powerbridge
sudo journalctl -u powerbridge -n 60
```

The service uses Python's standard library at runtime; the cryptography package is only required to generate certificates during setup.

## 2. Windows companion

Install 64-bit Python 3.11+ **for all users into Program Files**, including PATH. The installer deliberately rejects a user-writable interpreter because the service runs as SYSTEM. Open **PowerShell as Administrator** in the extracted folder:

```powershell
python -m pip install -r companion\requirements.txt
Get-NetAdapter | Format-Table Name, MacAddress, Status
Get-NetIPAddress -AddressFamily IPv4
python companion\setup.py --list-boots
```

Use the actual UEFI IDs printed on this PC. They are four-digit hexadecimal firmware IDs, not BCDEdit GUIDs. Example:

```powershell
python companion\setup.py --dir config-windows --host 192.168.1.50 --name "Anas PC" --machine-id anas-pc --mac AA:BB:CC:DD:EE:FF --broadcast 192.168.1.255 --linux-entry 0001 --windows-entry 0002
powershell -ExecutionPolicy Bypass -File scripts\install-windows.ps1 -ConfigDir "$PWD\config-windows"
Get-ScheduledTaskInfo -TaskName PowerBridge
Get-Content config-windows\pairing.json
```

The installer copies the runtime and configuration to `C:\ProgramData\PowerBridge`, restricts that directory to Administrators/SYSTEM, registers a startup task, and allows the configured TCP port only on the Private profile from LocalSubnet. It does not open an Internet-facing port.

Import Windows' pairing file into the app too. **Use the same `--machine-id` as Linux.** The app merges OS endpoints while retaining their separate certificates and secrets. Windows/Linux can have the same IP/port; the app checks each paired certificate. The certificate mismatch for an inactive OS is expected and never bypassed.

Enable real operations by editing `C:\ProgramData\PowerBridge\config.json` as Administrator, changing `dry_run` to `false`, then:

```powershell
Stop-ScheduledTask -TaskName PowerBridge
Start-ScheduledTask -TaskName PowerBridge
```

If startup fails, stop the task and run its command in an elevated terminal to see errors:

```powershell
python C:\ProgramData\PowerBridge\server.py --config C:\ProgramData\PowerBridge\config.json
```

UEFI variable access requires administrator/System privilege and firmware support. BitLocker recovery or a preboot PIN can interrupt unattended switching; have your recovery method available and test locally. No force-close flag is used on Windows, so applications may block shutdown to protect unsaved work.

## 3. Wake-on-LAN

### Standard build: always-on relay

The relay must remain powered on and connected to the target PC's LAN. Install the companion on that separate device with `--relay`; its API only accepts wake requests for the locally configured MAC. It cannot remotely run arbitrary commands or shut itself down through this API.

Example on a Linux relay; `.20` is the relay IP and the MAC is still your PC's Ethernet MAC:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r companion/requirements.txt
.venv/bin/python companion/setup.py --dir config-relay --relay \
  --host 192.168.1.20 --name "Anas PC" --machine-id anas-pc \
  --mac AA:BB:CC:DD:EE:FF --broadcast 192.168.1.255
sudo bash scripts/install-linux.sh "$PWD/config-relay"
```

Import the relay's `pairing.json` into the same PC profile. After checking pairing, set `dry_run` to `false` in `/etc/powerbridge/config.json` on the relay and restart its service. Test-mode relay requests explicitly report that no packet was sent.

The relay does not need to be a Mac. Do not install it only on the PC you want to wake: a powered-off service cannot send packets.

### Optional direct wake: no relay

Apple requires its restricted `com.apple.developer.networking.multicast` entitlement to send iOS broadcast traffic. The default project omits that entitlement so ordinary development signing can build the control app.

Once Apple grants the entitlement and your provisioning profile contains it:

1. In the PowerBridge target's Build Settings, set **Code Signing Entitlements** to `DirectWake.entitlements` for Debug and Release.
2. Add `DIRECT_WOL` to **Active Compilation Conditions** for both configurations; keep existing conditions.
3. Regenerate/download the authorized provisioning profile and rebuild.
4. Use the iPhone on the PC's Wi-Fi/LAN and allow Local Network access. Do not add a relay endpoint if you want to use direct wake; the app prefers a paired relay.

The direct code sends three standard magic packets to the configured directed broadcast, UDP port 9. Sending successfully does not prove the NIC received the packet. Guest Wi-Fi isolation and VLAN boundaries can block it. A VPN usually does not carry LAN broadcasts; use the relay for away-from-home wake.

### Hardware settings

Enable Wake-on-LAN/PCIe wake in your motherboard firmware and Ethernet adapter settings, as supported by your model. Some firmware power-saving options disable standby power to the NIC. Full shutdown wake depends on firmware/NIC/driver support; it is not guaranteed, particularly with Windows power-state differences. Do not change unrelated firmware/security settings to troubleshoot.

On Linux, inspect and, where supported, enable magic-packet wake (replace `enp3s0`):

```bash
sudo ethtool enp3s0
sudo ethtool -s enp3s0 wol g
```

This may not persist after reboot; set the equivalent wake setting in the network manager/driver configuration appropriate to your system. Test after shutdown from **each** OS because either driver can change NIC wake behavior.

## 4. What boot selection does

| App action | Behavior |
|---|---|
| Default + Restart/Shutdown | Uses existing firmware behavior; does not erase an already-set BootNext |
| Linux/Windows + Restart | At countdown expiry, sets BootNext then restarts |
| Linux/Windows + Shutdown | At countdown expiry, sets BootNext then shuts down; that selection applies on the next start |
| Default + Wake | Sends the wake packet only |
| Linux/Windows + Wake | Wakes normally, waits up to 150 seconds for the PC companion, then schedules a restart if the current OS differs |
| Cancel | Cancels an action still in this companion's countdown; nothing is written to firmware until expiry |

A magic packet cannot encode an OS choice. For a single direct boot into the desired OS, choose it before shutdown. When already off, the wake-and-switch flow may involve two boots. **Keep the app in the foreground.** Leaving it cancels further polling/switch orchestration; it does not recall packets or commands already sent. A Windows update, GRUB prompt, disk-encryption prompt, missing companion, or network delay can prevent the second step.

If firmware selection fails, the companion does not proceed to shutdown/restart. If firmware selection succeeds but the later power command fails, BootNext may remain set; the activity message explains this. `Default` deliberately does not erase settings written by other software. Clear an unwanted one-time selection locally using appropriate firmware tools.

## 5. Build and export an IPA

Open `ios/PowerBridge.xcodeproj` directly; no third-party iOS packages or XcodeGen installation are needed. `project.yml` is also provided if you prefer regenerating the project with XcodeGen.

For a simulator compilation check on a Mac:

```bash
bash scripts/build-ios.sh --simulator
```

For an iPhone archive using your Apple team:

```bash
TEAM_ID=YOUR_APPLE_TEAM_ID bash scripts/build-ios.sh
```

Open `build/PowerBridge.xcarchive` in Xcode, choose **Distribute App**, and use the distribution method supported by your account and provisioning. Export the signed `.ipa` and install it on its registered device. Apple Developer Program membership is required for relevant distribution methods; development runs via a personal team have different limits. Enable Developer Mode when required by Apple.

The included GitHub Actions workflow compiles an **unsigned iPhone-device IPA** on a hosted macOS runner. Download `PowerBridge-unsigned-IPA` from a successful run, extract it, and sign `PowerBridge-unsigned.ipa` in ESign using your matching certificate/profile. It needs no signing secret in GitHub. Put the contents of this folder at the root of a GitHub repository, including `.github`, to run it. The workflow has not been executed here; no GitHub account or Apple certificate was accessed. See [Linux + ESign instructions](docs/LINUX-ESIGN.md).

## 6. Security and operations

- Keep the API on a trusted LAN or private VPN. Never configure public router port-forwarding for it.
- The companion is privileged because shutdown and firmware operations require it. Pairing secrets grant power control; protect the configuration directory and source/runtime files.
- The iPhone verifies the exact SHA-256 certificate fingerprint supplied in the private pairing file. It does not accept arbitrary self-signed certificates or redirects.
- Requests sign method, path, timestamp, nonce, and raw body digest. The server rejects timestamps outside 60 seconds and repeated nonces during the service process lifetime. Nonce state is in memory and resets on service restart.
- Clocks on iPhone and PC must be synchronized. A certificate/secret rotation requires reimporting the new pairing file.
- Pairing is provisioned locally; no open network enrollment endpoint exists. There is no cloud account, analytics, or command execution endpoint.
- Event history and pending countdowns are in memory. Restarting the companion cancels its pending countdowns and clears history. Linux journal logs remain subject to system retention settings.
- A timeout after sending a command means its outcome may be uncertain. Refresh/check the PC before retrying.
- The app does not claim “offline” proves the power is off: unreachable can also mean firewall, pairing, certificate, network, or service failure.
- Forgetting a computer only deletes this phone's copy. To revoke other copies, stop the service, generate a new config directory/certificate/secret, replace the installed config files, and re-pair trusted devices. Restrict permissions again after copying.

## 7. Verification and acceptance

Automated tests run here:

```bash
python3 -m unittest discover -s companion/tests -v
```

The 22 tests cover HMAC validity/tampering, timestamp rejection, concurrent replay rejection, malformed inputs, countdown cancellation, test-mode isolation, boot-before-power ordering, firmware-error abort, relay restrictions, WOL packet bytes, TLS HTTP integration, and pairing certificate fingerprints. Platform operations are mocked; tests never power off the development computer.

Before using real actions:

1. Run the macOS build workflow or build in Xcode; resolve any compiler/signing issue.
2. Pair on a trusted LAN. Confirm each OS connects with its own endpoint and an incorrect pairing is rejected.
3. In test mode, schedule shutdown, cancel it, and let another countdown expire. Confirm no power/firmware change occurred.
4. Enable live mode and test shutdown/restart while at the PC with saved work.
5. Verify each mapped boot entry locally, then test a one-time switch in each direction.
6. Test wake from shutdown after both Windows and Linux, then test the optional wake-and-switch flow.
7. Test your VPN path separately if remote-away-from-home use is needed.

## Updates and uninstall

Linux: stop `powerbridge`, replace only `server.py`/`platform_ops.py` under `/opt/powerbridge` as root, keep `/etc/powerbridge` intact, then restart. For uninstall:

```bash
sudo systemctl disable --now powerbridge
sudo rm /etc/systemd/system/powerbridge.service
sudo systemctl daemon-reload
sudo rm -r /opt/powerbridge /etc/powerbridge
```

Remove only the firewall rule you added for this app if no longer needed. Deleting the configuration revokes that running installation and removes its saved keys.

Windows: stop the task before updating files under `C:\ProgramData\PowerBridge`. Keep its three config/certificate/key files to preserve pairing. For uninstall (Administrator):

```powershell
Stop-ScheduledTask -TaskName PowerBridge
Unregister-ScheduledTask -TaskName PowerBridge -Confirm:$false
Remove-NetFirewallRule -DisplayName 'PowerBridge LAN'
Remove-Item "$env:ProgramData\PowerBridge" -Recurse
```

## Primary references

- Apple: [Distribute to registered devices](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices).
- Apple: [Local network privacy and broadcast entitlement](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).
- Apple: [Multicast networking entitlement](https://developer.apple.com/news/?id=0oi77447).
- UEFI: [Boot Manager, BootNext semantics](https://uefi.org/specs/UEFI/2.11/03_Boot_Manager.html).
- Microsoft: [Read firmware variables](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getfirmwareenvironmentvariablew) and [write firmware variables](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setfirmwareenvironmentvariableexw).
- efibootmgr: [Upstream project and one-time boot usage](https://github.com/rhboot/efibootmgr/blob/main/README.md).
- Microsoft: [Wake-on-LAN power-state behavior](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/wake-on-lan-feature).
- Linux kernel: [ethtool wake settings](https://www.kernel.org/doc/html/v6.15/networking/ethtool-netlink.html).
