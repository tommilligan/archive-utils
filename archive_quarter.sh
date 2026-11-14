#!/usr/bin/env bash
#
# Per-quarter video/photo archive pipeline (work in progress).
#
# Usage: ./archive_quarter.sh <zipfile> <archive-name>
#   e.g. ./archive_quarter.sh ~/Downloads/Photos-1-001.zip 2025-Q1
#
# Steps:
#   1. Preflight
#   2. Check zip contains only .jpg/.mp4, wipe original/ and processed/
#      (temp dirs, deleted and recreated every run), extract to original/
#   3. Check each video's properties against the expected baseline
#   4. Copy photos, compress videos into processed/ (durations verified)
#   5. tar processed/ -> outfile
#
# Layout (paths are relative to this script):
#   original/   processed/   archive_quarter.sh
#
# Environment overrides:
#   ACCEPT_BASELINE_CHANGE=1     continue without prompting if videos differ from the baseline

set -euo pipefail

# ---- config ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIGINAL_DIR="$SCRIPT_DIR/original"
PROCESSED_DIR="$SCRIPT_DIR/processed"

CRF=26           # x265 quality: lower = better/bigger. Tune after testing 24/26/28.
PRESET=medium    # "slow" gives slightly smaller output, at the cost of time
DURATION_TOL=0.5 # max allowed difference (seconds) between input and output

# Expected source-video properties, taken from the sample clip. If any video in
# a batch differs, the script lists them and asks whether to continue BEFORE
# encoding anything, so you can review CRF/pixel format/etc. (non-interactive
# runs stop unless ACCEPT_BASELINE_CHANGE=1). Update these values once reviewed.
EXPECT_CODEC="hevc|h264" # regex pattern
EXPECT_DIMS="1920x1080"  # orientation-agnostic (portrait == landscape)
EXPECT_FPS_MIN=24        # frames/s. Pixel clips are variable-frame-rate, so "30 fps"
EXPECT_FPS_MAX=30.5      # shows up as 28.9, 29.75, 29.97, 30, ...; 60/120/240 will flag
EXPECT_PIX_FMT="yuvj420p"
EXPECT_TRANSFER="bt709"    # anything else (e.g. HLG/PQ HDR) needs a different recipe
EXPECT_BITRATE_MIN=8000000 # bits/s; sample clip was ~19.6 Mbps
EXPECT_BITRATE_MAX=30000000

# TESTING ONLY: if non-empty, only this basename is processed (e.g.
# TEST_ONLY="PXL_20241230_200737899.TS.mp4"). Empty = process every file.
TEST_ONLY=""

# ---- helpers --------------------------------------------------------------
die() {
  echo "ERROR: $*" >&2
  exit 1
}
log() { echo "[$(date +%H:%M:%S)] $*"; }
exists() { [[ -e "$1" || -L "$1" ]]; } # -L: catches dangling symlinks

# ---- Ctrl-C / SIGTERM handling ---------------------------------------------
# Bash runs a trap only once the foreground command (e.g. ffmpeg) has exited,
# and ffmpeg exits promptly on SIGINT, so this stops the whole script instead of
# letting it carry on to the next file. Partial files are removed.
CURRENT_OUT=""    # output file currently being encoded
CURRENT_ERRLOG="" # temp file holding ffmpeg's stderr
TAR_IN_PROGRESS=0 # 1 while OUTFILE is being written

on_signal() {
  local sig="$1" code="$2"
  trap '' INT TERM # ignore repeated signals while cleaning up
  echo >&2
  echo "Interrupted ($sig); cleaning up and exiting." >&2
  if [[ -n "$CURRENT_ERRLOG" ]]; then rm -f -- "$CURRENT_ERRLOG"; fi
  if [[ -n "$CURRENT_OUT" ]]; then
    rm -f -- "$CURRENT_OUT"
    echo "  removed partial output: $CURRENT_OUT" >&2
  fi
  if [[ "$TAR_IN_PROGRESS" == "1" ]]; then
    rm -f -- "$OUTFILE"
    echo "  removed partial archive: $OUTFILE" >&2
  fi
  echo "  original/ and processed/ are left as-is (wiped at the start of the next run)." >&2
  exit "$code"
}
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

