# Development notes

## TCC identity comes from the responsible process (verified 2026-07-28)

macOS decides which program a permission applies to by a kernel-tracked *responsible process*, assigned at spawn and inherited down the tree, not by the signature of the binary making the call. Measured with `responsibility_get_pid_responsible_for_pid`, three ways of starting the same python probe:

| launched | responsible |
|---|---|
| directly from a shell | ghostty |
| through Imp's launcher | ghostty (Imp itself is attributed to ghostty too) |
| through Imp, spawned with responsibility disclaimed | Imp |

So being a signed app bundle earns nothing when something else spawned you, which is why a terminal-launched Imp was a pass-through until it learned to re-spawn itself with `responsibility_spawnattrs_setdisclaim`. Under launchd the first spawn is already responsible, so the extra process only appears on the terminal path. Neither responsibility function is declared anywhere in the SDK, but both are exported by libSystem, so `CImp` declares them itself (see below).

The same finding is why `--grant` and `--status` must run as Imp: a wizard that requested permissions while attributed to a terminal would grant *the terminal* and report success.

Verification needs a fresh process, because a grant made after launch is invisible to the process that requested it (Screen Recording never updates in place, and Accessibility is not reliable either). Imp spawns a short-lived copy of itself per check, which is the same thing it already does for everything else.

The re-spawn must use Imp's real path from `proc_pidpath`, not `argv[0]`. A shell that finds a binary on `PATH` passes the bare name as `argv[0]` (verified with a native probe: through `PATH` it reads `Probe2`, by full path `/tmp/argv0probe/Probe2`), and `posix_spawn` does no `PATH` lookup, so passing `CommandLine.arguments` through made `Imp --status` fail with `cannot run Imp: No such file or directory` the moment the installer's `~/.local/bin/Imp` link existed. Nothing caught it earlier because every call until then named the binary in full.

Children go through `posix_spawnp` for the same reason, so `Imp pytest` resolves on `PATH` like a shell command; `posix_spawn` would have needed every command named in full. A shebang script needs nothing extra, since the kernel handles `#!` inside the exec.

## Grants survive rebuilds, and that is the point (verified 2026-07-28)

A Swift Imp built from scratch, signed fresh, and placed at a different path inherited an existing Accessibility grant with no prompt, because the designated requirement names the bundle identifier and team and nothing else. The same held for a `ditto` archive extracted somewhere else entirely, with `codesign --verify --strict` passing on the extracted copy. That is what makes curl-installed updates silent: new version, same grants, no second row in Settings.

Since `curl` does not set the quarantine attribute, Gatekeeper never assesses a curl-installed app, so notarization is unnecessary for this distribution. A browser download would need it.

## The `CImp` target, and what it is for (2026-07-28)

Two libSystem functions Imp needs, `responsibility_get_pid_responsible_for_pid` and `responsibility_spawnattrs_setdisclaim`, are exported but undeclared. Both appear in `$(xcrun --show-sdk-path)/usr/lib/libSystem.B.tbd`, and a grep over the SDK's headers finds neither, so they link but Swift cannot see them. Imp used to reach them with `dlsym` plus `unsafeBitCast` through hand-written `@convention(c)` typealiases, which nothing checks: a wrong signature there is undefined behaviour with no diagnostic. Declaring them in `Sources/CImp/include/shim.h` gets the compiler to check the calls instead.

That fallback was also worse than doing nothing. When the lookup failed, `amImp()` returned `true`, so Imp would claim to be the responsible process while running children under the terminal's identity, and every line `--status` printed would be wrong. A missing symbol should stop the program, and now does, at load.

`CImp` holds three things, and each is there because C reaches something Swift cannot:

- the two `extern` declarations above.
- `imp_exit_status`, wrapping `WIFEXITED`, `WEXITSTATUS` and `WTERMSIG`. Those are macros, which Swift cannot import at all, so `wait` used to decode the status bits by hand.
- `imp_spawn`, which does the `posix_spawnattr` dance and passes `environ` straight to `posix_spawnp`. Swift was rebuilding the environment out of `ProcessInfo.processInfo.environment`, a dictionary round-trip that reorders entries and cannot represent duplicate keys. A child now sees this process's environment exactly, multi-line values included (checked by comparing a child's `os.environ` against the parent's: 139 variables, identical).

### API notes need `[system]` on the module

