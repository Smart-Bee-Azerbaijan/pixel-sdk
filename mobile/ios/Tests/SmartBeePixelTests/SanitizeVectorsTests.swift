import Foundation
import XCTest
@testable import SmartBeePixel

/// Ortaq təmizləmə vektorları (spec/vectors/sanitize-url.json, sanitize-props.json, identity.json, campaign.json).
/// Eyni fayllar veb tracker-in (tracker/test/vectors.test.js; gözlənilən dəyərlər onun nəticəsidir) və Android-in
/// (SanitizeVectorsTest.kt) testlərində də işlədilir: üç SDK eyni girişdən eyni nəticəni almalıdır. Uyğun gəlməyən
/// hər vektor adı, gözlənilən və alınan dəyəri ilə birlikdə xəta mətnində sadalanır.
///
/// Fayllar repo-dan, bu faylın yoluna (`#filePath`) görə oxunur (CoreTests-dəki `specDir` kimi): `swift test`
/// həmişə repo-nun içində işlədilir, ona görə vektorların ayrıca nüsxəsi saxlanmır.
enum SanitizeVectors {
    /// mobile/ios/Tests/SmartBeePixelTests/SanitizeVectorsTests.swift -> spec/vectors
    static var directory: URL {
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("spec").appendingPathComponent("vectors")
    }

    /// Fayldakı girişlər; fayl oxunmursa boş siyahı (çağıran testdə say yoxlanır, ona görə test boş keçmir).
    static func cases(_ file: String) -> [[String: Any]] {
        let url = directory.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cases = root["cases"] as? [[String: Any]] else { return [] }
        return cases
    }

    /// Müqayisə üçün kanonik yazılış: açarları sıralanmış JSON; nil və NSNull üçün `null`.
    static func canonical(_ value: Any?) -> String {
        guard let value = value, !(value is NSNull) else { return "null" }
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "not JSON: \(value)" }
        return text
    }

    /// Gözlənilən və alınan dəyər eynidirsə nil, yoxsa fərqin təsviri. Mətnlər UTF-16 vahidləri ilə müqayisə olunur
    /// (`String ==` kanonik ekvivalent mətnləri eyni sayardı).
    static func difference(_ item: [String: Any], _ got: Any?) -> String? {
        let name = item["name"] as? String ?? "?"
        guard let expected = item["expected"] else { return "\(name): no expected value" }
        let want = canonical(expected)
        let have = canonical(got)
        if Array(want.utf16) == Array(have.utf16) { return nil }
        return "\(name)\n  expected: \(want)\n  actual:   \(have)"
    }
}

final class SanitizeVectorsTests: XCTestCase {
    private func run(_ file: String, min: Int, line: UInt = #line, _ actual: ([String: Any]) -> Any?) {
        let cases = SanitizeVectors.cases(file)
        XCTAssertGreaterThanOrEqual(cases.count, min, "\(file): at least \(min) cases expected at \(SanitizeVectors.directory.path)", line: line)
        var failed: [String] = []
        for item in cases {
            if let difference = SanitizeVectors.difference(item, actual(item)) { failed.append(difference) }
        }
        XCTAssertTrue(
            failed.isEmpty,
            "\(file): \(failed.count) of \(cases.count) vectors differ from the web tracker:\n" + failed.joined(separator: "\n"),
            line: line
        )
    }

    /// Konfiqin `strip_params` siyahısı real konfiq oxuyucusundan keçir (adlar kiçik hərfə çevrilir).
    private func strip(_ item: [String: Any]) -> Set<String> {
        guard let list = item["strip"] as? [Any], let json = Util.jsonString(["strip_params": list]) else { return [] }
        return RemoteConfig.parse(json)?.stripParams ?? []
    }

    func testUrlsAreCleanedExactlyLikeTheWebTracker() {
        run("sanitize-url.json", min: 60) { item in
            let ads = (item["ads"] as? Bool) ?? true
            return Util.cleanUrl(item["url"] as? String ?? "", extraStrip: self.strip(item), ads: ads)
        }
    }

    func testPropsAndTraitsAreCleanedExactlyLikeTheWebTracker() {
        run("sanitize-props.json", min: 40) { item in
            // kind: label — ekran adı (vebdə səhifə başlığı): giriş və nəticə mətndir.
            if (item["kind"] as? String) == "label" {
                return Util.label(item["input"] as? String ?? "")
            }
            let input = item["input"] as? [String: Any] ?? [:]
            let out: [String: Any]? = (item["kind"] as? String) == "traits" ? Util.cleanTraits(input) : Util.cleanObject(input)
            return out
        }
    }

    func testUserIdsAreNormalisedExactlyLikeTheWebTracker() {
        run("identity.json", min: 25) { item in
            return Util.userId(item["input"] as? String)
        }
    }

    func testCampaignsAreReadExactlyLikeTheWebTracker() {
        run("campaign.json", min: 20) { item in
            let ads = (item["ads"] as? Bool) ?? true
            let out: [String: Any]? = Util.campaignOf(item["url"] as? String ?? "", withClickIds: ads)
            return out
        }
    }
}
