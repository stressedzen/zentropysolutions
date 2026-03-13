#!/usr/bin/env bash
# generate-web-icons.sh (improved detection for macOS/Homebrew magick)
set -euo pipefail

ASSETS_DIR="${1:-$(pwd)/zentropysolutions/public_html/assets}"

PROCESSED_DIR="$ASSETS_DIR/processed"
ICONS_DIR="$PROCESSED_DIR/icons"
WEBP_DIR="$PROCESSED_DIR/webp"
FAV_DIR="$PROCESSED_DIR/favicons"
MANIFEST_DIR="$PROCESSED_DIR/manifest-icons"
LOG_FILE="$ASSETS_DIR/generate-web-icons.log"

SIZES=(16 32 48 64 128 180 192 256 512)
SKIP_SUFFIX="_keep.png"
SRC_DIR="$ASSETS_DIR/originals"
PNGQUANT_QUALITY="65-85"
WEBP_QUALITY=80

mkdir -p "$ICONS_DIR" "$WEBP_DIR" "$FAV_DIR" "$MANIFEST_DIR"
touch "$LOG_FILE"

log() { echo "$(date -Iseconds) $*" | tee -a "$LOG_FILE"; }

# Find ImageMagick binary robustly:
MAGICK_BIN=""
# 1) prefer explicit magick on PATH
if command -v magick >/dev/null 2>&1; then
  MAGICK_BIN="$(command -v magick)"
else
  # 2) try brew prefix (works for Homebrew installs)
  if command -v brew >/dev/null 2>&1; then
    BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
    if [ -n "$BREW_PREFIX" ] && [ -x "$BREW_PREFIX/bin/magick" ]; then
      MAGICK_BIN="$BREW_PREFIX/bin/magick"
    fi
  fi
  # 3) fallback to convert/identify if magick not available
  if [ -z "$MAGICK_BIN" ]; then
    if command -v convert >/dev/null 2>&1; then
      MAGICK_BIN="$(command -v convert)"
    fi
  fi
fi

if [ -n "$MAGICK_BIN" ]; then
  # If MAGICK_BIN points to 'convert' binary, set flags accordingly (convert vs magick)
  if [[ "$(basename "$MAGICK_BIN")" = "magick" ]]; then
    IM_CONVERT="$MAGICK_BIN convert"
    IM_IDENTIFY="$MAGICK_BIN identify"
  else
    # MAGICK_BIN is 'convert'
    IM_CONVERT="$MAGICK_BIN"
    # try to find identify on PATH
    if command -v identify >/dev/null 2>&1; then
      IM_IDENTIFY="identify"
    else
      IM_IDENTIFY="$MAGICK_BIN" # convert can sometimes handle identify-like formats
    fi
  fi
else
  log "ERROR: Could not locate ImageMagick (magick or convert). Please install ImageMagick."
  exit 1
fi

log "Using ImageMagick binary: $(echo \"$IM_CONVERT\" | awk '{print $1}')"

_has() { command -v "$1" >/dev/null 2>&1; }

if [ ! -d "$SRC_DIR" ]; then
  log "ERROR: Source directory not found: $SRC_DIR"
  log "Create it and copy your Drive PNGs there (e.g. public_html/assets/originals/)."
  exit 1
fi

if ! _has "$(echo $IM_CONVERT | awk '{print $1}')" || ! _has "$(echo $IM_IDENTIFY | awk '{print $1}')" ; then
  log "ERROR: ImageMagick commands not available: $IM_CONVERT or $IM_IDENTIFY"
  exit 1
fi

if ! _has cwebp; then log "WARNING: cwebp not found. WebP generation will be skipped."; fi
if ! _has optipng; then log "NOTE: optipng not found. Lossless PNG optimization will be skipped."; fi
if ! _has pngquant; then log "NOTE: pngquant not found. Lossy PNG quantization skipped for non-alpha images."; fi

log "Starting processing: SRC_DIR=$SRC_DIR -> PROCESSED_DIR=$PROCESSED_DIR"

needs_processing() {
  local src="$1" name="$2"
  for s in "${SIZES[@]}"; do
    out="$ICONS_DIR/${name}_${s}x${s}.png"
    [ ! -f "$out" ] && return 0
    [ "$src" -nt "$out" ] && return 0
  done
  webp_out="$WEBP_DIR/${name}.webp"
  [ ! -f "$webp_out" ] && return 0
  [ "$src" -nt "$webp_out" ] && return 0
  ico_out="$FAV_DIR/${name}.ico"
  [ ! -f "$ico_out" ] && return 0
  return 1
}

