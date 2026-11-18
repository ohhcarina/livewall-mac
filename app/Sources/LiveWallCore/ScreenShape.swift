// Wallpaper shapes (width / height, as the lock screen shows it upright) of the phones the rules were tested on
// (docs/research-notes.md 一.5, rounds 1 and 40). The apps pick one; the engine sizes the output from it.
public enum ScreenShape {
    /// Every Face ID iPhone: their screens differ by under 0.5 %, less than iOS's own wallpaper crop. Device-tested
    /// portrait 884×1920 on an iPhone 16 Pro (round 40).
    public static let faceIDiPhone = 1179.0 / 2556.0
    /// The home-button iPhone SE, 16 : 9 portrait. Not tested on a device.
    public static let homeButtoniPhone = 750.0 / 1334.0
    /// The iPhone Duo inner screen used sideways; its outer screen shares the same wallpaper (round 43).
    public static let duoInner = 3222.0 / 2266.0
}
