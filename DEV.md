# Development notes

## TCC identity comes from the responsible process (verified 2026-07-28)

macOS decides which program a permission applies to by a kernel-tracked *responsible process*, assigned at spawn and inherited down the tree, not by the signature of the binary making the call. Measured with `responsibility_get_pid_responsible_for_pid`, three ways of starting the same python probe:

| launched | responsible |
|---|---|
| directly from a shell | ghostty |
| through Imp's launcher | ghostty (Imp itself is attributed to ghostty too) |
| through Imp, spawned with responsibility disclaimed | Imp |

So being a signed app bundle earns nothing when something else spawned you, which is why a terminal-launched Imp was a pass-through until it learned to re-spawn itself with `responsibility_spawnattrs_setdisclaim`. Under launchd the first spawn is already responsible, so the extra process only appears on the terminal path. Neither responsibility function is declared anywhere in the SDK (a grep over `$(xcrun --show-sdk-path)/usr/include` finds nothing), so Imp resolves both with `dlsym` and degrades gracefully if a future macOS drops them.

The same finding is why `--grant` and `--status` must run as Imp: a wizard that requested permissions while attributed to a terminal would grant *the terminal* and report success.

Verification needs a fresh process, because a grant made after launch is invisible to the process that requested it (Screen Recording never updates in place, and Accessibility is not reliable either). Imp spawns a short-lived copy of itself per check, which is the same thing it already does for everything else.

## Grants survive rebuilds, and that is the point (verified 2026-07-28)

A Swift Imp built from scratch, signed fresh, and placed at a different path inherited an existing Accessibility grant with no prompt, because the designated requirement names the bundle identifier and team and nothing else. The same held for a `ditto` archive extracted somewhere else entirely, with `codesign --verify --strict` passing on the extracted copy. That is what makes curl-installed updates silent: new version, same grants, no second row in Settings.

Since `curl` does not set the quarantine attribute, Gatekeeper never assesses a curl-installed app, so notarization is unnecessary for this distribution. A browser download would need it.

## Permission facts worth not re-learning

- An Accessibility grant also confers listen-event access (`CGPreflightListenEventAccess` returns true with only Accessibility granted, verified twice, once under Imp's own identity). Input Monitoring is therefore not offered as a separate permission.
- Categories are otherwise independent: Screen Recording stayed false when Accessibility was granted.
- Carbon's `RegisterEventHotKey` needs no permission at all. The system watches the keyboard and delivers only your combo, so there is no stream to protect. Event taps and synthetic input are what need Accessibility.
- macOS shows each dialog once per app per category. After a denial the request API returns immediately with no UI, so a wizard that only calls request and waits will hang forever on exactly the users who fat-fingered "Don't Allow". Hence request, poll briefly, then fall through to the Settings pane.
- `tccutil reset Accessibility com.answerdotai.imp` revokes one category for one bundle, which is how to test the grant flow repeatedly without deleting Settings rows by hand.
## Why `--grant` asks one at a time

Simultaneous TCC requests collide: asking for accessibility and input monitoring together produced only the accessibility dialog (verified live 2026-07-27, in the Python predecessor). `--grant` therefore walks its list one permission at a time and confirms each before starting the next, and falls back to a Settings deep link (`open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"`) whenever the prompt does not arrive.


## Code signing setup

Imp.app exists to hold macOS permission grants. macOS keys a grant to a stored rule about the program's identity, so how the bundle is signed decides whether a grant survives a rebuild.

Ad-hoc signing (`codesign -s -`) produces a rule keyed to the exact bytes: `cdhash H"..."`. Any rebuild breaks it, the row in System Settings still shows enabled while the system denies access, and toggling that row does not repair it. The only fix is deleting the row and re-approving. Signing with a Developer ID certificate instead produces a rule keyed to the bundle identifier and the team, with no hash:

    identifier "com.answerdotai.imp" and anchor apple generic
      and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]
      and certificate leaf[subject.OU] = "9T4M7L8547"

Verified 2026-07-27: editing the launcher source, rebuilding, and re-signing changed the code hash and left that rule byte-identical. So the launcher can be changed freely without anyone re-approving, and certificate renewal is safe too, since the rule names the team rather than the certificate.

To get the certificate: in Xcode, Settings, Accounts, add the Apple ID, select the team, Manage Certificates, then + and Developer ID Application. This takes four clicks, generates the key inside the login keychain with permission for `codesign` already granted, and needs no files handled. Confirm with `security find-identity -v -p codesigning`.

Releasing means building, signing, and committing the archive: `swifttool.zip_app` writes `dist/Imp.app.zip` with `ditto -c -k --keepParent`, and `install.sh` fetches that from GitHub raw and extracts it with `ditto -x -k`. A round trip preserves the bundle signature exactly (`codesign --verify --strict` passes on the extracted copy and the designated requirement is unchanged), which is what lets other machines inherit identifier+team grants with no certificate of their own. Plain `zip` does not: it can drop extended attributes and mangle symlinks, which invalidates the signature. Never write into the bundle after signing either, since the signature seals `Contents/Resources` and the Info.plist.


Routes that do not work, so nobody retries them:

- The App Store Connect API cannot create this certificate with any key. A team key is refused with 403 `FORBIDDEN_ERROR`, "This operation can only be performed by the Account Holder", and a team key's highest assignable role is Admin. An individual key is refused earlier still, with 401, because individual keys cannot use provisioning endpoints at all. Only a human account holder can create Developer ID certificates, through Xcode or the developer website.
- Individual App Store Connect keys are also useless for `notarytool`. Notarizing from CI needs a team key, its Issuer ID, and the account's `.p8` file, which is what those credentials are worth keeping for.
- `certtool r` can generate a keypair inside the keychain, which avoids keychain permission prompts, but it prompts interactively for every field and is awkward to drive from a script. Generating the key with a library and importing it works, at the cost of one keychain permission dialog on first use.
- A self-signed certificate would also survive rebuilds, but it needs trust settings configured before `codesign` will use it, and it cannot be notarized. A Developer ID certificate is less work and strictly more useful.