# ---- args and preflight ---------------------------------------------------
[[ $# -eq 2 ]] || die "usage: $0 <zipfile> <archive-name>"
ZIP="$1"
OUTFILE="$2"

[[ -f "$ZIP" ]] || die "zip not found: $ZIP"
[[ -n "$OUTFILE" ]] || die "archive name must be non-empty"

for cmd in unzip ffmpeg ffprobe tar awk; do
  command -v "$cmd" >/dev/null || die "missing required command: $cmd"
done

if [[ -n "$TEST_ONLY" ]]; then
  log "NOTE: TEST_ONLY is set ($TEST_ONLY); the archive will contain only that file"
fi

# ---- check zip contents before extracting ---------------------------------
log "Checking archive contains only .jpg and .mp4 files"
bad=0
entries=0
while IFS= read -r entry; do
  [[ "$entry" == */ ]] && continue # skip directory entries
  entries=$((entries + 1))
  case "${entry,,}" in
  *.jpg | *.jpeg | *.mp4) ;;
  *)
    echo "  unexpected file type: $entry" >&2
    bad=1
    ;;
  esac
done < <(unzip -Z1 "$ZIP")
[[ $entries -gt 0 ]] || die "zip lists no files (unreadable or empty?)"
[[ $bad -eq 0 ]] || die "zip contains files other than .jpg/.mp4 (see above)"

# ---- wipe temp dirs and extract -------------------------------------------
# original/ and processed/ are temp dirs: deleted and recreated every run.
# Guard so rm -rf can only ever touch the two expected subdirs of this script.
[[ -n "$SCRIPT_DIR" && "$ORIGINAL_DIR" == "$SCRIPT_DIR/original" && "$PROCESSED_DIR" == "$SCRIPT_DIR/processed" ]] ||
  die "refusing to delete unexpected directories: $ORIGINAL_DIR $PROCESSED_DIR"
log "Wiping $ORIGINAL_DIR and $PROCESSED_DIR"
rm -rf -- "$ORIGINAL_DIR" "$PROCESSED_DIR"
mkdir -p "$ORIGINAL_DIR" "$PROCESSED_DIR"

log "Extracting $entries file(s) to $ORIGINAL_DIR"
unzip -q "$ZIP" -d "$ORIGINAL_DIR" ||
  die "unzip failed (corrupt zip?); $ORIGINAL_DIR may be partially populated"

# Build the work list (applies the TEST_ONLY filter).
FILES=()
while IFS= read -r -d '' f; do
  if [[ -n "$TEST_ONLY" && "$(basename "$f")" != "$TEST_ONLY" ]]; then
    continue
  fi
  FILES+=("$f")
done < <(find "$ORIGINAL_DIR" -type f -print0 | sort -z)
[[ ${#FILES[@]} -gt 0 ]] || die "no files to process (is TEST_ONLY=\"$TEST_ONLY\" present in the zip?)"

# ---- baseline check -------------------------------------------------------
PROBE_CODEC="" PROBE_W="" PROBE_H="" PROBE_PIX="" PROBE_FPS="" PROBE_AVG="" PROBE_XFER="" PROBE_BR=""

probe_video() {
  local key val
  PROBE_CODEC="" PROBE_W="" PROBE_H="" PROBE_PIX="" PROBE_FPS="" PROBE_AVG="" PROBE_XFER="" PROBE_BR=""
  while IFS='=' read -r key val; do
    case "$key" in
    codec_name) PROBE_CODEC="$val" ;;
    width) PROBE_W="$val" ;;
    height) PROBE_H="$val" ;;
    pix_fmt) PROBE_PIX="$val" ;;
    r_frame_rate) PROBE_FPS="$val" ;;
    avg_frame_rate) PROBE_AVG="$val" ;;
    color_transfer) PROBE_XFER="$val" ;;
    bit_rate) PROBE_BR="$val" ;;
    esac
  done < <(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,width,height,pix_fmt,r_frame_rate,avg_frame_rate,color_transfer,bit_rate \
    -of default=nw=1 "$1" 2>/dev/null || true)
  # Prefer the average rate: r_frame_rate is a guess that looks odd (119/4,
  # 359/12...) for variable-frame-rate clips.
  if [[ -n "$PROBE_AVG" && "$PROBE_AVG" != "0/0" ]]; then PROBE_FPS="$PROBE_AVG"; fi
  if [[ ! "$PROBE_BR" =~ ^[0-9]+$ ]]; then # stream bitrate can be N/A
    PROBE_BR="$(ffprobe -v error -show_entries format=bit_rate -of csv=p=0 "$1" 2>/dev/null || true)"
  fi
}

