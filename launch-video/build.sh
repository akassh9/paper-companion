#!/bin/zsh
# Rebuilds the film from its sources. Needs: Xcode command-line tools (swiftc), ffmpeg, python3 with numpy,
# and the archival media in assets/ (see CREDITS.md for where each file comes from).
#
#   ./build.sh            picture + sound + both masters
#   ./build.sh sound      soundtrack and masters only (reuses render/picture.mov)
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p render tools/bin

if [[ "${1:-}" != "sound" ]]; then
  (cd tools/cutter && swiftc -O -o ../bin/cutter *.swift)
  tools/bin/cutter events render/events.json
  tools/bin/cutter film render/picture.mov
fi
python3 -I tools/audio/mix.py "$PWD" render/soundtrack.wav

# Loudness for online playback: -15 LUFS integrated, -1 dBTP.
ffmpeg -loglevel error -y -i render/soundtrack.wav -af loudnorm=I=-15:TP=-1.0:LRA=11 -ar 48000 render/soundtrack-norm.wav

# Master: 3840x2160, 60 fps, HEVC 10-bit (hvc1, plays in QuickTime), AAC 320k.
ffmpeg -loglevel error -y -i render/picture.mov -i render/soundtrack-norm.wav \
  -map 0:v -map 1:a -c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le -b:v 90M -maxrate 120M -tag:v hvc1 \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a aac -b:a 320k -movflags +faststart -shortest "Paper Companion - film - 4K60.mp4"

# Share copy: 1920x1080, 60 fps, H.264 High, AAC 256k.
ffmpeg -loglevel error -y -i render/picture.mov -i render/soundtrack-norm.wav \
  -map 0:v -map 1:a -vf "scale=1920:1080:flags=lanczos" -c:v libx264 -preset slow -crf 17 -profile:v high -pix_fmt yuv420p \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a aac -b:a 256k -movflags +faststart -shortest "Paper Companion - film - 1080p.mp4"
echo "done"
