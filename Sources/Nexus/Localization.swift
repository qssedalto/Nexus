import Foundation

func localized(_ key: String) -> String {
    #if SWIFT_PACKAGE
    let bundle = Bundle.module
    #else
    let bundle = Bundle.main
    #endif
    #if DEBUG
    if CommandLine.arguments.contains("--nexus-trend-preview"),
       let language = CommandLine.arguments.first(where: { $0.hasPrefix("--nexus-preview-language=") })?
        .split(separator: "=").last.map(String.init),
       let path = bundle.path(forResource: language, ofType: "lproj"),
       let selectedBundle = Bundle(path: path) {
        return selectedBundle.localizedString(forKey: key, value: nil, table: nil)
    }
    #endif
    return bundle.localizedString(forKey: key, value: nil, table: nil)
}
