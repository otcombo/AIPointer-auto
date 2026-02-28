import Foundation

/// 系统首选语言是否为中文
/// 使用 CFPreferences 直接读取系统设置，不受 app bundle 本地化影响
let isSystemChinese: Bool = {
    if let languages = CFPreferencesCopyValue(
        "AppleLanguages" as CFString,
        kCFPreferencesAnyApplication,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    ) as? [String], let first = languages.first {
        return first.hasPrefix("zh")
    }
    return false
}()

/// 根据系统语言返回默认回复语言
let defaultResponseLanguage: String = isSystemChinese ? "zh-CN" : "en"

/// 中英文快捷切换
func L(_ zh: String, _ en: String) -> String {
    isSystemChinese ? zh : en
}
