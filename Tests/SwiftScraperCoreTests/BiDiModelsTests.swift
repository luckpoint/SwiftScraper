import Foundation
import XCTest
@testable import SwiftScraperCore

final class BiDiModelsTests: XCTestCase {
    func testEventEncodesBiDiEventType() throws {
        let event = BiDiEvent(
            method: "browsingContext.domContentLoaded",
            params: [
                "context": .string("main"),
            ]
        )

        let data = try JSONEncoder().encode(event)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(
            value,
            .object([
                "method": .string("browsingContext.domContentLoaded"),
                "params": .object([
                    "context": .string("main"),
                ]),
                "type": .string("event"),
            ])
        )
    }

    func testClientSessionFiltersEventsByNameAndContext() {
        let session = BiDiClientSession()
        session.subscribe(events: ["log.entryAdded"], contexts: ["main"])

        XCTAssertTrue(
            session.isSubscribed(
                to: BiDiEvent(
                    method: "log.entryAdded",
                    params: [
                        "source": .object([
                            "context": .string("main"),
                        ]),
                    ]
                )
            )
        )
        XCTAssertFalse(
            session.isSubscribed(
                to: BiDiEvent(
                    method: "browsingContext.load",
                    params: [
                        "context": .string("main"),
                    ]
                )
            )
        )
    }

    func testClientSessionSupportsModuleSubscriptions() {
        let session = BiDiClientSession()
        session.subscribe(events: ["browsingContext"], contexts: ["main"])

        XCTAssertTrue(
            session.isSubscribed(
                to: BiDiEvent(
                    method: "browsingContext.load",
                    params: [
                        "context": .string("main"),
                    ]
                )
            )
        )
    }

    func testClientSessionUnsubscribeRemovesEvent() {
        let session = BiDiClientSession()
        session.subscribe(events: ["log.entryAdded"], contexts: nil)
        session.unsubscribe(events: ["log.entryAdded"], contexts: nil)

        XCTAssertFalse(
            session.isSubscribed(
                to: BiDiEvent(
                    method: "log.entryAdded",
                    params: [
                        "source": .object([
                            "context": .string("main"),
                        ]),
                    ]
                )
            )
        )
    }

    func testErrorResponseEncodesStacktrace() throws {
        let response = BiDiResponse.failure(
            id: 7,
            error: "javascript error",
            message: "ReferenceError: foo is not defined",
            stacktrace: "stack"
        )

        let data = try JSONEncoder().encode(response)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(
            value,
            .object([
                "error": .string("javascript error"),
                "id": .int(7),
                "message": .string("ReferenceError: foo is not defined"),
                "stacktrace": .string("stack"),
                "type": .string("error"),
            ])
        )
    }

    func testJSONValueReadsIntegralDoubleAsInt() {
        XCTAssertEqual(JSONValue.double(1280).intValue, 1280)
        XCTAssertNil(JSONValue.double(1280.5).intValue)
    }

    func testCookieFilterMatchesNameDomainAndPath() throws {
        let cookie = try XCTUnwrap(
            HTTPCookie(properties: [
                .domain: "example.com",
                .name: "sid",
                .path: "/",
                .value: "abc",
            ])
        )

        XCTAssertTrue(
            BiDiCookieFilter(
                name: "sid",
                domain: "example.com",
                path: "/"
            ).matches(cookie)
        )
        XCTAssertFalse(
            BiDiCookieFilter(
                name: "other",
                domain: "example.com",
                path: "/"
            ).matches(cookie)
        )
    }
}