# "30000/1001" -> "29.97" (empty if the rate is unusable)
fps_value() {
  awk -v r="$1" 'BEGIN{n=split(r,p,"/"); d=(n>1)?p[2]:1; if(d+0==0){exit} printf "%.2f", p[1]/d}'
}

# Prints one line per deviation from the expected baseline (nothing if it matches).
baseline_deviations() {
  probe_video "$1"
  if [[ -z "$PROBE_CODEC" ]]; then
    echo "could not read video stream with ffprobe"
    return 0
  fi

  local dims="${PROBE_W}x${PROBE_H}"
  if [[ "$PROBE_W" =~ ^[0-9]+$ && "$PROBE_H" =~ ^[0-9]+$ ]]; then
    if ((PROBE_W >= PROBE_H)); then dims="${PROBE_W}x${PROBE_H}"; else dims="${PROBE_H}x${PROBE_W}"; fi
  fi

  [[ "$PROBE_CODEC" =~ ^($EXPECT_CODEC)$ ]] || echo "codec $PROBE_CODEC (expected $EXPECT_CODEC)"
  [[ "$dims" == "$EXPECT_DIMS" ]] || echo "resolution $dims (expected $EXPECT_DIMS)"
  local fps
  fps="$(fps_value "$PROBE_FPS")"
  if [[ -z "$fps" ]]; then
    echo "frame rate unreadable (${PROBE_FPS:-none})"
  elif ! awk -v f="$fps" -v lo="$EXPECT_FPS_MIN" -v hi="$EXPECT_FPS_MAX" 'BEGIN{exit !(f>=lo && f<=hi)}'; then
    echo "frame rate $fps fps (expected $EXPECT_FPS_MIN-$EXPECT_FPS_MAX)"
  fi
  [[ "$PROBE_PIX" == "$EXPECT_PIX_FMT" ]] || echo "pixel format $PROBE_PIX (expected $EXPECT_PIX_FMT)"
  [[ "$PROBE_XFER" == "$EXPECT_TRANSFER" ]] || echo "color transfer ${PROBE_XFER:-unknown} (expected $EXPECT_TRANSFER)"

  if [[ "$PROBE_BR" =~ ^[0-9]+$ ]]; then
    if ((PROBE_BR < EXPECT_BITRATE_MIN || PROBE_BR > EXPECT_BITRATE_MAX)); then
      echo "bitrate $(awk -v b="$PROBE_BR" 'BEGIN{printf "%.1f", b/1e6}') Mbps (expected $((EXPECT_BITRATE_MIN / 1000000))-$((EXPECT_BITRATE_MAX / 1000000)) Mbps)"
    fi
  else
    echo "bitrate unknown"
  fi
  return 0
}

log "Checking video properties against expected baseline"
drift_files=0
MAX_SHOWN=10
for f in "${FILES[@]}"; do
  [[ "${f,,}" == *.mp4 ]] || continue
  devs="$(baseline_deviations "$f")"
  if [[ -n "$devs" ]]; then
    drift_files=$((drift_files + 1))
    if [[ $drift_files -le $MAX_SHOWN ]]; then
      echo "  $(basename "$f"):" >&2
      sed 's/^/    - /' <<<"$devs" >&2
    fi
  fi
