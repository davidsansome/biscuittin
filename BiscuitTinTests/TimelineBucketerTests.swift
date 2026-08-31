import XCTest
@testable import BiscuitTin

/// Day/week/month bucketing, including the calendar edge cases called out in DESIGN.md §16.
final class TimelineBucketerTests: XCTestCase {

    /// Fixed calendar so tests do not depend on the machine's locale or zone.
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.locale = Locale(identifier: "en_GB")
        return cal
    }()

    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: iso)!
    }

    private func stub(_ id: String, _ iso: String) -> AssetStub {
        AssetStub(id: AssetID(raw: id), captureDate: date(iso), hasLocal: true, hasRemote: false,
                  kind: .image, durationSeconds: 0, pixelWidth: 100, pixelHeight: 100,
                  latitude: .nan, longitude: .nan)
    }

    /// Bucketing assumes a newest-first input, which is what `TimelineIndex` guarantees.
    private func sorted(_ stubs: [AssetStub]) -> [AssetStub] {
        stubs.sorted { $0.captureDate > $1.captureDate }
    }

    private func bucketer(now: String = "2026-08-18 12:00") -> TimelineBucketer {
        TimelineBucketer(calendar: calendar, now: date(now))
    }

    // MARK: - Day

    func testDayGroupingSplitsAcrossMidnight() {
        let stubs = sorted([
            stub("a", "2026-08-18 23:59"),
            stub("b", "2026-08-19 00:01"),
            stub("c", "2026-08-18 00:00")
        ])
        let buckets = bucketer().buckets(from: stubs, grouping: .day)

        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].items.map(\.id.raw), ["b"])
        XCTAssertEqual(Set(buckets[1].items.map(\.id.raw)), ["a", "c"])
    }

    func testDayTitlesUseRelativeNamesForTodayAndYesterday() {
        let stubs = sorted([
            stub("today", "2026-08-18 09:00"),
            stub("yesterday", "2026-08-17 09:00"),
            stub("older", "2026-08-10 09:00")
        ])
        let buckets = bucketer(now: "2026-08-18 12:00").buckets(from: stubs, grouping: .day)

        XCTAssertEqual(buckets[0].title, "Today")
        XCTAssertEqual(buckets[1].title, "Yesterday")
        XCTAssertNotEqual(buckets[2].title, "Today")
        XCTAssertFalse(buckets[2].title.isEmpty)
    }

    func testDayBucketIdentifiersAreStableAndUnique() {
        let stubs = sorted([stub("a", "2026-08-18 09:00"), stub("b", "2026-08-17 09:00")])
        let buckets = bucketer().buckets(from: stubs, grouping: .day)
        XCTAssertEqual(buckets.map(\.id), ["d-2026-08-18", "d-2026-08-17"])
    }

    // MARK: - Week

    func testWeekGroupingSplitsOnWeekBoundary() {
        // en_GB weeks start Monday: 17 Aug 2026 is a Monday, so 16 Aug falls in the prior week.
        let stubs = sorted([
            stub("mon", "2026-08-17 09:00"),
            stub("sun", "2026-08-16 09:00"),
            stub("sat", "2026-08-22 09:00")
        ])
        let buckets = bucketer().buckets(from: stubs, grouping: .week)

        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(Set(buckets[0].items.map(\.id.raw)), ["sat", "mon"])
        XCTAssertEqual(buckets[1].items.map(\.id.raw), ["sun"])
    }

    func testWeekTitleCoversInclusiveRange() {
        let buckets = bucketer().buckets(from: [stub("a", "2026-08-18 09:00")], grouping: .week)
        let title = buckets[0].title
        // The end date must be the inclusive Sunday (23rd), not the exclusive boundary (24th).
        XCTAssertTrue(title.contains("23"), "week title \(title) should end on the 23rd")
        XCTAssertFalse(title.contains("24"), "week title \(title) leaked the exclusive end")
    }

    // MARK: - Month and year

    func testMonthGroupingSplitsOnMonthBoundary() {
        let stubs = sorted([
            stub("aug-first", "2026-08-01 00:00"),
            stub("jul-last", "2026-07-31 23:59"),
            stub("aug-last", "2026-08-31 23:59")
        ])
        let buckets = bucketer().buckets(from: stubs, grouping: .month)

        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(Set(buckets[0].items.map(\.id.raw)), ["aug-first", "aug-last"])
        XCTAssertEqual(buckets[1].items.map(\.id.raw), ["jul-last"])
        XCTAssertEqual(buckets.map(\.id), ["m-2026-08", "m-2026-07"])
    }

    func testYearRolloverKeepsDaysSeparate() {
        let stubs = sorted([
            stub("newyear", "2027-01-01 00:30"),
            stub("nye", "2026-12-31 23:30")
        ])
        let buckets = bucketer().buckets(from: stubs, grouping: .day)
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets.map(\.id), ["d-2027-01-01", "d-2026-12-31"])
    }

    func testDaylightSavingTransitionDayStaysOneBucket() {
        // 25 Oct 2026 is the UK DST fall-back day: a 25-hour local day must not split.
        var uk = Calendar(identifier: .gregorian)
        uk.timeZone = TimeZone(identifier: "Europe/London")!
        uk.locale = Locale(identifier: "en_GB")
        calendar = uk

        let stubs = sorted([
            stub("early", "2026-10-25 00:30"),
            stub("mid", "2026-10-25 01:30"),
            stub("late", "2026-10-25 23:30")
        ])
        let buckets = TimelineBucketer(calendar: uk, now: date("2026-11-01 12:00"))
            .buckets(from: stubs, grouping: .day)

        XCTAssertEqual(buckets.count, 1, "a DST day must remain a single bucket")
        XCTAssertEqual(buckets[0].items.count, 3)
    }

    // MARK: - Structure

    func testBucketsAndItemsAreNewestFirst() {
        let stubs = sorted((0..<40).map { stub("a-\($0)", "2026-08-\(String(format: "%02d", ($0 % 28) + 1)) 10:00") })
        for grouping in Grouping.allCases {
            let buckets = bucketer().buckets(from: stubs, grouping: grouping)
            let starts = buckets.compactMap { $0.items.first?.captureDate }
            XCTAssertEqual(starts, starts.sorted(by: >), "\(grouping) buckets out of order")
            for bucket in buckets {
                let dates = bucket.items.map(\.captureDate)
                XCTAssertEqual(dates, dates.sorted(by: >), "\(grouping) items out of order")
            }
        }
    }

    func testEveryAssetLandsInExactlyOneBucket() {
        let stubs = sorted((0..<120).map {
            stub("a-\($0)", "2026-\(String(format: "%02d", ($0 % 12) + 1))-\(String(format: "%02d", ($0 % 28) + 1)) 10:00")
        })
        for grouping in Grouping.allCases {
            let buckets = bucketer().buckets(from: stubs, grouping: grouping)
            let ids = buckets.flatMap { $0.items.map(\.id) }
            XCTAssertEqual(ids.count, stubs.count, "\(grouping) lost or duplicated assets")
            XCTAssertEqual(Set(ids).count, stubs.count, "\(grouping) duplicated an asset")
            XCTAssertEqual(Set(buckets.map(\.id)).count, buckets.count, "\(grouping) duplicated a bucket id")
        }
    }

    func testEmptyInputProducesNoBuckets() {
        XCTAssertTrue(bucketer().buckets(from: [], grouping: .day).isEmpty)
    }
}
