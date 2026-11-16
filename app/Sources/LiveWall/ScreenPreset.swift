import Foundation

/// A target screen shape. `verified` marks shapes that were checked on a real device (docs/research-notes.md): the Duo
/// inner screen since round 1, Face ID iPhones since round 40 (portrait 884×1920 on an iPhone 16 Pro).
///
/// All Face ID iPhones share one shape: their screens differ by under 0.5 % in width / height (1170×2532, 1179×2556,
/// 1206×2622, 1290×2796, 1320×2868…), less than iOS's own wallpaper crop, so one entry covers them. The home-button
/// iPhone SE is 16 : 9. iPads come in three shapes and turn, so they also have an orientation.
struct ScreenPreset: Identifiable, Hashable {
    enum Family { case iPhone, iPad, other }

    let id: String
    let name: String
    let family: Family
    let symbol: String
    /// width / height of the wallpaper as the lock screen shows it, upright.
    let aspect: Double
    /// iPads are used both ways up; the iPhone Duo inner screen only landscape, iPhones only portrait.
    let rotates: Bool
    let verified: Bool

    /// What to call the device in sentences ("发送到 iPad").
    var deviceName: String { family == .iPad ? "iPad" : "iPhone" }

    static let duo = ScreenPreset(id: "duo", name: "iPhone Duo 内屏", family: .iPhone, symbol: "rectangle.split.2x1",
                                  aspect: 3222.0 / 2266.0, rotates: false, verified: true)
    static let iphone = ScreenPreset(id: "iphone", name: "iPhone（面容 ID 机型）", family: .iPhone, symbol: "iphone",
                                     aspect: 1179.0 / 2556.0, rotates: false, verified: true)
    static let iphoneSE = ScreenPreset(id: "iphone-se", name: "iPhone SE（主屏幕按钮机型）", family: .iPhone, symbol: "iphone.gen1",
                                       aspect: 750.0 / 1334.0, rotates: false, verified: false)
    static let ipad = ScreenPreset(id: "ipad", name: "iPad、iPad Air / Pro 11 英寸", family: .iPad, symbol: "ipad",
                                   aspect: 1640.0 / 2360.0, rotates: true, verified: false)
    static let ipad13 = ScreenPreset(id: "ipad-13", name: "iPad Air / Pro 13 英寸", family: .iPad, symbol: "ipad",
                                     aspect: 2048.0 / 2732.0, rotates: true, verified: false)
    static let ipadMini = ScreenPreset(id: "ipad-mini", name: "iPad mini", family: .iPad, symbol: "ipad",
                                       aspect: 1488.0 / 2266.0, rotates: true, verified: false)
    static let custom = ScreenPreset(id: "custom", name: "自定义", family: .other, symbol: "aspectratio",
                                     aspect: 1, rotates: false, verified: false)

    static let iPhones = [iphone, duo, iphoneSE]
    static let iPads = [ipad, ipad13, ipadMini]
    static let all = iPhones + iPads + [custom]
}
