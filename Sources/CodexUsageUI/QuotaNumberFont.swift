import CoreText
import SwiftUI

public enum QuotaNumberFont {
    public static let postScriptName = "QuotaNumber"

    public static func register() {
        _ = registration
    }

    public static func font(size: CGFloat) -> Font {
        .custom(postScriptName, size: size)
    }

    private static let registration: Bool = {
        guard let url = Bundle.main.url(forResource: "Num_Digits_Only", withExtension: "ttf") else {
            return false
        }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()
}
