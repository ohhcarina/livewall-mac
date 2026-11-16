#!/bin/zsh
# 下载测试视频到项目根（仓库的上一层）的 _samples/，不进仓库；LIVEWALL_SAMPLES 可改目录。已存在的文件跳过。
# 来源与许可证见 app/Samples/README.md。
set -e
out="${LIVEWALL_SAMPLES:-${0:A:h:h:h:h}/_samples}"
mkdir -p "$out"

# name  url  [trim seconds]
clips=(
  "clouds-blue-sky.mp4|https://assets.mixkit.co/videos/51105/51105-1080.mp4|"
  "aurora-4k.mp4|https://assets.mixkit.co/videos/4038/4038-2160.mp4|"
  "night-sky-lake.mp4|https://assets.mixkit.co/videos/1704/1704-1080.mp4|"
  "mountain-fog.mp4|https://assets.mixkit.co/videos/4695/4695-1080.mp4|"
  "pink-flowers-portrait.mp4|https://assets.mixkit.co/videos/1168/1168-1080.mp4|"
  "sea-waves-aerial-portrait.mp4|https://assets.mixkit.co/videos/51506/51506-1080.mp4|"
  "smoke-portrait.mp4|https://assets.mixkit.co/videos/1968/1968-1080.mp4|"
  "fireworks.mp4|https://assets.mixkit.co/videos/4064/4064-1080.mp4|"
  "ink-in-water.mp4|https://assets.mixkit.co/videos/154/154-1080.mp4|20"
  "earth-spin-60fps.mp4|https://svs.gsfc.nasa.gov/vis/a000000/a005500/a005570/Earth_wAtmos_spin_02_1080p60.mp4|20"
)

for entry in $clips; do
  parts=("${(@s:|:)entry}")
  name=$parts[1] url=$parts[2] trim=$parts[3]
  dest="$out/$name"
  if [[ -e "$dest" ]]; then
    echo "skip  $name"
    continue
  fi
  echo "fetch $name"
  tmp="$out/.$name.part"
  curl -fL --retry 2 --progress-bar -o "$tmp" $url
  if [[ -n $trim ]]; then
    # 从头截取，流拷贝不重编码
    ffmpeg -v error -y -i "$tmp" -t $trim -c copy -an -movflags +faststart "$dest"
    rm -f "$tmp"
  else
    mv "$tmp" "$dest"
  fi
done
