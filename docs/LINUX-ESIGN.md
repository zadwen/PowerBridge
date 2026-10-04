# Linux + GitHub Actions + ESign

You do not need to own a Mac. GitHub's macOS runner compiles the app; your Linux browser manages the repository and downloads the result; ESign signs it on your iPhone.

The source ZIP is not an IPA. The first successful cloud build will produce `PowerBridge-unsigned.ipa`. That build has not been run for you: this delivery does not have a connected GitHub repository or access to Apple's build tools.

## 1. Put the project on GitHub from Linux

Create an empty GitHub repository called `PowerBridge`. Extract this ZIP, open a terminal **inside the extracted PowerBridge directory**, and run:

```bash
git init
git add .
git commit -m "Add PowerBridge iPhone and PC apps"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/PowerBridge.git
git push -u origin main
```

Replace `YOUR_USERNAME`. Use your normal GitHub authentication (for example GitHub CLI login or a personal access token), not your account password for HTTPS Git. Git may ask you to configure a commit name/email if you have not done so before.

Push only the supplied source project, before creating PC pairing configurations. Never commit your ESign certificate/private key, certificate password, provisioning profile, or PC pairing files. The build does not need them. `.gitignore` covers the generated companion configs but is not a substitute for checking what you upload.

At the repository root you must see `ios`, `scripts`, `companion`, and the hidden `.github/workflows/ios-build.yml`. If everything is nested inside an extra `PowerBridge` folder, the workflow will not run. Use `git add .` as shown so the hidden workflow folder is included.

## 2. Run the build

1. Open the GitHub repository in your browser.
2. Select **Actions → Build iPhone IPA**.
3. The push starts a run automatically. To rerun manually, select **Run workflow** on the main branch.
4. Wait for `iphone-ipa` to succeed. The separate `companion` job checks the PC service.
5. Open the successful workflow run, scroll to **Artifacts**, and download **PowerBridge-unsigned-IPA** while signed into GitHub.
6. Extract the downloaded artifact ZIP. Inside is **PowerBridge-unsigned.ipa**; the `.sha256` file is a checksum, not the app.

The job uses `iphoneos`, a generic iOS device destination, and arm64, then validates the app metadata and ZIP structure. It does not build a simulator app. It neither signs nor uploads the app to Apple. GitHub runner availability and account usage limits still apply.

If the run fails, open its failed step and copy the compiler error text. There will be no valid IPA artifact until the build succeeds. Do not rename the source ZIP to `.ipa`.

## 3. Sign in ESign on your iPhone

Transfer/download `PowerBridge-unsigned.ipa` to your iPhone Files app, then import it into ESign. Use your existing signing flow to select your valid certificate and its matching provisioning profile, sign the app, and install the **signed** output. Menu wording depends on your ESign version.

The profile must permit the app's bundle identifier (`com.anas.PowerBridge`, or an identifier you correctly change during signing), entitlements, and intended device/distribution method. A certificate alone is not enough. A wildcard profile may permit the bundle ID; an explicit profile must match it. Keep a stable bundle ID/team across updates to preserve app identity and Keychain pairing.

A revoked/expired certificate or mismatched profile will prevent installation or launch regardless of whether compilation succeeded. Follow iOS trust/Developer Mode prompts only when applicable to your signing method. No Apple credentials or private signing files need to be shared with this project or uploaded to GitHub.

## 4. Set up the PC on Linux

Follow README section 1 for the Linux companion, import its private pairing file into PowerBridge, then test countdown/cancellation before enabling actual power actions. Install the Windows companion too if you want control when Windows is running.

## Wake-up limitation with a regular signing certificate

The standard IPA supports shutdown, restart, and mapped boot selection. Wake uses a paired always-on relay. A normal valid signing certificate does **not** by itself authorize Apple's restricted multicast/broadcast entitlement.

Direct iPhone broadcast wake requires that entitlement to be authorized in the provisioning profile, the direct-wake source condition enabled, and the entitlement retained in the final signature. This default cloud build intentionally has no direct-wake entitlement and uses the relay route described in README section 3. Do not enable restricted entitlements merely by adding plist keys to ESign; the profile must authorize them.

## References

- GitHub macOS runners: https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- Download artifacts: https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts
- Apple profiles, app IDs, and entitlements: https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
- Apple's multicast requirements: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy

The ESign handoff here uses the user's existing signing setup; its exact UI has not been tested in this environment.
