import Foundation

enum PatchPayloadMerge {
    static func materialize(
        rule: PatchRule,
        existing: Data?,
        settings: [String: String]
    ) throws -> Data {
        switch rule.resolvedOperation {
        case "replace":
            return rule.replacementData
        case "merge_json":
            return try mergeJSON(
                existing: existing,
                overlay: rule.replacementData,
                settings: settings
            )
        case "merge_plist":
            return try mergePlist(
                existing: existing,
                overlay: rule.replacementData,
                settings: settings
            )
        default:
            throw PatchPackageError.invalidProject
        }
    }

    static func settingsDefaults(from value: Any?) -> [String: String] {
        var result: [String: String] = [:]
        if let fields = value as? [[String: Any]] {
            for field in fields {
                addField(field, to: &result)
            }
            return result
        }
        guard let document = value as? [String: Any] else { return result }
        if let fields = document["fields"] as? [[String: Any]] {
            for field in fields {
                addField(field, to: &result)
            }
        }
        if let values = document["values"] as? [String: Any] {
            for (key, raw) in values {
                if let text = scalarString(raw) {
                    result[key] = text
                }
            }
        }
        return result
    }

    private static func addField(_ field: [String: Any], to result: inout [String: String]) {
        let identifier = (field["id"] as? String) ?? (field["key"] as? String)
        guard let identifier, !identifier.isEmpty else { return }
        if let value = field["defaultValue"] ?? field["value"], let text = scalarString(value) {
            result[identifier] = text
        }
    }

    private static func mergeJSON(
        existing: Data?,
        overlay: Data,
        settings: [String: String]
    ) throws -> Data {
        let overlayObject = try JSONSerialization.jsonObject(with: overlay)
        let baseObject: Any
        if let existing, !existing.isEmpty,
           let parsed = try? JSONSerialization.jsonObject(with: existing) {
            baseObject = parsed
        } else {
            baseObject = [String: Any]()
        }
        let merged = mergeValue(baseObject, overlayObject, settings: settings)
        return try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
    }

    private static func mergePlist(
        existing: Data?,
        overlay: Data,
        settings: [String: String]
    ) throws -> Data {
        let overlayObject = try PropertyListSerialization.propertyList(
            from: overlay,
            options: [],
            format: nil
        )
        let baseObject: Any
        if let existing, !existing.isEmpty,
           let parsed = try? PropertyListSerialization.propertyList(
            from: existing,
            options: [],
            format: nil
           ) {
            baseObject = parsed
        } else {
            baseObject = [String: Any]()
        }
        let merged = mergeValue(baseObject, overlayObject, settings: settings)
        return try PropertyListSerialization.data(
            fromPropertyList: merged,
            format: .binary,
            options: 0
        )
    }

    private static func mergeValue(_ base: Any, _ overlay: Any, settings: [String: String]) -> Any {
        if let overlayDictionary = dictionary(overlay) {
            var result = dictionary(base) ?? [:]
            for (key, value) in overlayDictionary {
                if isRemovedValue(value) {
                    result.removeValue(forKey: key)
                    continue
                }
                if let current = result[key] {
                    result[key] = mergeValue(current, value, settings: settings)
                } else {
                    result[key] = substitute(value, settings: settings)
                }
            }
            return result
        }
        if let overlayArray = overlay as? [Any] {
            return overlayArray.map { substitute($0, settings: settings) }
        }
        return substitute(overlay, settings: settings)
    }

    private static func substitute(_ value: Any, settings: [String: String]) -> Any {
        if let text = value as? String {
            return substitute(text, settings: settings)
        }
        if let dictionaryValue = dictionary(value) {
            return dictionaryValue.mapValues { substitute($0, settings: settings) }
        }
        if let array = value as? [Any] {
            return array.map { substitute($0, settings: settings) }
        }
        return value
    }

    private static func substitute(_ text: String, settings: [String: String]) -> String {
        var result = text
        for (identifier, value) in settings {
            result = result.replacingOccurrences(of: "{{\(identifier)}}", with: value)
        }
        return result
    }

    private static func dictionary(_ value: Any) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func isRemovedValue(_ value: Any) -> Bool {
        if let text = value as? String {
            return text == "{{__remove__}}"
        }
        return false
    }

    private static func scalarString(_ value: Any) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        if let flag = value as? Bool { return flag ? "true" : "false" }
        return nil
    }
}
