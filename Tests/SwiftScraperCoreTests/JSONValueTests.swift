import XCTest
@testable import SwiftScraperCore

final class JSONValueTests: XCTestCase {
    func testRemoteValueEncodesObjectPropertiesAsBiDiTuples() {
        let value = JSONValue.object([
            "title": .string("Apple Swift"),
            "rank": .int(1),
        ])

        XCTAssertEqual(
            value.remoteValue(),
            .object([
                "type": .string("object"),
                "value": .array([
                    .array([
                        .string("rank"),
                        .object([
                            "type": .string("number"),
                            "value": .int(1),
                        ]),
                    ]),
                    .array([
                        .string("title"),
                        .object([
                            "type": .string("string"),
                            "value": .string("Apple Swift"),
                        ]),
                    ]),
                ]),
            ])
        )
    }
}
