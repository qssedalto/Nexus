import CoreGraphics

let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
) as? [[String: Any]] ?? []
if let window = windows.first(where: {
    ($0[kCGWindowOwnerName as String] as? String) == "Nexus" &&
    ($0[kCGWindowName as String] as? String).map {
        $0 == "Time trend" || $0 == "时间趋势"
    } == true
}), let number = window[kCGWindowNumber as String] as? Int {
    print(number)
}