find "$SRC_DIR" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.PNG' \) -print0 |
while IFS= read -r -d '' SRC; do
  BASENAME=$(basename "$SRC")
  if [[ "$BASENAME" == *"$SKIP_SUFFIX" ]]; then
    log "SKIP (keep marker): $BASENAME"
    continue
  fi
  NAME="${BASENAME%.*}"
  log "PROCESS: $BASENAME"

  channels=$($IM_IDENTIFY -format "%[channels]" "$SRC" 2>/dev/null || echo "")
  HAS_ALPHA=0
  if echo "$channels" | grep -qi 'alpha'; then HAS_ALPHA=1; else lastchar="${channels: -1}"; if [ "$lastchar" = "a" ]; then HAS_ALPHA=1; fi; fi
  if [ -z "$channels" ]; then alt=$($IM_IDENTIFY -format "%[alpha]" "$SRC" 2>/dev/null || echo ""); if echo "$alt" | grep -Eqi 'true|1'; then HAS_ALPHA=1; fi; fi

  log "alpha=$HAS_ALPHA (identify channels='$channels')"

  if ! needs_processing "$SRC" "$NAME"; then
    log "UP-TO-DATE: $BASENAME"
    continue
  fi

  for S in "${SIZES[@]}"; do
    OUT="$ICONS_DIR/${NAME}_${S}x${S}.png"
    mkdir -p "$(dirname "$OUT")"
    if [ "$HAS_ALPHA" -eq 1 ]; then
      $IM_CONVERT "$SRC" -auto-orient -strip -resize "${S}x${S}" "$OUT" || log "convert failed $SRC -> $OUT"
      if _has optipng; then optipng -o7 -out "$OUT" "$OUT" >/dev/null 2>&1 || true; fi
    else
      $IM_CONVERT "$SRC" -auto-orient -strip -resize "${S}x${S}" -gravity center -background none -extent "${S}x${S}" "$OUT" || log "convert failed $SRC -> $OUT"
      if _has pngquant; then TMP="${OUT}.tmp.png"; pngquant --quality="$PNGQUANT_QUALITY" --output "$TMP" --force "$OUT" >/dev/null 2>&1 && mv -f "$TMP" "$OUT" || true
      elif _has optipng; then optipng -o7 -out "$OUT" "$OUT" >/dev/null 2>&1 || true; fi
    fi
    log "  wrote $OUT"
  done

  WEBP_OUT="$WEBP_DIR/${NAME}.webp"
  mkdir -p "$(dirname "$WEBP_OUT")"
  if _has cwebp; then
    if [ "$HAS_ALPHA" -eq 1 ]; then cwebp -lossless "$SRC" -o "$WEBP_OUT" >/dev/null 2>&1 && log "  wrote $WEBP_OUT (lossless)"; else cwebp -q "$WEBP_QUALITY" "$SRC" -o "$WEBP_OUT" >/dev/null 2>&1 && log "  wrote $WEBP_OUT (lossy)"; fi
  else log "  skipped webp: cwebp not installed"; fi

  ICO_OUT="$FAV_DIR/${NAME}.ico"
  ICO_IN_16="$ICONS_DIR/${NAME}_16x16.png"
  ICO_IN_32="$ICONS_DIR/${NAME}_32x32.png"
  ICO_IN_48="$ICONS_DIR/${NAME}_48x48.png"
  if [ -f "$ICO_IN_16" ] && [ -f "$ICO_IN_32" ]; then
    if [ -f "$ICO_IN_48" ]; then $IM_CONVERT "$ICO_IN_16" "$ICO_IN_32" "$ICO_IN_48" -colors 256 "$ICO_OUT" || log "warning: failed to create $ICO_OUT"
    else $IM_CONVERT "$ICO_IN_16" "$ICO_IN_32" -colors 256 "$ICO_OUT" || log "warning: failed to create $ICO_OUT"; fi
    cp -f "$ICO_IN_32" "$FAV_DIR/${NAME}_favicon32.png" || true
    log "  wrote $ICO_OUT and fallback 32px"
  fi

  for S in 192 512; do SRC_ICON="$ICONS_DIR/${NAME}_${S}x${S}.png"; [ -f "$SRC_ICON" ] && cp -f "$SRC_ICON" "$MANIFEST_DIR/$(basename "$SRC_ICON")"; done

  log "DONE: $BASENAME alpha=$HAS_ALPHA"
done

log "=== Finished pass ==="
exit 0