done
if [[ $drift_files -gt 0 ]]; then
  [[ $drift_files -le $MAX_SHOWN ]] || echo "  ...and $((drift_files - MAX_SHOWN)) more file(s)" >&2
  if [[ "${ACCEPT_BASELINE_CHANGE:-0}" == "1" ]]; then
    log "WARNING: $drift_files video(s) differ from baseline; continuing (ACCEPT_BASELINE_CHANGE=1)"
  elif [[ -t 0 ]]; then
    echo "$drift_files video(s) differ from the expected baseline (see above; at most $MAX_SHOWN shown)." >&2
    read -r -p "Continue encoding anyway? [y/N] " reply || reply=""
    case "${reply,,}" in
    y | yes) log "Continuing despite baseline differences" ;;
    *) die "aborted. Review the compression settings (update the EXPECT_* values if needed). Nothing has been encoded." ;;
    esac
  else
    die "$drift_files video(s) differ from the expected baseline and stdin is not a terminal. Review the settings, or re-run with ACCEPT_BASELINE_CHANGE=1. Nothing has been encoded."
  fi
fi

# ---- process --------------------------------------------------------------
# ffmpeg output is captured and only shown if the encode fails.
compress_video() {
  local in="$1" out="$2" errlog
  errlog="$(mktemp)"
  CURRENT_ERRLOG="$errlog"
  if ffmpeg -nostdin -hide_banner -loglevel error -n \
    -i "$in" \
    -map 0:v:0 -map 0:a:0? \
    -c:v libx265 -preset "$PRESET" -crf "$CRF" -pix_fmt yuv420p -tag:v hvc1 \
    -c:a copy \
    -map_metadata 0 -movflags +faststart \
    "$out" 2>"$errlog"; then
    rm -f "$errlog"
    CURRENT_ERRLOG=""
    touch -r "$in" "$out" # carry over mtime
  else
    echo "  ffmpeg failed for $in:" >&2
    sed 's/^/    /' "$errlog" >&2
    rm -f "$errlog" "$out" # don't leave a partial output behind
    CURRENT_ERRLOG=""
    return 1
  fi
}

# Fails if input/output durations differ by more than DURATION_TOL seconds.
verify_duration() {
  local a b
  a="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null || true)"
  b="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$2" 2>/dev/null || true)"
  if [[ -z "$a" || -z "$b" ]] ||
    ! awk -v a="$a" -v b="$b" -v tol="$DURATION_TOL" \
      'BEGIN{d=a-b; if(d<0)d=-d; exit (d>tol)}'; then
    echo "  duration check failed: original=${a:-?}s output=${b:-?}s" >&2
    return 1
  fi
}

# ---- progress reporting (videos only; photo copies are negligible) --------
fmt_dur() { # seconds -> 47s / 24m3s / 1h2m3s
  local t=$1
  if ((t >= 3600)); then
    printf '%dh%dm%ds' $((t / 3600)) $((t % 3600 / 60)) $((t % 60))
  elif ((t >= 60)); then
    printf '%dm%ds' $((t / 60)) $((t % 60))
  else printf '%ds' "$t"; fi
}

TOTAL_VIDEOS=0
TOTAL_VIDEO_BYTES=0
for f in "${FILES[@]}"; do
  if [[ "${f,,}" == *.mp4 ]]; then
    TOTAL_VIDEOS=$((TOTAL_VIDEOS + 1))
    TOTAL_VIDEO_BYTES=$((TOTAL_VIDEO_BYTES + $(stat -c %s "$f")))
  fi
done
log "$TOTAL_VIDEOS video(s), $(awk -v b="$TOTAL_VIDEO_BYTES" 'BEGIN{printf "%.1f", b/1048576}')MB to compress"

videos_done=0
bytes_done=0
photos_done=0
VIDEO_OUT_BYTES=0

