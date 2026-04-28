import Testing
import Foundation
@testable import NutriLensEval

private func validItem(id: String = "001_apple") -> GroundTruthItem {
    GroundTruthItem(
        id: id,
        image: "tier1/\(id).jpg",
        tier: 1,
        category: "fruit",
        nameAliases: ["apple", "яблоко"],
        calories: 95,
        protein: 0.5,
        carbs: 25.0,
        fats: 0.3,
        portionGrams: 182,
        tolerancePercent: 10,
        source: "USDA",
        license: "CC-BY-SA",
        imageUrl: "https://commons.wikimedia.org/test"
    )
}

@Suite("GroundTruth")
struct GroundTruthTests {

    @Test("validate accepts well-formed document")
    func validateOK() throws {
        let doc = GroundTruthDocument(version: 1, items: [validItem()])
        try doc.validate()  // не должно бросить
    }

    @Test("validate rejects duplicate ids")
    func rejectDuplicateIds() {
        let doc = GroundTruthDocument(
            version: 1,
            items: [validItem(id: "x"), validItem(id: "x")]
        )
        #expect(throws: GroundTruthError.self) {
            try doc.validate()
        }
    }

    @Test("validate rejects tier out of range")
    func rejectTierOutOfRange() {
        let bad = GroundTruthItem(
            id: "x",
            image: "tier1/x.jpg",
            tier: 5,
            category: "fruit",
            nameAliases: ["a"],
            calories: 1,
            protein: 1,
            carbs: 1,
            fats: 1,
            portionGrams: 1,
            tolerancePercent: 10,
            source: "x",
            license: "x"
        )
        let doc = GroundTruthDocument(version: 1, items: [bad])
        #expect(throws: GroundTruthError.self) {
            try doc.validate()
        }
    }

    @Test("validate rejects absolute image path")
    func rejectAbsoluteImagePath() {
        let bad = GroundTruthItem(
            id: "x",
            image: "/abs/path/x.jpg",
            tier: 1,
            category: "fruit",
            nameAliases: ["a"],
            calories: 1,
            protein: 1,
            carbs: 1,
            fats: 1,
            portionGrams: 1,
            tolerancePercent: 10,
            source: "x",
            license: "x"
        )
        let doc = GroundTruthDocument(version: 1, items: [bad])
        #expect(throws: GroundTruthError.self) {
            try doc.validate()
        }
    }

    @Test("validate rejects zero tolerance")
    func rejectZeroTolerance() {
        let bad = GroundTruthItem(
            id: "x",
            image: "tier1/x.jpg",
            tier: 1,
            category: "fruit",
            nameAliases: ["a"],
            calories: 1,
            protein: 1,
            carbs: 1,
            fats: 1,
            portionGrams: 1,
            tolerancePercent: 0,
            source: "x",
            license: "x"
        )
        let doc = GroundTruthDocument(version: 1, items: [bad])
        #expect(throws: GroundTruthError.self) {
            try doc.validate()
        }
    }

    @Test("validate rejects empty aliases")
    func rejectEmptyAliases() {
        let bad = GroundTruthItem(
            id: "x",
            image: "tier1/x.jpg",
            tier: 1,
            category: "fruit",
            nameAliases: [],
            calories: 1,
            protein: 1,
            carbs: 1,
            fats: 1,
            portionGrams: 1,
            tolerancePercent: 10,
            source: "x",
            license: "x"
        )
        let doc = GroundTruthDocument(version: 1, items: [bad])
        #expect(throws: GroundTruthError.self) {
            try doc.validate()
        }
    }

    @Test("load from URL parses real JSON")
    func loadFromTempFile() throws {
        let doc = GroundTruthDocument(version: 1, items: [validItem()])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(doc)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ground_truth_\(UUID().uuidString).json")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let loaded = try GroundTruthDocument.load(from: tmp)
        #expect(loaded.version == 1)
        #expect(loaded.items.count == 1)
        #expect(loaded.items.first?.id == "001_apple")
        try loaded.validate()
    }

    @Test("load throws fileNotFound for missing path")
    func loadMissingFile() {
        let url = URL(fileURLWithPath: "/no/such/path/ground_truth_\(UUID().uuidString).json")
        #expect(throws: GroundTruthError.self) {
            _ = try GroundTruthDocument.load(from: url)
        }
    }
}
