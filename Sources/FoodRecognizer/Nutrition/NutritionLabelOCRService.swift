#if canImport(UIKit)

import Foundation
import UIKit
import Vision

/// Результат чтения этикетки пищевой ценности через Vision OCR.
/// `calories` — обязательны (минимальный сигнал что на фото лейбл, а не блюдо).
/// Остальные поля могут быть nil, если на этикетке их нет или OCR не смог распознать.
struct NutritionLabelReading {
    let calories: Double
    let protein: Double?
    let carbs: Double?
    let fats: Double?
    let portionGrams: Double?
    let rawText: String
}

/// Детерминированное чтение nutrition-этикеток. Работает на iOS 17+ через
/// VNRecognizeTextRequest.revision3 (кириллица, тайский, латиница, CJK).
///
/// Используется как fast-path в `NutritionAnalyzerService` ПЕРЕД VLM: если фото
/// содержит читаемый лейбл, OCR даёт точные цифры за ~200 мс вместо того чтобы
/// 2B-VLM «угадывала» калории и ставила 0/0/0.
public final class NutritionLabelOCRService {

    public init() {}

    func extract(from image: UIImage) async -> NutritionLabelReading? {
        guard let cgImage = image.cgImage else { return nil }

        return await withCheckedContinuation { (continuation: CheckedContinuation<NutritionLabelReading?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                // Сокращённый список языков: Vision теряет точность на non-latin
                // скриптах когда в списке 5+ языков (на тайском лейбле распознал
                // цифры 40/45 но keywords `พลังงาน/น้ำตาล` превратились в
                // латинский мусор `Unana/luuu`). Держим только широкие языки
                // самых частых лейблов.
                request.recognitionLanguages = ["en-US", "ru-RU", "th-TH"]
                if #available(iOS 16.0, *) {
                    request.revision = VNRecognizeTextRequestRevision3
                }

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    AppLog.error("OCR failed: \(error.localizedDescription)", category: .llm)
                    continuation.resume(returning: nil)
                    return
                }

                let lines = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: "\n")

                if !text.isEmpty {
                    AppLog.info(
                        "OCR raw (\(text.count) chars): \(text.prefix(600))",
                        category: .llm
                    )
                }

