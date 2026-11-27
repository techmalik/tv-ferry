#!/bin/bash
# End-to-end test: runs a throwaway FTP server (pyftpdlib) and pushes real files through
# TV Ferry's transfer queue via its --selftest mode. Checks renaming, junk filtering,
# NFC normalisation, folder structure, resume, skip-existing and error messages.
set -euo pipefail
export TVFERRY_STATE_DIR="$(mktemp -d)"   # keep the partial-upload record out of your real settings
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

grep -q "Amélie.mp4 .*verified=true" <<<"$(run secret /Fresh Am*.mp4)" || fail "upload of accented name not verified"

echo "== a different, smaller file with the same name is replaced, not resumed onto"
head -c 20000000 /dev/urandom > "$WORK/tv/Movies/Movie (2024).mkv"
out=$(run secret /Movies "Movie (2024).mkv")
grep -q "resumedFrom=0 verified=true" <<<"$out" || fail "resumed onto an unrelated file: $out"
cmp "Movie (2024).mkv" "$WORK/tv/Movies/Movie (2024).mkv" || fail "replaced file differs"

echo "== resume after an interrupted upload"
rm "$WORK/tv/Movies/Movie (2024).mkv"
TVFERRY_DEBUG=1 TVFERRY_LIMIT_RATE=8M run secret /Movies "Movie (2024).mkv" >/dev/null 2>&1 &
SELF_PID=$!
sleep 2.5
pkill -f "curl .*127.0.0.1:28782/Movies/Movie" || true   # stop the upload part-way
wait "$SELF_PID" 2>/dev/null || true
# Let the server finish writing whatever was in flight when curl was stopped.
partial=-1
for _ in 1 2 3 4 5 6 7 8 9 10; do
  now=$(stat -f %z "$WORK/tv/Movies/Movie (2024).mkv"); [[ "$now" == "$partial" ]] && break; partial=$now; sleep 0.5
done
(( partial > 0 && partial < 52428800 )) || fail "interruption didn't leave a partial file ($partial bytes)"
out=$(run secret /Movies "Movie (2024).mkv" || true); grep -q "resumedFrom=$partial verified=true" <<<"$out" || fail "did not resume from $partial: $out / $(cat "$TVFERRY_STATE_DIR"/*.json 2>&1)"
cmp "Movie (2024).mkv" "$WORK/tv/Movies/Movie (2024).mkv" || fail "resumed file differs"

echo "== skip existing"
run secret /Movies "Movie (2024).mkv" | grep -q "Already on TV" || fail "did not skip"

echo "== wrong password"
out=$(run wrong /Movies "Movie (2024).mkv" || true)
grep -q "refused the login" <<<"$out" || fail "bad login message: $out"

echo "== video the TV may not play (full-range colour, level 5.0) is converted"
if command -v ffmpeg >/dev/null; then
  ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=30:duration=3 -f lavfi -i sine=duration=3 \
    -pix_fmt yuvj420p -c:v libx264 -level:v 5.0 -c:a aac -shortest "Clip.mov"
  "$BIN" --check-video "Clip.mov" | grep -q "May not play" || fail "problem video not detected"
  out=$(run secret /Movies "Clip.mov" || true)
  grep -q "needsChoice" <<<"$out" || fail "did not ask before converting: $out"
  TVFERRY_AUTOCONVERT=1 "$BIN" --selftest 127.0.0.1 28782 tv secret /Movies "Clip.mov" | grep -q "done | Clip.mov -> /Movies/Clip.mp4" || fail "auto-convert failed"
  "$BIN" --check-video "$WORK/tv/Movies/Clip.mp4" | grep -q ": OK" || fail "converted copy still flagged"
else
  echo "(ffmpeg not installed: skipping conversion test)"
fi

echo "== network debugging (adb), against a stand-in adb that keeps the TV's storage in a folder"
mkdir -p "$WORK/sdcard" "$WORK/fakeadb"
cat > "$WORK/fakeadb/adb" <<'SH'
#!/bin/bash
# Stand-in for Google's adb: /sdcard is a local folder; FAKE_ADB_STATE=unauthorized/refused simulates a TV that hasn't allowed this Mac.
[[ "$1" == "-s" ]] && shift 2
case "$1" in
  start-server) exit 0 ;;
  connect)
    [[ "${FAKE_ADB_STATE:-}" == "refused" ]] && { echo "failed to connect to '$2': Connection refused"; exit 0; }
    echo "connected to $2" ;;
  get-state)
    [[ "${FAKE_ADB_STATE:-}" == "unauthorized" ]] && { echo "error: device unauthorized." >&2; exit 1; }
    echo device ;;
  shell)
    cmd="${2//\/sdcard/$FAKE_SDCARD}"; cmd="${cmd//stat -c %s/stat -f %z}"
    [[ "$cmd" == am\ * ]] && exit 0
    exec /bin/sh -c "$cmd" ;;
  push) dest="${3/#\/sdcard/$FAKE_SDCARD}"; mkdir -p "$(dirname "$dest")"; cp "$2" "$dest" ;;
  *) echo "unknown: $*" >&2; exit 1 ;;
esac
SH
chmod +x "$WORK/fakeadb/adb"
adb_run() { TVFERRY_DEBUG=1 TVFERRY_ADB="$WORK/fakeadb/adb" FAKE_SDCARD="$WORK/sdcard" "$BIN" --selftest-adb 127.0.0.1 5555 "$@"; }
out=$(adb_run /Movies "Movie (2024).mkv" "Q: What? <cut>.srt" "Season 1" || true)
grep -q "done | Movie (2024).mkv -> /Movies/Movie (2024).mkv | 52428800/52428800 resumedFrom=0 verified=true" <<<"$out" || fail "adb upload: $out"
cmp "Movie (2024).mkv" "$WORK/sdcard/Movies/Movie (2024).mkv" || fail "adb copy differs"
[[ -f "$WORK/sdcard/Movies/Q - What (cut).srt" && -f "$WORK/sdcard/Movies/Season 1/Ep 1.mkv" ]] || fail "adb names or folders wrong"
grep -q "Movies" <<<"$out" || fail "adb listing missing"
adb_run /Movies "Movie (2024).mkv" | grep -q "Already on TV" || fail "adb did not skip existing"
out=$(FAKE_ADB_STATE=unauthorized adb_run /Movies "Movie (2024).mkv" || true)
grep -q "allow debugging" <<<"$out" || fail "unauthorized message: $out"
out=$(FAKE_ADB_STATE=refused adb_run /Movies "Movie (2024).mkv" || true)
grep -q "Turn on Network debugging" <<<"$out" || fail "refused message: $out"

echo "All end-to-end checks passed."
