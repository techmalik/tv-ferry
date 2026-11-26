#!/bin/bash
# End-to-end test: runs a throwaway FTP server (pyftpdlib) and pushes real files through
# TV Ferry's transfer queue via its --selftest mode. Checks renaming, junk filtering,
# NFC normalisation, folder structure, resume, skip-existing and error messages.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN="$PWD/.build/release/TVFerry"
WORK=$(mktemp -d)
trap 'kill ${FTP_PID:-0} 2>/dev/null || true; rm -rf "$WORK"' EXIT

python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" -q install pyftpdlib
mkdir -p "$WORK/tv" "$WORK/src/Season 1"
cat > "$WORK/ftpd.py" <<'PY'
import sys
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler
from pyftpdlib.servers import FTPServer
a = DummyAuthorizer(); a.add_user("tv", "secret", sys.argv[1], perm="elradfmwMT")
H = FTPHandler; H.authorizer = a; H.banner = "220 test"
FTPServer(("127.0.0.1", 28782), H).serve_forever()
PY
"$WORK/venv/bin/python3" -I "$WORK/ftpd.py" "$WORK/tv" >/dev/null 2>&1 &
FTP_PID=$!
sleep 1.5

cd "$WORK/src"
head -c 52428800 /dev/urandom > "Movie (2024).mkv"
python3 -c "import unicodedata; open(unicodedata.normalize('NFD','Amélie.mp4'),'wb').write(b'x'*1000)"
echo sub > "Q: What? <cut>.srt"
echo ep > "Season 1/Ep 1.mkv"; echo junk > "Season 1/.DS_Store"; echo junk > "Season 1/._Ep 1.mkv"

fail() { echo "FAIL: $*"; exit 1; }
run() { "$BIN" --selftest 127.0.0.1 28782 tv "$@"; }

echo "== upload"
run secret /Movies "Movie (2024).mkv" Am*.mp4 "Q: What? <cut>.srt" "Season 1"
cmp "Movie (2024).mkv" "$WORK/tv/Movies/Movie (2024).mkv" || fail "movie differs"
[[ -f "$WORK/tv/Movies/Q - What (cut).srt" ]] || fail "unsafe name not sanitised"
[[ -f "$WORK/tv/Movies/Season 1/Ep 1.mkv" ]] || fail "folder structure lost"
[[ ! -e "$WORK/tv/Movies/Season 1/.DS_Store" && ! -e "$WORK/tv/Movies/Season 1/._Ep 1.mkv" ]] || fail "junk uploaded"
python3 -c "import os,unicodedata,sys; n=[f for f in os.listdir(sys.argv[1]) if f.startswith('Am')][0]; sys.exit(0 if unicodedata.is_normalized('NFC',n) else 1)" "$WORK/tv/Movies" || fail "not NFC"

echo "== resume"
head -c 20000000 "Movie (2024).mkv" > "$WORK/tv/Movies/Movie (2024).mkv"
run secret /Movies "Movie (2024).mkv" | grep -q "resumedFrom=20000000" || fail "did not resume"
cmp "Movie (2024).mkv" "$WORK/tv/Movies/Movie (2024).mkv" || fail "resumed file differs"

echo "== skip existing"
run secret /Movies "Movie (2024).mkv" | grep -q "Already on TV" || fail "did not skip"

echo "== wrong password"
out=$(run wrong /Movies "Movie (2024).mkv" || true)
grep -q "refused the login" <<<"$out" || fail "bad login message: $out"

echo "All end-to-end checks passed."
