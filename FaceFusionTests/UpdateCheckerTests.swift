import Foundation
import Testing
@testable import Morphiqo

@Suite("iOS App Store update lookup")
struct UpdateCheckerTests {

    @Test("ignores a Mac result returned for the shared app record")
    func ignoresMacResult() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "results": [[
                "version": "9.9.9",
                "trackViewUrl": "https://apps.apple.com/app/morphiqo/id1234567890",
                "bundleId": "com.lisenhuang.morphiqo",
                "kind": "mac-software"
            ]]
        ])

        #expect(UpdateChecker.parse(data) == nil)
    }

    @Test("accepts only the iOS listing")
    func acceptsIOSResult() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "results": [
                [
                    "version": "9.9.9",
                    "trackViewUrl": "https://apps.apple.com/app/morphiqo/id1234567890",
                    "bundleId": "com.lisenhuang.morphiqo",
                    "kind": "mac-software"
                ],
                [
                    "version": "1.7.0",
                    "trackViewUrl": "https://apps.apple.com/app/morphiqo/id6797135085",
                    "bundleId": "com.lisenhuang.morphiqo",
                    "kind": "software"
                ]
            ]
        ])

        let update = try #require(UpdateChecker.parse(data))
        #expect(update.version == "1.7.0")
        #expect(update.storeURL.absoluteString == "https://apps.apple.com/app/morphiqo/id6797135085")
    }
}