`CImp.apinotes` gives the shim honest nullability and Swift-shaped names. It applies only when the module map declares `module CImp [system]`. With a plain `module CImp`, the annotations are silently ignored: `swift build` reported `cannot find 'responsiblePid' in scope`, and adding `-Xcc -fapinotes-modules` to the target's `swiftSettings` changed nothing. Marking the module `[system]` fixed it with no compiler flags at all, which is also how `swift-synthesize-interface` behaves, where `-I` shows the raw C names and `-Isystem` shows the annotated ones.

Renaming through API notes leaves a good diagnostic rather than a mystery: calling the old name gives `'imp_exit_status' has been renamed to 'exitStatus(of:)'`.

The cost of `[system]` is that clang stops reporting warnings from those headers, which is worth remembering if the shim ever grows past a page.

### Versioning

`impVersion` in `main.swift` is the only copy; the build passes it to `build_app` as `CFBundleShortVersionString`. Nothing enforces that, so a build that skips the argument produces a bundle whose plist disagrees with `Imp --version`. Worth fixing when `fastship` grows a Swift flavour and owns the release step.

## Permission facts worth not re-learning

- An Accessibility grant also confers listen-event access (`CGPreflightListenEventAccess` returns true with only Accessibility granted, verified twice, once under Imp's own identity). Input Monitoring is therefore not offered as a separate permission.
- Categories are otherwise independent: Screen Recording stayed false when Accessibility was granted.
- Carbon's `RegisterEventHotKey` needs no permission at all. The system watches the keyboard and delivers only your combo, so there is no stream to protect. Event taps and synthetic input are what need Accessibility.
- macOS shows each dialog once per app per category. After a denial the request API returns immediately with no UI, so a wizard that only calls request and waits will hang forever on exactly the users who fat-fingered "Don't Allow". Hence request, wait two minutes, then print what to do by hand. An earlier version auto-opened the Settings pane; removed 2026-07-28 as cleverness serving a rare case.
- `tccutil reset Accessibility com.answerdotai.imp` revokes one category for one bundle, which is how to test the grant flow repeatedly without deleting Settings rows by hand.
- Notifications are not TCC, so `tccutil` cannot reset them. The reset for testing is in the Notifications Settings pane: right-click the Imp row, then "Reset Notifications", which returns the state to not-determined so the dialog fires again (found 2026-07-28; the Delete-key method blogs describe did not apply).
## Why `--grant` asks one at a time

Simultaneous TCC requests collide: asking for accessibility and input monitoring together produced only the accessibility dialog (verified live 2026-07-27, in the Python predecessor). `--grant` therefore walks its list one permission at a time and confirms each before starting the next, and prints the Settings deep link as an `open` command whenever the prompt does not arrive.


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




## Notifications and alerts (2026-07-28)

Notification Center refuses a process whose bundle it cannot find, and a window needs an application to own it, so neither is reachable from the Python that macmage runs. Imp has a bundle and an identity already, which is why `--notify` and `--alert` live here rather than there. A notification is about 20ms end to end, including the process spawn.

`UNUserNotificationCenter` works from a plain command-line binary inside the bundle, with no `NSApplication`. Its calls are asynchronous, so each one is a `DispatchSemaphore` wait, with the result left in a small box class because a captured `var` is not `Sendable` under Swift 6.

`NSAlert` does need `NSApplication`, but only `.shared` with the accessory activation policy, which does not conflict with anything: the alert is a fresh short-lived process. Its function is `@MainActor`, which top-level code satisfies.

The bundle now sets `LSUIElement` rather than `LSBackgroundOnly`, since a background-only app cannot bring a window to the front. No Dock icon either way, and the change does not touch the designated requirement, so grants survive it.

`notifications` is the third permission, and adding it showed the `Perm` table extends cleanly, except that `pane` had to become a whole Settings URL: the notification pane is `x-apple.systempreferences:com.apple.Notifications-Settings.extension`, not an anchor under Privacy and Security.

The authorization "prompt" on macOS is a banner in the top right, not a modal: clicking it opens the Settings pane, and `requestAuthorization`'s completion fires with `granted=false` at that moment, before the person has decided anything (observed live 2026-07-28). So a false completion is not a denial and must fall back to polling; only true is definitive, and `--grant` treats it as such (`answer == true || waitFor(...)`). This also makes the tempting `getNotificationSettings`-for-denied shortcut suspect: whether a banner click-through records `.denied` is unknown, and if it does, the shortcut would report failure to a person who is mid-way to granting.
