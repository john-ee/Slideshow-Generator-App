#!/bin/bash
THREADS=2
FADE_DUR=2
TMP_DIR="./tmp_segments"
SORTED_DIR="./sorted_media"
TMP_LIST="concat.txt"

MUSIC_VOL=0.2
IMG_DIR="./media"
FINAL_OUTPUT="final_slideshow.mp4"
MUSIC_FILE="music.mp3"
YOUTUBE_URL=""
YOUTUBE_SECTION=""
DURATION_PER_IMAGE=3
ORIENTATION="landscape"

while getopts d:f:m:y:s:t:v:o: flag; do
 case "${flag}" in
 d) IMG_DIR="${OPTARG}" ;;
 f) FINAL_OUTPUT="${OPTARG}" ;;
 m) MUSIC_FILE="${OPTARG}" ;;
 y) YOUTUBE_URL="${OPTARG}" ;;
 s) YOUTUBE_SECTION="${OPTARG}" ;;
 t) DURATION_PER_IMAGE="${OPTARG}" ;;
 v) MUSIC_VOL="${OPTARG}" ;;
 o) ORIENTATION="${OPTARG}" ;;
 *) echo "Usage: $0 [-d media_dir] [-f final_output] [-m music_file] [-y youtube_url] [-s youtube_section] [-t image_duration] [-v music_volume] [-o orientation (landscape|portrait|square)]" && exit 1 ;;
 esac
done

# Set resolution based on orientation
if [[ "$ORIENTATION" == "portrait" ]]; then
  RESOLUTION="720:1280"
elif [[ "$ORIENTATION" == "square" ]]; then
  RESOLUTION="1080:1080"
else
  RESOLUTION="1280:720"
fi

for cmd in ffmpeg ffprobe exiftool bc; do
 command -v $cmd >/dev/null 2>&1 || { echo "❌ $cmd is not installed"; exit 1; }
done
if [[ -n "$YOUTUBE_URL" ]]; then
 command -v yt-dlp >/dev/null 2>&1 || { echo "❌ yt-dlp is required"; exit 1; }
 command -v jq >/dev/null 2>&1 || { echo "❌ jq is required"; exit 1; }
fi

# Download music and extract metadata if YouTube URL provided
if [[ -n "$YOUTUBE_URL" ]]; then
 echo "Downloading audio from YouTube..."
 
 # Build yt-dlp command with optional section download
 YTDLP_CMD="yt-dlp -x --audio-format mp3"
 if [[ -n "$YOUTUBE_SECTION" ]]; then
   echo "Using section: $YOUTUBE_SECTION"
   YTDLP_CMD="$YTDLP_CMD --download-sections \"*$YOUTUBE_SECTION\""
 fi
 YTDLP_CMD="$YTDLP_CMD -o \"$MUSIC_FILE\" \"$YOUTUBE_URL\""
 
 eval $YTDLP_CMD || exit 1
 
 YTID=$(yt-dlp --get-id "$YOUTUBE_URL")
 echo "MUSIC CREDITS : https://youtu.be/$YTID" > overlay.txt
fi

# Pre cleanup
rm -rf "$TMP_DIR" "$TMP_LIST" combined.mp4 "$SORTED_DIR"

mkdir -p "$SORTED_DIR" "$TMP_DIR"
> "$TMP_LIST"

cp "$IMG_DIR"/* "$SORTED_DIR"

echo "Processing media..."
for file in $(find "$SORTED_DIR" -type f \( -iname "*.jpg" -o -iname "*.mp4" \) | sort); do
  base_name=$(basename "$file" | sed 's/\.[^.]*$//')
  seg="$TMP_DIR/${base_name}.mp4"

  if [[ "$file" == *.jpg ]]; then
    ffmpeg -threads $THREADS -y \
      -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
      -loop 1 -t $DURATION_PER_IMAGE -i "$file" \
      -vf "scale=$RESOLUTION:force_original_aspect_ratio=decrease,pad=$RESOLUTION:(ow-iw)/2:(oh-ih)/2:black,format=yuv420p" \
      -r 30 -c:v libx264 -pix_fmt yuv420p -color_range tv -sar 1:1 -c:a aac -shortest "$seg" || exit 1
  else
    ffmpeg -threads $THREADS -y -i "$file" \
      -vf "scale=$RESOLUTION:force_original_aspect_ratio=decrease,pad=$RESOLUTION:(ow-iw)/2:(oh-ih)/2:black,format=yuv420p" \
      -r 30 -c:v libx264 -pix_fmt yuv420p -color_range tv -sar 1:1 -c:a aac -ar 44100 "$seg" || exit 1
  fi

  echo "file '$seg'" >> "$TMP_LIST"
done

if [[ ! -s "$TMP_LIST" ]]; then
 echo "❌ No media files found"
 exit 1
fi

echo "Creating combined video..."
INPUTS=$(awk -F"'" '{print "-i " $2}' "$TMP_LIST")
SEG_COUNT=$(wc -l < "$TMP_LIST")

# Build filter chain that normalizes SAR for each input
FILTER_CHAIN=""
for i in $(seq 0 $((SEG_COUNT - 1))); do
  FILTER_CHAIN="${FILTER_CHAIN}[$i:v]setsar=1[v$i];[$i:a]anull[a$i];"
done

# Build concat inputs
CONCAT_INPUTS=""
for i in $(seq 0 $((SEG_COUNT - 1))); do
  CONCAT_INPUTS="${CONCAT_INPUTS}[v$i][a$i]"
done

ffmpeg -threads $THREADS -y $INPUTS \
-filter_complex "${FILTER_CHAIN}${CONCAT_INPUTS}concat=n=$SEG_COUNT:v=1:a=1[outv][outa]" \
-map "[outv]" -map "[outa]" -c:v libx264 -pix_fmt yuv420p -r 30 -c:a aac combined.mp4 || exit 1

DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 combined.mp4)
VIDEO_FADE_OUT_START=$(echo "$DURATION - $FADE_DUR" | bc)

echo "Adding music and fades..."
# Build video filter chain (fade + optional overlay)
if [[ -n "$YOUTUBE_URL" ]]; then
 DRAW_TEXT=",drawtext=textfile='overlay.txt':fontcolor=white:fontsize=20:x=w-tw-20:y=h-th-20:box=1:boxcolor=black@0.5"
else
 DRAW_TEXT=""
fi

VIDEO_FILTER="[0:v]fade=t=in:st=0:d=$FADE_DUR,fade=t=out:st=$VIDEO_FADE_OUT_START:d=$FADE_DUR$DRAW_TEXT[v]"
AUDIO_FILTER="[0:a]volume=1.0[a0]; [1:a]volume=$MUSIC_VOL,afade=t=out:st=$VIDEO_FADE_OUT_START:d=$FADE_DUR[a1]; [a0][a1]amix=inputs=2:duration=longest[a]"

ffmpeg -threads $THREADS -y -i combined.mp4 -i "$MUSIC_FILE" \
-filter_complex "$VIDEO_FILTER; $AUDIO_FILTER" \
-map "[v]" -map "[a]" -c:v libx264 -c:a aac -t $DURATION "$FINAL_OUTPUT" || exit 1

# Cleanup
rm -rf "$TMP_DIR" "$TMP_LIST" combined.mp4 "$SORTED_DIR"
if [[ -n "$YOUTUBE_URL" ]]; then rm -f "$MUSIC_FILE" overlay.txt; fi

echo "✅ Done! Final video: $FINAL_OUTPUT"