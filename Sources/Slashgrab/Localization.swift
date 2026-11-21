import Foundation

func localized(_ key: String) -> String {
    #if SWIFT_PACKAGE
    let bundle = Bundle.module
    #else
    let bundle = Bundle.main
    #endif
    return bundle.localizedString(forKey: key, value: nil, table: nil)
}
