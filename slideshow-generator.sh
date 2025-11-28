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
RESOLUTION="1280:720"
YOUTUBE_URL=""
DURATION_PER_IMAGE=3

while getopts d:f:m:r:y:t:v: flag; do
 case "${flag}" in
 d) IMG_DIR="${OPTARG}" ;;
 f) FINAL_OUTPUT="${OPTARG}" ;;
 m) MUSIC_FILE="${OPTARG}" ;;
 r) RESOLUTION="${OPTARG}" ;;
 y) YOUTUBE_URL="${OPTARG}" ;;
 t) DURATION_PER_IMAGE="${OPTARG}" ;;
 v) MUSIC_VOL="${OPTARG}" ;;
 *) echo "Usage: $0 [-d media_dir] [-f final_output] [-m music_file] [-r resolution] [-y youtube_url] [-t image_duration] -v [music volume between 0 and 1]" && exit 1 ;;
 esac
done

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
 yt-dlp -x --audio-format mp3 -o "$MUSIC_FILE" "$YOUTUBE_URL" || exit 1
 YTID=$(yt-dlp --get-id "$YOUTUBE_URL")
 echo "MUSIC CREDITS : https://youtu.be/$YTID" > overlay.txt
fi

mkdir -p "$SORTED_DIR" "$TMP_DIR"
> "$TMP_LIST"

exiftool '-FileName<DateTimeOriginal' -d "%Y%m%d_%H%M%S%%-c.%%e" -o "$SORTED_DIR" "$IMG_DIR" || cp "$IMG_DIR"/* "$SORTED_DIR"

echo "Processing media..."
for file in $(find "$SORTED_DIR" -type f \( -iname "*.jpg" -o -iname "*.mp4" \) | sort); do
  base_name=$(basename "$file" | sed 's/\.[^.]*$//')
  seg="$TMP_DIR/${base_name}.mp4"

  if [[ "$file" == *.jpg ]]; then
    ffmpeg -threads $THREADS -y \
      -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
      -loop 1 -t $DURATION_PER_IMAGE -i "$file" \
      -vf "scale=$RESOLUTION:force_original_aspect_ratio=decrease,pad=$RESOLUTION:(ow-iw)/2:(oh-ih)/2:black" \
      -r 30 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$seg" || exit 1
  else
    ffmpeg -threads $THREADS -y -i "$file" \
      -vf "scale=$RESOLUTION:force_original_aspect_ratio=decrease,pad=$RESOLUTION:(ow-iw)/2:(oh-ih)/2:black" \
      -r 30 -c:v libx264 -pix_fmt yuv420p -c:a aac -ar 44100 "$seg" || exit 1
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

ffmpeg -threads $THREADS -y $INPUTS \
-filter_complex "concat=n=$SEG_COUNT:v=1:a=1" \
-c:v libx264 -pix_fmt yuv420p -r 30 -c:a aac combined.mp4 || exit 1

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
