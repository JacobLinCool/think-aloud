import Foundation
import XCTest

final class LocalizationCatalogTests: XCTestCase {
    private static let formatExpression = try! NSRegularExpression(
        // Exclude the optional printf space flag: localization keys contain ordinary phrases
        // such as "100% local", and Swift interpolation never emits that flag here.
        pattern: #"%(?:(\d+)\$)?[-+#0.0-9]*(hh|h|ll|l|q|z|t|j)?([@diuoxXfFeEgGaAcCsSp])"#
    )

    private struct Catalog: Decodable {
        let strings: [String: Entry]
    }

    private struct Entry: Decodable {
        let extractionState: String?
        let localizations: [String: Localization]?
    }

    private struct Localization: Decodable {
        let stringUnit: StringUnit?
    }

    private struct StringUnit: Decodable {
        let state: String?
        let value: String
    }

    func testCatalogContainsOnlyLiveCompleteTraditionalChineseEntries() throws {
        let catalog = try loadCatalog()
        XCTAssertFalse(catalog.strings.isEmpty)

        for source in catalog.strings.keys.sorted() {
            let entry = try XCTUnwrap(catalog.strings[source])
            XCTAssertNotEqual(
                entry.extractionState,
                "stale",
                "Catalog contains a stale source key: \(source.debugDescription)"
            )
            let translation = try XCTUnwrap(
                entry.localizations?["zh-Hant"]?.stringUnit,
                "Missing zh-Hant translation for \(source.debugDescription)"
            )
            XCTAssertEqual(
                translation.state,
                "translated",
                "zh-Hant translation is not complete for \(source.debugDescription)"
            )
            XCTAssertFalse(
                translation.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "zh-Hant translation is empty for \(source.debugDescription)"
            )
        }
    }

    func testTranslatedFormatSpecifiersPreserveSourceArgumentTypes() throws {
        let catalog = try loadCatalog()

        for source in catalog.strings.keys.sorted() {
            let sourceArguments = try formatArguments(in: source)
            guard !sourceArguments.isEmpty else { continue }

            let localizations = catalog.strings[source]?.localizations ?? [:]
            for locale in localizations.keys.sorted() {
                guard let value = localizations[locale]?.stringUnit?.value else { continue }
                XCTAssertEqual(
                    try formatArguments(in: value),
                    sourceArguments,
                    "\(locale) changes the printf argument positions or types for \(source.debugDescription)"
                )
            }
        }
    }

    private func loadCatalog() throws -> Catalog {
        let catalogURL = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "LocalizationCatalog",
                withExtension: "json"
            ),
            "The test target must embed the source string catalog as LocalizationCatalog.json"
        )
        return try JSONDecoder().decode(
            Catalog.self,
            from: Data(contentsOf: catalogURL)
        )
    }

    /// Returns each printf argument position and its ABI-relevant conversion. Positional
    /// specifiers let translators reorder arguments safely; changing the conversion at a position
    /// can make Foundation read a scalar as an object (or vice versa) and crash at runtime.
    private func formatArguments(in value: String) throws -> [Int: String] {
        let range = NSRange(value.startIndex..., in: value)
        var arguments: [Int: String] = [:]
        var nextAutomaticPosition = 1

        for match in Self.formatExpression.matches(in: value, range: range) {
            let position: Int
            if let positionRange = Range(match.range(at: 1), in: value) {
                position = try XCTUnwrap(Int(value[positionRange]))
            } else {
                position = nextAutomaticPosition
                nextAutomaticPosition += 1
            }

            let modifier = Range(match.range(at: 2), in: value)
                .map { String(value[$0]) } ?? ""
            let conversionRange = try XCTUnwrap(Range(match.range(at: 3), in: value))
            let conversion = modifier + String(value[conversionRange])
            if let existing = arguments[position] {
                XCTAssertEqual(existing, conversion, "Argument \(position) uses conflicting conversions")
            } else {
                arguments[position] = conversion
            }
        }
        return arguments
    }
}
