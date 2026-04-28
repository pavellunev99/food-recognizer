import Testing
@testable import FoodEval

@Suite("ModelOutput.parse")
struct ModelOutputTests {

    @Test("parses clean JSON")
    func parsesCleanJSON() {
        let raw = """
        {"foodName": "apple", "calories": 95, "protein": 0.5, "carbs": 25.0, "fats": 0.3, "portionGrams": 182}
        """
        let parsed = ModelOutput.parse(rawJSON: raw)
        #expect(parsed != nil)
        #expect(parsed?.foodName == "apple")
        #expect(parsed?.calories == 95)
        #expect(parsed?.protein == 0.5)
        #expect(parsed?.carbs == 25.0)
        #expect(parsed?.fats == 0.3)
        #expect(parsed?.portionGrams == 182)
    }

    @Test("parses markdown-wrapped JSON (```json ... ```)")
    func parsesMarkdownWrappedJSON() {
        let raw = """
        ```json
        {
          "foodName": "banana",
          "calories": 105,
          "protein": 1.3,
          "carbs": 27.0,
          "fats": 0.4,
          "portionGrams": 118
        }
        ```
        """
        let parsed = ModelOutput.parse(rawJSON: raw)
        #expect(parsed != nil)
        #expect(parsed?.foodName == "banana")
        #expect(parsed?.calories == 105)
    }

    @Test("parses JSON inside prose preamble")
    func parsesJSONInsideText() {
        let raw = """
        Here is the nutritional analysis of the image:

        {
          "foodName": "carbonara",
          "calories": 600,
          "protein": 22,
          "carbs": 70,
          "fats": 25,
          "portionGrams": 300
        }

        Hope this helps!
        """
        let parsed = ModelOutput.parse(rawJSON: raw)
        #expect(parsed != nil)
        #expect(parsed?.foodName == "carbonara")
        #expect(parsed?.calories == 600)
        #expect(parsed?.portionGrams == 300)
    }

    @Test("returns nil on empty input")
    func returnsNilOnEmpty() {
        #expect(ModelOutput.parse(rawJSON: "") == nil)
        #expect(ModelOutput.parse(rawJSON: "   \n  ") == nil)
    }

    @Test("returns nil when no JSON object")
    func returnsNilOnNonJSON() {
        let parsed = ModelOutput.parse(rawJSON: "I cannot analyze this image.")
        #expect(parsed == nil)
    }

    @Test("parses partial JSON (some fields missing)")
    func parsesPartialJSON() {
        let raw = """
        {"foodName": "apple", "calories": 95}
        """
        let parsed = ModelOutput.parse(rawJSON: raw)
        #expect(parsed != nil)
        #expect(parsed?.foodName == "apple")
        #expect(parsed?.calories == 95)
        #expect(parsed?.protein == nil)
        #expect(parsed?.carbs == nil)
    }

    @Test("parses numbers given as strings (lenient fallback)")
    func parsesStringNumbers() {
        let raw = """
        {"foodName": "apple", "calories": "95", "protein": "0.5", "carbs": "25", "fats": "0.3", "portionGrams": "182"}
        """
        let parsed = ModelOutput.parse(rawJSON: raw)
        #expect(parsed != nil)
        #expect(parsed?.calories == 95)
        #expect(parsed?.protein == 0.5)
    }
}
