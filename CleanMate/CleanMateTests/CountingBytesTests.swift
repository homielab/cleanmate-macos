import Foundation
import Testing
@testable import CleanMate

/// The number that counts up on done screens and the Overview: one unit all the way, exact at the end.
struct CountingBytesTests {
    private let en = Locale(identifier: "en_US")

    @Test func countsInTheUnitOfTheFinalValue() {
        #expect(CountingBytes.unit(of: 0) == .bytes)
        #expect(CountingBytes.unit(of: 999) == .bytes)
        #expect(CountingBytes.unit(of: 1_000) == .kb)
        #expect(CountingBytes.unit(of: 3_456_000) == .mb)
        #expect(CountingBytes.unit(of: 3_456_000_000) == .gb)
        #expect(CountingBytes.unit(of: 2_000_000_000_000) == .tb)
        #expect(CountingBytes.text(0, target: 3_456_000_000, locale: en) == "0 GB")
        #expect(CountingBytes.text(1_728_000_000, target: 3_456_000_000, locale: en).hasSuffix(" GB"))
        #expect(CountingBytes.text(-5, target: 3_456_000_000, locale: en) == "0 GB") // a spring overshooting below 0
    }

    @Test func endsOnTheExactFileSizeText() {
        for target: Int64 in [0, 512, 139_264, 3_456_000_000, 999_999_999, 1_234_567_890_123] {
            let exact = target.formatted(.fileSize.locale(en))
            #expect(CountingBytes.text(Double(target), target: target, locale: en) == exact)
            #expect(CountingBytes.text(Double(target) + 1, target: target, locale: en) == exact)
        }
    }
}
