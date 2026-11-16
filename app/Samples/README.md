# 测试样片

开发和测试用的公开授权短视频，放在项目根（仓库的上一层）的 `_samples/` 里，不进仓库；仓库里只有这份说明和下载脚本。

重新下载：`app/scripts/fetch-samples.sh`（下载到 `../_samples/`，设 `LIVEWALL_SAMPLES` 可换目录；已存在的跳过；约 480 MB）。

| 文件 | 内容 | 分辨率 / fps / 时长 | 方向 | 测什么 | 许可 | 来源 |
|---|---|---|---|---|---|---|
| `clouds-blue-sky.mp4` | 蓝天白云快速飘过 | 1920×1080 / 25 / 5.6 s | 横 | 常规慢动作；短片（只有 5.6 s） | Mixkit Free | [51105](https://mixkit.co/free-stock-video/white-clouds-moving-across-a-clear-blue-sky-quickly-51105/) |
| `aurora-4k.mp4` | 蓝绿极光 | 3840×2160 / 30 / 7.1 s | 横 | 4K 降采样（长边 > 2176）；色彩标签不一致（trc bt709、primaries smpte170m） | Mixkit Free | [4038](https://mixkit.co/free-stock-video/northern-lights-of-blue-and-green-colors-in-the-night-4038/) |
| `night-sky-lake.mp4` | 湖面星空延时 | 1920×1080 / 23.976 / 12.1 s | 横 | 暗场、星点细节、非整数帧率 | Mixkit Free | [1704](https://mixkit.co/free-stock-video/night-sky-with-stars-at-a-calm-lake-time-lapse-1704/) |
| `mountain-fog.mp4` | 云雾漫过山峦 | 1920×1080 / 25 / 22.0 s | 横 | 慢速大面积运动；**无色彩标签**（unknown） | Mixkit Free | [4695](https://mixkit.co/free-stock-video/clouds-covering-the-mountains-4695/) |
| `pink-flowers-portrait.mp4` | 粉花随风摆动 | 1080×1920 / 23.976 / 20.8 s | **竖** | 竖屏原生（编码即竖，无旋转标记） | Mixkit Free | [1168](https://mixkit.co/free-stock-video/pink-flowers-wave-in-the-breeze-1168/) |
| `sea-waves-aerial-portrait.mp4` | 俯拍海浪拍礁石 | 1080×1920 / 23.976 / 24.6 s | **竖** | 竖屏；高频纹理（浪花） | Mixkit Free | [51506](https://mixkit.co/free-stock-video/aerial-view-of-sea-waves-crash-at-a-rock-51506/) |
| `smoke-portrait.mp4` | 黑底烟雾 | 1080×1920 / 24 / 15.0 s | **竖** | 竖屏；深色背景上的抽象运动 | Mixkit Free | [1968](https://mixkit.co/free-stock-video/black-background-with-smoke-foreground-1968/) |
| `fireworks.mp4` | 夜空烟花 | 1920×1080 / 24 / 24.1 s | 横 | 快速闪烁、亮度突变（运动/跳变警告）；无色彩标签 | Mixkit Free | [4064](https://mixkit.co/free-stock-video/fireworks-at-night-sky-4064/) |
| `ink-in-water.mp4` | 水中墨汁扩散特写 | 1920×1080 / 23.976 / 20.1 s | 横 | 抽象慢动作；原片 37.9 s，截前 20 s | Mixkit Free | [154](https://mixkit.co/free-stock-video/abstract-close-up-of-black-ink-in-water-154/) |
| `earth-spin-60fps.mp4` | 带云层、大气和夜光的自转地球 | 1920×1080 / 60 / 20.0 s | 横 | 60 fps 输入；无色彩标签；原片 100 s，截前 20 s | NASA 公有领域 | [SVS 5570](https://svs.gsfc.nasa.gov/5570) |

全部是 H.264 / yuv420p / SDR，没有 HDR 样片。截短的两条用 `ffmpeg -t 20 -c copy -an` 从头截取，不重编码。

## 许可

- **Mixkit Stock Video Free License**：可商用，不要求署名；不得把素材原样当素材再分发 —— 这也是视频只用脚本下载、不进仓库的原因。条款：<https://mixkit.co/license/>。
- **NASA SVS**：NASA 制作的影像属公有领域，按 NASA 媒体使用指南建议署名：`NASA's Scientific Visualization Studio`（数据可视化 Kel Elkins，科学家 William Putman）。不得暗示 NASA 背书。
