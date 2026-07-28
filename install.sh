#!/bin/sh
# Install Imp: curl -fsSL https://raw.githubusercontent.com/AnswerDotAI/imp/main/install.sh | sh
set -eu

[ "$(uname -m)" = arm64 ] || { echo "Imp needs Apple Silicon." >&2; exit 1; }

url=${IMP_URL:-https://raw.githubusercontent.com/AnswerDotAI/imp/main/dist/Imp.app.zip}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "$url" -o "$tmp/Imp.app.zip"
mkdir -p "$HOME/Applications"
ditto -x -k "$tmp/Imp.app.zip" "$HOME/Applications"
imp="$HOME/Applications/Imp.app/Contents/MacOS/Imp"

if [ -d "$HOME/.local/bin" ]; then
    ln -sf "$imp" "$HOME/.local/bin/Imp"
    echo "Installed $HOME/Applications/Imp.app, linked as ~/.local/bin/Imp"
else
    echo "Installed $HOME/Applications/Imp.app"
    echo "For an 'Imp' command, link it somewhere on your PATH:"
    echo "  ln -s $imp /usr/local/bin/Imp"
fi

echo
"$imp" --status
