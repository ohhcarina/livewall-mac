# LiveWall for Mac

**English:** LiveWall turns a video clip into a Live Photo wallpaper that actually moves on the iPhone lock screen: no "Motion not available", no jumps, no colour shift. It picks the frames and encodes them for you, following rules found by testing on real iPhones. macOS 14 or later, Apple silicon and Intel. The interface is in Chinese. MIT licensed.

把一段视频做成在 iPhone 锁屏上真正会动的实况（Live Photo）壁纸。

自己做的实况照片设成壁纸时，常常提示「动态效果不可用」、只能当静态的，或者一动就跳、偏色。LiveWall 按在真机上一轮轮测出来的规则自动挑帧、编码。导出的壁纸点亮锁屏就会动。

## 下载

到 [Releases](https://github.com/ohhcarina/livewall-mac/releases) 下载 `LiveWall-<版本>.dmg`，把 LiveWall 拖进「应用程序」。需要 macOS 14 或更新，已经过 Apple 公证，双击就能打开。

## 用法

1. 把视频拖进窗口。
2. 选机型（默认是面容 ID 的 iPhone，也可以选 iPhone Duo 内屏、iPad 或自定义比例）和适配方式：
   - 压窄：整幅画面拉伸，不丢内容。
   - 裁切：切出一块，不变形。
3. 在时间轴上选封面。锁屏点亮时只播封面之前的 10 帧，起点会自动放在「最远还顺」的地方，你也可以自己拖。
4. 看锁屏预览和颜色条（平滑 / 略有跳动 / 跳动明显）。预览只是模拟，手机会在帧之间自动过渡，实际效果以手机为准。
5. 点导出，在弹窗里选「隔空投送」到 iPhone，或者「添加到『照片』」等 iCloud 同步。
6. 在 iPhone 上打开「设置 › 墙纸 › 添加新墙纸 › 照片」，选这张实况。

已在真机上验证过：iPhone Duo 内屏、iPhone 16 Pro（竖屏）。其他机型应该也能用；如果你的壁纸提示「动态效果不可用」，欢迎开 issue，写上机型和 iOS 版本。

暂不支持 HDR / 杜比视界视频（iPhone 默认拍的就是），导入时会提示。

## 在 iPhone 上直接做

iOS 版「LiveWall 实况壁纸」正在准备上架 App Store：在手机上选视频，直接存成能动的实况壁纸，不用经过 Mac。

## 从源码构建

需要 Xcode 27 或更新（命令行工具带的 Swift 也行）：

```bash
cd app
swift test                    # 引擎的单元测试
swift run LiveWall            # 直接运行（也可以 swift run LiveWall 视频文件）
scripts/build-app.sh          # 组装 dist/LiveWall.app（通用二进制，ad-hoc 签名）
scripts/make-dmg.sh           # 打成 dist/LiveWall-<版本>.dmg
```

引擎 `LiveWallCore` 是纯 Swift，只用系统框架（AVFoundation、VideoToolbox、ImageIO），不需要 ffmpeg。命令行版 `livewall-cli` 能批量出包：

```bash
swift run livewall-cli build <视频> --range 起,止 --aspect 0.4613 --name 名字 --out 输出目录
```

`--range` 是起止秒数（止 = 封面），`--aspect` 是屏幕宽高比，`--mode crop` 改成裁切；`swift run livewall-cli` 列出全部命令。

## 许可

[MIT](LICENSE)。Live Photo 元数据的写法来自 [pudding0503/live-photo-batch](https://github.com/pudding0503/live-photo-batch)（MIT），许可见 [THIRD_PARTY/](THIRD_PARTY/)。测试样片的来源与许可见 [app/Samples/README.md](app/Samples/README.md)。
