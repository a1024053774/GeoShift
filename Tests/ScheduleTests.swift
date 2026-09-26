import Foundation

private var failures = 0

private func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        fputs("FAIL \(message)\n", stderr)
    }
}

private func date(timeZone: TimeZone, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute, second: second
    ))!
}

private func chinaParts(_ date: Date) -> DateComponents {
    ChinaClock.chinaCalendar().dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
}

private func sanFranciscoParts(_ date: Date) -> DateComponents {
    ChinaClock.calendar(ChinaClock.sanFrancisco).dateComponents([.year, .month, .day, .hour, .minute], from: date)
}

private func clockSeconds(_ date: Date, timeZone: TimeZone) -> Int {
    let parts = ChinaClock.calendar(timeZone).dateComponents([.hour, .minute, .second], from: date)
    return (parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0)
}

private func chinaSeconds(_ date: Date) -> Int {
    clockSeconds(date, timeZone: ChinaClock.china)
}

private func sanFranciscoSeconds(_ date: Date) -> Int {
    clockSeconds(date, timeZone: ChinaClock.sanFrancisco)
}

@main
private struct ScheduleTestMain {
    static func main() {
        runAll()
    }
}

private func runAll() {
let schedule = DaySchedule.default
let winter = date(timeZone: ChinaClock.sanFrancisco, 2026, 1, 15, 12)
let summer = date(timeZone: ChinaClock.sanFrancisco, 2026, 7, 15, 12)
let tuesdayNight = date(timeZone: ChinaClock.sanFrancisco, 2026, 9, 22, 22, 6)

check(ChinaClock.sanFranciscoLag(at: winter) == (16, 0), "January lag should be 16 hours, got \(ChinaClock.sanFranciscoLag(at: winter))")
check(!ChinaClock.sanFranciscoUsesDaylightSaving(at: winter), "January should be Pacific Standard Time")
check(ChinaClock.menuBarTitle(at: winter) == "1月16日 周五 04:00", "winter title was \(ChinaClock.menuBarTitle(at: winter))")
check(ChinaClock.appearance(at: winter, schedule: schedule) == .dark, "04:00 China should be dark")

check(ChinaClock.sanFranciscoLag(at: summer) == (15, 0), "July lag should be 15 hours, got \(ChinaClock.sanFranciscoLag(at: summer))")
check(ChinaClock.sanFranciscoUsesDaylightSaving(at: summer), "July should be Pacific Daylight Time")
check(ChinaClock.menuBarTitle(at: summer) == "7月16日 周四 03:00", "summer title was \(ChinaClock.menuBarTitle(at: summer))")

check(ChinaClock.sanFranciscoLag(at: tuesdayNight) == (15, 0), "September lag should be 15 hours")
check(ChinaClock.menuBarTitle(at: tuesdayNight) == "9月23日 周三 13:06", "Tuesday night title was \(ChinaClock.menuBarTitle(at: tuesdayNight))")
check(ChinaClock.zoneLine(at: tuesdayNight, timeZone: ChinaClock.sanFrancisco) == "9月22日 周二 22:06", "SF line was \(ChinaClock.zoneLine(at: tuesdayNight, timeZone: ChinaClock.sanFrancisco))")
check(ChinaClock.appearance(at: tuesdayNight, schedule: schedule) == .light, "13:06 China should be light")
check(ChinaClock.offsetSummary(at: tuesdayNight).contains("夏令时间"), "offset summary should use the daylight name: \(ChinaClock.offsetSummary(at: tuesdayNight))")
check(ChinaClock.offsetSummary(at: winter).contains("标准时间"), "offset summary should use the standard name: \(ChinaClock.offsetSummary(at: winter))")
check(!ChinaClock.offsetSummary(at: tuesdayNight).contains("16"), "daylight summary must not say 16 hours")
check(!ChinaClock.offsetSummary(at: winter).contains("15"), "standard summary must not say 15 hours")

let spring = ChinaClock.nextSanFranciscoDaylightSavingTransition(after: winter)
check(spring != nil, "system should report the next Pacific daylight transition")
if let spring {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let parts = utc.dateComponents([.year, .month, .day, .hour, .minute], from: spring)
    check(parts.year == 2026 && parts.month == 3 && parts.day == 8 && parts.hour == 10 && parts.minute == 0, "spring transition was \(spring)")
    let before = spring.addingTimeInterval(-1)
    let after = spring.addingTimeInterval(1)
    check(!ChinaClock.sanFranciscoUsesDaylightSaving(at: before) && ChinaClock.sanFranciscoUsesDaylightSaving(at: after), "daylight flag should flip at the system transition")
    check(ChinaClock.sanFranciscoLag(at: before).hours == 16 && ChinaClock.sanFranciscoLag(at: after).hours == 15, "lag should follow the system transition")
    let chinaDelta = chinaSeconds(after) - chinaSeconds(before)
    let sanFranciscoDelta = sanFranciscoSeconds(after) - sanFranciscoSeconds(before)
    check(chinaDelta == 2, "China clock should advance 2 seconds across the transition, advanced \(chinaDelta)")
    check(sanFranciscoDelta == 3602, "San Francisco clock should spring forward one hour, advanced \(sanFranciscoDelta)")
}

let autumn = ChinaClock.nextSanFranciscoDaylightSavingTransition(after: summer)
check(autumn != nil, "system should report the autumn transition")
if let autumn {
    let before = autumn.addingTimeInterval(-1)
    let after = autumn.addingTimeInterval(1)
    check(ChinaClock.sanFranciscoUsesDaylightSaving(at: before) && !ChinaClock.sanFranciscoUsesDaylightSaving(at: after), "autumn transition should leave daylight saving")
    check(ChinaClock.sanFranciscoLag(at: before).hours == 15 && ChinaClock.sanFranciscoLag(at: after).hours == 16, "lag should become 16 after the autumn transition")
    check(ChinaClock.china.nextDaylightSavingTimeTransition(after: autumn) == nil, "China has no daylight-saving transition in the system database")
    check(ChinaClock.china.secondsFromGMT(for: autumn) == 8 * 3600, "China offset should stay 8 hours")
}

let septemberNext = ChinaClock.nextTransition(after: tuesdayNight, schedule: schedule)
check(septemberNext?.appearance == .dark, "next change after Tuesday night should be dark")
if let septemberNext {
    let china = chinaParts(septemberNext.date)
    let local = sanFranciscoParts(septemberNext.date)
    check(china.month == 9 && china.day == 23 && china.hour == 19 && china.minute == 0, "China switch was \(china)")
    check(local.month == 9 && local.day == 23 && local.hour == 4 && local.minute == 0, "SF switch during PDT was \(local)")
    check(ChinaClock.nextChangeDescription(after: tuesdayNight, schedule: schedule) == "今天 19:00 切换为深色", "description was \(ChinaClock.nextChangeDescription(after: tuesdayNight, schedule: schedule))")
}

let chinaNoon = date(timeZone: ChinaClock.china, 2026, 1, 16, 12)
let winterNext = ChinaClock.nextTransition(after: chinaNoon, schedule: schedule)
if let winterNext {
    let local = sanFranciscoParts(winterNext.date)
    check(winterNext.appearance == .dark, "noon China next change is dark")
    check(local.hour == 3 && local.day == 16, "19:00 China is 03:00 SF during standard time, got \(local)")
}

for (hour, minute, expected) in [(6, 59, DayAppearance.dark), (7, 0, .light), (18, 59, .light), (19, 0, .dark), (0, 0, .dark), (23, 59, .dark)] {
    let sample = date(timeZone: ChinaClock.china, 2026, 1, 16, hour, minute)
    check(ChinaClock.appearance(at: sample, schedule: schedule) == expected, "\(hour):\(minute) expected \(expected)")
}

let atSeven = date(timeZone: ChinaClock.china, 2026, 1, 16, 7)
let fromSeven = ChinaClock.nextTransition(after: atSeven, schedule: schedule)
check(fromSeven?.appearance == .dark && chinaParts(fromSeven!.date).hour == 19, "07:00 next should be 19:00 dark")

let atNineteen = date(timeZone: ChinaClock.china, 2026, 1, 16, 19)
let fromNineteen = ChinaClock.nextTransition(after: atNineteen, schedule: schedule)
let nineteenParts = chinaParts(fromNineteen!.date)
check(fromNineteen?.appearance == .light && nineteenParts.day == 17 && nineteenParts.hour == 7, "19:00 next should be next morning")

let wrapped = DaySchedule(lightMinutes: 22 * 60, darkMinutes: 6 * 60)
for (hour, minute, expected) in [(23, 0, DayAppearance.light), (5, 59, .light), (6, 0, .dark), (12, 0, .dark), (21, 59, .dark), (22, 0, .light)] {
    let sample = date(timeZone: ChinaClock.china, 2026, 1, 16, hour, minute)
    check(wrapped.appearance(atMinutes: hour * 60 + minute) == expected, "wrapped \(hour):\(minute)")
    _ = sample
}

let nineOhFive = date(timeZone: ChinaClock.china, 2026, 9, 23, 9, 5)
check(ChinaClock.menuBarTitle(at: nineOhFive) == "9月23日 周三 09:05", "padding was \(ChinaClock.menuBarTitle(at: nineOhFive))")

let boundary = date(timeZone: ChinaClock.china, 2026, 9, 23, 13, 6, 0)
let justAfter = date(timeZone: ChinaClock.china, 2026, 9, 23, 13, 6, 59)
check(ChinaClock.nextMinute(after: boundary) == date(timeZone: ChinaClock.china, 2026, 9, 23, 13, 7), "exact minute should schedule the following minute")
check(ChinaClock.nextMinute(after: justAfter) == date(timeZone: ChinaClock.china, 2026, 9, 23, 13, 7), "late second should still target the next minute")
check(ChinaClock.nextMinute(after: boundary).timeIntervalSince(boundary) == 60, "full minute interval")
check(ChinaClock.nextMinute(after: justAfter).timeIntervalSince(justAfter) == 1, "one second until the next displayed minute")

let newYorkSummer = date(timeZone: TimeZone(identifier: "America/New_York")!, 2026, 9, 26, 12)
let newYorkWinter = date(timeZone: TimeZone(identifier: "America/New_York")!, 2026, 1, 15, 12)
let zoneGroups = ZoneCatalog.groups(at: newYorkSummer)
let america = zoneGroups.first { $0.key == "America" }
let asia = zoneGroups.first { $0.key == "Asia" }
check(america?.title == "美洲", "America group title was \(america?.title ?? "missing")")
check(asia?.title == "亚洲", "Asia group title was \(asia?.title ?? "missing")")
check(america?.zones.contains { $0.identifier == "America/New_York" && $0.title == "New York (UTC-4)" } == true, "New York summer title was \(ZoneCatalog.title(for: "America/New_York", at: newYorkSummer))")
check(ZoneCatalog.title(for: "America/New_York", at: newYorkWinter) == "New York (UTC-5)", "New York winter title was \(ZoneCatalog.title(for: "America/New_York", at: newYorkWinter))")
check(asia?.zones.contains { $0.identifier == "Asia/Shanghai" && $0.title == "Shanghai (UTC+8)" } == true, "Shanghai was not grouped under Asia")
check(zoneGroups.contains { $0.key == "America/New_York" } == false, "New York must not be a top-level timezone list")
check(zoneGroups.map(\.key).firstIndex(of: "Asia")! < zoneGroups.map(\.key).firstIndex(of: "America")!, "continents should stay in a fixed order")
check(ZoneCatalog.title(for: "Asia/Kolkata", at: newYorkSummer) == "Kolkata (UTC+5:30)", "half-hour offset was \(ZoneCatalog.title(for: "Asia/Kolkata", at: newYorkSummer))")
check(ZoneCatalog.title(for: "America/Argentina/Buenos_Aires", at: newYorkSummer).hasPrefix("Argentina/Buenos Aires (UTC"), "region should stay visible")
let command = ZoneCatalog.administratorScript(identifier: "America/New_York")
check(command?.contains("/usr/sbin/systemsetup -settimezone America/New_York") == true, "timezone command was \(command ?? "nil")")
check(ZoneCatalog.administratorScript(identifier: "America/New_York; reboot") == nil, "shell metacharacters must be rejected")

let taipei = TimeZone(identifier: "Asia/Taipei")!
let newYork = TimeZone(identifier: "America/New_York")!
let noonInNewYork = date(timeZone: newYork, 2026, 9, 26, 12, 42)
check(ZoneLocation.parse("+2503+12130")?.latitude == 25.05, "Taipei latitude was \(String(describing: ZoneLocation.parse("+2503+12130")))")
check(abs((ZoneLocation.parse("+404251-0740023")?.longitude ?? 0) + 74.0064) < 0.01, "New York longitude")
let taipeiCoordinate = ZoneLocation.coordinate(for: "Asia/Taipei")
check(taipeiCoordinate != nil, "system zone table should include Taipei")
let taipeiPlace = taipeiCoordinate ?? ZoneCoordinate(latitude: 25.05, longitude: 121.5)
check(SolarDay.appearance(at: noonInNewYork, timeZone: taipei, coordinate: taipeiPlace) == .dark, "Taipei should be night while New York is afternoon")
check(ChinaClock.zoneLine(at: noonInNewYork, timeZone: taipei) == "9月27日 周日 00:42", "Taipei clock was \(ChinaClock.zoneLine(at: noonInNewYork, timeZone: taipei))")
check(ChinaClock.lagSummary(actual: taipei, disguise: newYork, at: noonInNewYork) == "伪装时区比实际时区慢 12 小时", "lag was \(ChinaClock.lagSummary(actual: taipei, disguise: newYork, at: noonInNewYork))")
let taipeiNoon = date(timeZone: taipei, 2026, 9, 26, 12)
check(SolarDay.appearance(at: taipeiNoon, timeZone: taipei, coordinate: taipeiPlace) == .light, "Taipei noon should be light")
let sunrise = SolarDay.nextChangeDescription(after: noonInNewYork, timeZone: taipei, coordinate: taipeiPlace)
check(sunrise.contains("切换为浅色"), "next Taipei change was \(sunrise)")

check(DaySchedule(lightMinutes: 7 * 60, darkMinutes: 7 * 60).normalized() == nil, "equal boundaries are rejected")
check(DaySchedule(lightMinutes: -1, darkMinutes: 19 * 60).normalized() == nil, "out of range boundaries are rejected")

if failures == 0 {
    print("ok")
    exit(0)
}
fputs("\(failures) failed\n", stderr)
exit(1)
}
