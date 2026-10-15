import Foundation

struct ZoneChoice: Equatable {
    var identifier: String
    var place: String
    var title: String
}

struct ZoneGroup: Equatable {
    var key: String
    var title: String
    var zones: [ZoneChoice]
}

enum ZonePreference {
    static let actualIdentifierKey = "actualTimeZoneIdentifier"
    static let defaultActualIdentifier = "Asia/Taipei"

    static func actualTimeZone() -> TimeZone {
        let stored = UserDefaults.standard.string(forKey: actualIdentifierKey)
        if let stored, let zone = TimeZone(identifier: stored) {
            return zone
        }
        return TimeZone(identifier: defaultActualIdentifier) ?? .current
    }

    static func saveActual(_ identifier: String) {
        guard ZoneCatalog.isValidIdentifier(identifier) else { return }
        UserDefaults.standard.set(identifier, forKey: actualIdentifierKey)
    }
}

enum ZoneCatalog {
    private static let continentOrder = [
        "Asia", "Europe", "America", "Africa", "Australia",
        "Pacific", "Atlantic", "Indian", "Antarctica", "Arctic",
    ]

    private static let continentTitles = [
        "Asia": "亚洲",
        "Europe": "欧洲",
        "America": "美洲",
        "Africa": "非洲",
        "Australia": "澳洲",
        "Pacific": "太平洋",
        "Atlantic": "大西洋",
        "Indian": "印度洋",
        "Antarctica": "南极",
        "Arctic": "北极",
    ]

    static func groups(
        at date: Date,
        identifiers: [String] = TimeZone.knownTimeZoneIdentifiers
    ) -> [ZoneGroup] {
        var buckets: [String: [ZoneChoice]] = [:]
        for identifier in identifiers {
            guard TimeZone(identifier: identifier) != nil else { continue }
            let key = identifier.split(separator: "/").first.map(String.init) ?? identifier
            buckets[key, default: []].append(choice(identifier: identifier, at: date))
        }
        for key in buckets.keys {
            buckets[key]?.sort { $0.place.localizedCaseInsensitiveCompare($1.place) == .orderedAscending }
        }

        var groups: [ZoneGroup] = []
        var used = Set<String>()
        for key in continentOrder {
            guard let zones = buckets[key], !zones.isEmpty else { continue }
            used.insert(key)
            groups.append(ZoneGroup(key: key, title: continentTitles[key] ?? key, zones: zones))
        }

        let extras = buckets.keys.filter { !used.contains($0) }.sorted()
        let otherZones = extras.flatMap { buckets[$0] ?? [] }
            .sorted { $0.place.localizedCaseInsensitiveCompare($1.place) == .orderedAscending }
        if !otherZones.isEmpty {
            groups.append(ZoneGroup(key: "Other", title: "其他", zones: otherZones))
        }
        return groups
    }

    static func choice(identifier: String, at date: Date) -> ZoneChoice {
        let place = placeName(identifier: identifier)
        let seconds = TimeZone(identifier: identifier)?.secondsFromGMT(for: date) ?? 0
        return ZoneChoice(
            identifier: identifier,
            place: place,
            title: "\(place) (\(offsetText(seconds: seconds)))"
        )
    }

    static func title(for identifier: String, at date: Date) -> String {
        choice(identifier: identifier, at: date).title
    }

    static func administratorScript(identifier: String) -> String? {
        guard isValidIdentifier(identifier) else { return nil }
        return """
        do shell script "/usr/sbin/systemsetup -settimezone \(identifier)" with administrator privileges with prompt "GeoShift需要管理员权限才能切换系统时区。"
        """
    }

    static func isValidIdentifier(_ identifier: String) -> Bool {
        identifier.range(of: #"^[A-Za-z0-9_/+-]+$"#, options: .regularExpression) != nil
            && TimeZone(identifier: identifier) != nil
    }

    static func offsetText(seconds: Int) -> String {
        let sign = seconds >= 0 ? "+" : "-"
        let magnitude = abs(seconds)
        let hours = magnitude / 3600
        let minutes = (magnitude % 3600) / 60
        if minutes == 0 {
            return "UTC\(sign)\(hours)"
        }
        return String(format: "UTC%@%d:%02d", sign, hours, minutes)
    }

    private static func placeName(identifier: String) -> String {
        let parts = identifier.split(separator: "/").map { $0.replacingOccurrences(of: "_", with: " ") }
        guard parts.count >= 2 else { return identifier.replacingOccurrences(of: "_", with: " ") }
        return parts.dropFirst().joined(separator: "/")
    }
}
