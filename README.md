# Imp

> A small macOS app you should never use that holds permission grants on behalf of anything you run through it.

macOS asks your permission before a program can watch the keyboard, control other apps, or record the screen. Every program has to ask separately. macOS remembers each grant against one specific program, and silently drops it when that program is rebuilt or its virtual environment moves. For a developer running scripts and automation tools, this means the same dialogs over and over, a Settings list full of entries called `python3.13`, and things that stop working for no visible reason.

Imp is a small signed app that holds those permissions on behalf of anything you run through it.

    Imp python watch_keys.py

The script now has whatever permissions Imp has. Nothing needed to be signed, bundled, or granted separately, and nothing breaks when you rebuild it or move it.

## Install

    curl -fsSL https://raw.githubusercontent.com/AnswerDotAI/imp/main/install.sh | sh

That puts `Imp.app` in `~/Applications` and links `Imp` into `~/.local/bin`. Apple Silicon only.

Then grant it what you need, once:

    Imp --grant accessibility

A permission applies only to processes started after you grant it, so restart whatever you are running once the grant is in place.

Upgrading is the same command again, and keeps every grant. To remove Imp, delete `~/Applications/Imp.app` and the `~/.local/bin/Imp` link. Its entries stay in System Settings, Privacy & Security until you remove them there with the minus button.

## Use

    Imp <command> [args...]     run a command with Imp's permissions
    Imp --grant <a,b>           get the named permissions, one at a time
    Imp --check <a,b>           exit 0 if all are granted, else 1
    Imp --status                report every permission's state
    Imp --version               print the version
    Imp --notify <title> [body]  post a notification
    Imp --alert <title> [body] [button...]   show a message box, and exit with the button's index
    Imp --web <title> <url|file|->           show a web page in a panel; "-" reads HTML from stdin, Esc closes
    Imp --pick <title> <item...>             choose by digit (up to ten items); the index goes to stdout
    Imp --show <title>                       show stdin in a scrollable monospaced panel

Imp finds the command the way a shell does, so `Imp pytest` works as well as `Imp /path/to/pytest`, and an executable script with a shebang runs as `Imp ./watch_keys.py`. Whatever it runs keeps Imp's permissions, including anything that program starts in turn.

Permission names are `accessibility` (watching input, controlling other apps, sending synthetic keystrokes), `screen` (screen recording, and reading window titles), and `notifications`.

`--grant` asks for one permission at a time and confirms each before moving to the next. It asks macOS to show its own dialog, then waits up to two minutes for the permission to really work. macOS shows each dialog only once per category, so if you dismissed it in the past no dialog can appear: after the wait, Imp prints the exact `open` command for the right Settings pane and what to switch on, and exits nonzero.

`--check` is for scripts. It prints nothing and only sets an exit code.

`--notify`, `--alert`, `--web`, `--pick`, and `--show` exist because macOS will not let an unbundled process speak to the user at all: Notification Center refuses a process with no bundle, and a window needs an application to own it. Since Imp is a bundled application, anything running under it can borrow that. A notification takes about 20ms and needs the `notifications` permission; an alert blocks until its box is dismissed, and exits with the index of the button pressed, so `Imp --alert "Delete?" "" Delete Cancel` is a usable confirmation in a script. A pick prints the chosen index to stdout and exits 1 when dismissed, so `i=$(Imp --pick ...)` reads naturally in shell. Esc or the close button dismisses any of the panels.

`--status` reports the state of every permission, and which program macOS thinks it is talking to:

    $ Imp --status
    running as: Imp
    accessibility : true
    screen        : false
    notifications : true

`running as` should always say Imp. Anything else means Imp failed to make itself the responsible process, and the permissions reported belong to whatever launched Imp instead.

For a background agent, put Imp at the front of a launchd plist's `ProgramArguments`:

    <key>ProgramArguments</key>
    <array>
      <string>/Users/you/Applications/Imp.app/Contents/MacOS/Imp</string>
      <string>/path/to/venv/bin/python</string>
      <string>-m</string>
      <string>youragent</string>
    </array>

## How it works

macOS decides which program a permission check applies to by walking up the process tree to a responsible process, not by looking at the binary that made the call. That is why a Python script started from a terminal is treated as the terminal, and why every script you run inherits your terminal's permissions today.

Imp makes itself the responsible process and then runs your command as a child, so your command is treated as Imp. When Imp is started from a terminal it would ordinarily inherit the terminal's identity instead, so it re-launches itself once with responsibility disclaimed, which macOS supports for exactly this purpose.

Permissions are recorded against a code signature requirement rather than a hash of the binary. Imp's requirement is its bundle identifier plus the Answer.AI team ID, so a new version installed over the old one keeps every permission, with no second entry in Settings and no prompt.

## Security

Anything you run through Imp gets everything Imp has been granted. That is the whole point, and it means Imp is exactly as trustworthy as the things you choose to run through it. Grant it only what you need, and don't hand `Imp` to code you wouldn't hand your keyboard to.

## Build from source

Needs Xcode and, for signing, a Developer ID certificate.

    swift build -c release
    swift test

The helpers in `swifttool.py` (currently in the `macmage` repo) build the package, assemble and sign the bundle, and produce the `ditto` archive in `dist/`. An unsigned or ad-hoc-signed build works, but its permissions are keyed to the exact binary, so they are lost on every rebuild.

The `Imp` target is Swift. Alongside it, `CImp` is a small C target holding the things Swift cannot see: two libSystem functions Apple exports without declaring in any header, and the `wait(2)` status macros. `Sources/CImp/include/CImp.apinotes` then annotates that header so Swift imports it with real optionality and readable names, which is worth reading before adding anything to the shim.

The version lives in `Sources/Imp/main.swift` as `impVersion`, and the build stamps it into the bundle's `Info.plist`.