# The estimate is extrapolated from how this batch has gone so far: elapsed time
# per input byte, applied to the whole batch. It is rough after the first file
# and improves as more files complete.
report_progress() {
  ((bytes_done > 0 && TOTAL_VIDEO_BYTES > 0)) || return 0
  local elapsed=$((SECONDS - LOOP_START)) est_total pct mb_done mb_total
  est_total="$(awk -v e="$elapsed" -v d="$bytes_done" -v t="$TOTAL_VIDEO_BYTES" \
    'BEGIN{x=int(e*t/d+0.5); if(x<e)x=e; print x}')"
  est_remaining=$((est_total - elapsed))
  pct=$((bytes_done * 100 / TOTAL_VIDEO_BYTES))
  mb_done="$(awk -v b="$bytes_done" 'BEGIN{printf "%.1f", b/1048576}')"
  mb_total="$(awk -v b="$TOTAL_VIDEO_BYTES" 'BEGIN{printf "%.0f", b/1048576}')"
  log "Processed $videos_done/$TOTAL_VIDEOS videos, ${mb_done}/${mb_total}MB, ~$(fmt_dur "$est_remaining") remaining (${pct}%)"
}

# Compress + verify one video; records failures in FAILED and returns non-zero.
process_video() {
  local in="$1" out="$2" name="$3" in_size out_size
  log "Compressing video: $name (crf=$CRF preset=$PRESET)"
  CURRENT_OUT="$out"
  if ! compress_video "$in" "$out"; then
    CURRENT_OUT=""
    FAILED+=("$name (ffmpeg error)")
    return 1
  fi
  CURRENT_OUT=""
  if ! verify_duration "$in" "$out"; then
    FAILED+=("$name (duration mismatch; output left in processed/ for inspection)")
    return 1
  fi
  in_size=$(stat -c %s "$in")
  out_size=$(stat -c %s "$out")
  VIDEO_OUT_BYTES=$((VIDEO_OUT_BYTES + out_size))
  log "  $(numfmt --to=iec "$in_size") -> $(numfmt --to=iec "$out_size")"
  if ((out_size >= in_size)); then
    log "  WARNING: $name: output ($(numfmt --to=iec "$out_size")) is not smaller than the original ($(numfmt --to=iec "$in_size"))"
  fi
}

processed=0
FAILED=()
LOOP_START=$SECONDS
for f in "${FILES[@]}"; do
  name="$(basename "$f")"
  out="$PROCESSED_DIR/$name"
  [[ ! -e "$out" ]] || die "duplicate output name (collision?): $name"

  case "${name,,}" in
  *.jpg | *.jpeg)
    log "Copying photo: $name"
    cp -p "$f" "$out"
    photos_done=$((photos_done + 1))
    ;;
  *.mp4)
    process_video "$f" "$out" "$name" || true # failure is recorded in FAILED
    videos_done=$((videos_done + 1))
    bytes_done=$((bytes_done + $(stat -c %s "$f")))
    report_progress
    ;;
  esac
  processed=$((processed + 1))
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "ERROR: ${#FAILED[@]} file(s) failed:" >&2
  printf '  %s\n' "${FAILED[@]}" >&2
  die "not creating archive. Fix the problem and re-run (original/ and processed/ are wiped at the start of each run)."
fi
log "Processed $processed file(s) into $PROCESSED_DIR"

# ---- archive --------------------------------------------------------------
log "Creating $OUTFILE"
TAR_IN_PROGRESS=1
tar -cf "$OUTFILE" -C "$PROCESSED_DIR" .
TAR_IN_PROGRESS=0

log "Verifying tar is readable and complete"
tar_files=$(tar -tf "$OUTFILE" | grep -vc '/$' || true)
[[ "$tar_files" -eq "$processed" ]] ||
  die "tar contains $tar_files file(s) but $processed were processed; leaving $OUTFILE in place"

log "Done: $OUTFILE ($(numfmt --to=iec "$(stat -c %s "$OUTFILE")"))"
log "original/ and processed/ have been left in place (they are wiped at the start of the next run)."

# ---- final summary ----------------------------------------------------------
# Space saved / percentage are for videos only (photos are copied unchanged).
summary="$videos_done video(s) + $photos_done photo(s) processed in $(fmt_dur "$SECONDS")"
if ((bytes_done > 0)); then
  summary+="; videos $(awk -v i="$bytes_done" -v o="$VIDEO_OUT_BYTES" \
    'BEGIN{printf "%.1fMB -> %.1fMB, saved %.1fMB (%.1f%% smaller)", i/1048576, o/1048576, (i-o)/1048576, (i-o)*100/i}')"
fi
log "SUMMARY: $summary"
