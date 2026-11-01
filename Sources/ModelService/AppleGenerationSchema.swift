import Foundation
import FoundationModels
import ModelAPI

enum AppleGenerationSchema {
    private static func integer(_ value: JSONValue?) -> Int? { if case .number(let n) = value, n.isFinite, n >= 0, n <= Double(Int.max - 1) { return Int(n) }; return nil }
    static func convert(_ json: JSONValue, name: String) throws -> DynamicGenerationSchema {
        guard let object = json.object else { throw ModelAPIError.invalid("Invalid Apple generation schema.") }
        if case .array(let types) = object["type"] {
            return .init(name: name, anyOf: try types.enumerated().map { index, type in
                var alternative = object; alternative["type"] = type
                return try convert(.object(alternative), name: name + "_" + String(index))
            })
        }
        guard let type = object["type"]?.string else { throw ModelAPIError.invalid("Missing Apple generation type.") }
        switch type {
        case "object":
            guard let properties = object["properties"]?.object else { throw ModelAPIError.invalid("Missing generation properties.") }
            let required = Set(object["required"]?.arrayStrings ?? [])
            return .init(name: name, properties: try properties.keys.sorted().map { key in
                .init(name: key, description: properties[key]?.object?["description"]?.string, schema: try convert(properties[key]!, name: name + "_" + key), isOptional: !required.contains(key))
            })
        case "string":
            if let choices = object["enum"]?.arrayStrings { return .init(name: name, anyOf: choices) }
            return .init(type: String.self)
        case "array":
            guard let items = object["items"] else { throw ModelAPIError.invalid("Missing array item schema.") }
            return .init(arrayOf: try convert(items, name: name + "_item"), minimumElements: integer(object["minItems"]), maximumElements: integer(object["maxItems"]))
        case "integer": return .init(type: Int.self)
        case "null":
            if #available(macOS 26.4, iOS 26.4, *) { return .null }
            throw ModelAPIError.unavailable("Nullable app tool arguments require macOS 26.4 or later.")
        case "number": return .init(type: Double.self)
        case "boolean": return .init(type: Bool.self)
        default: throw ModelAPIError.invalid("Unsupported Apple generation type: \(type).")
        }
    }
}

private extension JSONValue {
    var arrayStrings: [String]? { if case .array(let values) = self { values.compactMap(\.string) } else { nil } }
}