                let parsed = Self.parse(text: text)
                if parsed == nil, !text.isEmpty {
                    AppLog.info("OCR не нашёл nutrition-паттернов в тексте", category: .llm)
                }
                continuation.resume(returning: parsed)
            }
        }
    }

    // MARK: - Parsing

    private static func parse(text: String) -> NutritionLabelReading? {
        // Нормализация:
        // 1) lowercased для латиницы/кириллицы (тайский/CJK игнорит case)
        // 2) запятые → точки (EU decimal)
        // 3) схлопываем ЛЮБЫЕ whitespace-последовательности (включая \n) в один
        //    пробел — OCR таблиц разбивает ячейки по строкам, а regex ищет
        //    <keyword> <num> <unit> вплотную
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        guard let calories = extractCalories(normalized) else { return nil }

        // Санитарная проверка — нереалистичные значения отбрасываем
        guard (1...3000).contains(calories) else {
            AppLog.info("OCR calories out of range: \(calories)", category: .llm)
            return nil
        }

        return NutritionLabelReading(
            calories: calories,
            protein: extractMacro(normalized, keywords: proteinKeywords),
            carbs: extractMacro(normalized, keywords: carbsKeywords),
            fats: extractMacro(normalized, keywords: fatKeywords),
            portionGrams: extractPortion(normalized),
            rawText: text
        )
    }

    // MARK: - Keywords

    private static let proteinKeywords = [
        "protein", "proteins", "белки", "белок", "โปรตีน",
        "eiweiß", "eiweiss", "protéines", "蛋白质", "たんぱく"
    ]
    private static let fatKeywords = [
        "total fat", "saturated", "fat", "fats", "жиры", "жир",
        "ไขมัน", "fett", "lipides", "脂肪", "脂質"
    ]
    private static let carbsKeywords = [
        "carbohydrate", "carbohydrates", "carbs", "углеводы", "углевод",
        "คาร์โบไฮเดรต", "น้ำตาล", "sugar", "сахар",
        "kohlenhydrate", "glucides", "碳水", "炭水化物"
    ]

    // MARK: - Calories

    /// Ищет количество ккал. Порядок: точные kcal/ккал → energy-labels (тайское
    /// พลังงาน) → kJ с пересчётом.
    /// `\b` ставим только для ASCII-юнитов; для тайского/CJK word boundaries
    /// не работают корректно.
    private static func extractCalories(_ text: String) -> Double? {
        // 1. ASCII kcal/calorie/ккал (word boundary нужен чтобы "kcals" не ловил лишнее)
        let asciiKcalUnits = [
            #"k?cal(?:ori[ea]s?)?"#,
            #"ккал"#,
            #"калори[ий]?"#,
            #"кило?калори[ий]?"#
        ]
        for unit in asciiKcalUnits {
            if let v = firstNumber(in: text, pattern: #"(\d{1,4}(?:\.\d+)?)\s*\#(unit)\b"#) { return v }
            if let v = firstNumber(in: text, pattern: #"\#(unit)\b\D{0,15}?(\d{1,4}(?:\.\d+)?)"#) { return v }
        }

        // 2. Non-ASCII units — без \b
        let nonAsciiKcalUnits = [
            #"กิ?โลแคลอรี่?"#,   // тайский с опциональным tone marker
            #"กิโลแคลลอรี่?"#,  // вариант с удвоённой л (ошибка OCR)
            #"キロカロリー"#,
            #"千卡"#
        ]
        for unit in nonAsciiKcalUnits {
            if let v = firstNumber(in: text, pattern: #"(\d{1,4}(?:\.\d+)?)\s*\#(unit)"#) { return v }
            if let v = firstNumber(in: text, pattern: #"\#(unit)\D{0,15}?(\d{1,4}(?:\.\d+)?)"#) { return v }
        }

        // 3. Energy-label keywords: число в пределах 25 символов от ключа
        // («พลังงาน 40 กิโลแคลอรี» — kcal-юнит мог распознаться неточно)
        let energyLabels = [
            #"พลังงาน"#,         // тайский "энергия"
            #"energy"#,
            #"энергетическая ценность"#,
            #"energ[iy]a"#,       // it/es/pt
            #"エネルギー"#,
            #"能量"#
        ]
        for label in energyLabels {
            if let v = firstNumber(in: text, pattern: #"\#(label)\D{0,25}?(\d{1,4}(?:\.\d+)?)"#),
               v >= 1, v <= 2000 {
                return v
            }
        }

        // 4. kJ → kcal (1 kcal ≈ 4.184 kJ). Европейские лейблы часто дают оба.
        // Clamp: реалистичный диапазон kJ на упаковке 4...15000 (≈1-3600 ккал).
        // Значения за пределами почти всегда мусор OCR — пропускаем, пусть
        // решение примет downstream (VLM или общий sanity check в parse).
        let kjUnits = [#"kj\b"#, #"кдж"#, #"キロジュール"#, #"千焦"#]
        for unit in kjUnits {
            if let v = firstNumber(in: text, pattern: #"(\d{1,5}(?:\.\d+)?)\s*\#(unit)"#),
               (4.0...15_000.0).contains(v) {
                return (v / 4.184).rounded()
            }
        }

        return nil
    }

    // MARK: - Macros

    /// Ищет первое число в окне ±30 символов от ключевого слова.
    /// `g\b/г\b` дают word boundary только для латиницы/кириллицы; тайское
    /// `กรัม` и японское `グラム` — без \b.
    /// Возвращает значения < 500г (отсеивает калории/вес-порции).
    private static func extractMacro(_ text: String, keywords: [String]) -> Double? {
        // Whitespace уже схлопнут в parse() → в regex работаем с одной строкой
        for keyword in keywords {
            let escaped = NSRegularExpression.escapedPattern(for: keyword)

            // A) strict: "keyword [separator] <num>g/г/กรัม"
            let unitsASCII = #"(?:g|г|гр)\b"#
            let unitsIntl = #"(?:กรัม|グラム|克)"#

            let a1 = #"\#(escaped)[\s:\-]{0,6}(\d{1,3}(?:\.\d+)?)\s*\#(unitsASCII)"#
            if let v = firstNumber(in: text, pattern: a1), v >= 0, v < 500 { return v }
            let a2 = #"\#(escaped)[\s:\-]{0,6}(\d{1,3}(?:\.\d+)?)\s*\#(unitsIntl)"#
            if let v = firstNumber(in: text, pattern: a2), v >= 0, v < 500 { return v }

            // B) wider: "keyword ... <num> <unit>" в окне 30 символов (OCR мог вставить мусор)
            let b1 = #"\#(escaped).{0,30}?(\d{1,3}(?:\.\d+)?)\s*\#(unitsASCII)"#
            if let v = firstNumber(in: text, pattern: b1), v >= 0, v < 500 { return v }
            let b2 = #"\#(escaped).{0,30}?(\d{1,3}(?:\.\d+)?)\s*\#(unitsIntl)"#
            if let v = firstNumber(in: text, pattern: b2), v >= 0, v < 500 { return v }

            // C) reverse: "<num>g ... keyword" — EU-style "8g Fat"
            let c1 = #"(\d{1,3}(?:\.\d+)?)\s*\#(unitsASCII).{0,20}?\#(escaped)"#
            if let v = firstNumber(in: text, pattern: c1), v >= 0, v < 500 { return v }
            let c2 = #"(\d{1,3}(?:\.\d+)?)\s*\#(unitsIntl).{0,20}?\#(escaped)"#
            if let v = firstNumber(in: text, pattern: c2), v >= 0, v < 500 { return v }

            // Раньше был fallback D (keyword + число без юнита). Он давал
            // wildly wrong значения: на русском лейбле "Белки 40" где "40" —
            // это процент дневной нормы или соседнее поле, D возвращал 40г
            // белка. Без юнита нельзя уверенно опознать макро-значение —
            // лучше вернуть nil и отдать VLM.
        }
        return nil
    }

    // MARK: - Portion size

    /// Ищет размер порции: "180 ml", "250 г", "180 มล.", "per 100g".
    /// Пропускает явно «на 100 г / per 100g» маркеры — это базис, а не порция
    /// (иначе OCR для тайского "ต่อ 1 ขวด (180 мл)" вернёт 180, а для EU
    /// "per 100 ml" вернёт 100 и испортит расчёт).
    private static func extractPortion(_ text: String) -> Double? {
        let patterns = [
            // Миллилитры
            #"(\d{2,4}(?:\.\d+)?)\s*ml\b"#,
            #"(\d{2,4}(?:\.\d+)?)\s*мл"#,
            #"(\d{2,4}(?:\.\d+)?)\s*มล"#,
            // Граммы
            #"(\d{2,4}(?:\.\d+)?)\s*g\b"#,
            #"(\d{2,4}(?:\.\d+)?)\s*г\b"#,
            #"(\d{2,4}(?:\.\d+)?)\s*กรัม"#
        ]

        // Соберём все кандидаты и отфильтруем «базовые» 100 если рядом "per 100"
        let candidates = patterns.flatMap { allNumbers(in: text, pattern: $0) }
        let filtered = candidates.filter { value in
            guard (30...2000).contains(value) else { return false }
            // Исключаем "per 100g / на 100г / ต่อ 100" — это не порция
            if value == 100, text.contains("per 100") || text.contains("на 100") || text.contains("ต่อ 100") {
                return false
            }
            return true
        }
        return filtered.first
    }

    // MARK: - Regex helpers

    private static func firstNumber(in text: String, pattern: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: text),
              let value = Double(text[captureRange]) else { return nil }
        return value
    }

    private static func allNumbers(in text: String, pattern: String) -> [Double] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges >= 2,
                  let captureRange = Range(match.range(at: 1), in: text) else { return nil }
            return Double(text[captureRange])
        }
    }
}

#endif
