import Foundation
import ModelAPI

public struct MultipartAudio {
    public var file: URL
    public var model: String
    public var language: String
    public static func parse(file source: URL, contentType: String, directory: URL) throws -> Self {
        guard let marker = contentType.components(separatedBy: ";").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix("boundary=") }) else { throw ModelAPIError.invalid("Multipart boundary required.") }
        let boundary = String(marker.dropFirst(9)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard (1...70).contains(boundary.utf8.count), boundary.utf8.allSatisfy({ $0 >= 33 && $0 < 127 }) else { throw ModelAPIError.invalid("Invalid multipart boundary.") }
        let reader = try MultipartReader(source)
        defer { reader.close() }
        guard try reader.line() == "--" + boundary else { throw ModelAPIError.invalid("Invalid multipart body.") }
        let output = directory.appendingPathComponent(UUID().uuidString + ".upload")
        var complete = false; defer { if !complete { try? FileManager.default.removeItem(at: output) } }
        var fields: [String: String] = [:]; var hasFile = false; var count = 0
        while true {
            count += 1; guard count <= 3 else { throw ModelAPIError.invalid("Supply only file, model and language fields.") }
            var disposition = ""; var headers = 0
            while true {
                let line = try reader.line(); if line.isEmpty { break }; headers += line.utf8.count
                guard headers <= 8192 else { throw ModelAPIError.limit("Multipart headers exceed 8 KiB.") }
                if line.lowercased().hasPrefix("content-disposition:") { guard disposition.isEmpty else { throw ModelAPIError.invalid("Duplicate part disposition.") }; disposition = line }
            }
            let names = disposition.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let field = names.first(where: { $0.hasPrefix("name=\"") }) else { throw ModelAPIError.invalid("Each part needs a field name.") }
            let name = String(field.dropFirst(6).dropLast())
            guard ["file", "model", "language"].contains(name), fields[name] == nil, !(name == "file" && hasFile) else { throw ModelAPIError.invalid("Unknown or duplicate multipart field.") }
            let terminator = Data(("\r\n--" + boundary).utf8)
            if name == "file" {
                FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
                let writer = try FileHandle(forWritingTo: output); defer { try? writer.close() }
                try reader.part(until: terminator, limit: AudioIO.uploadLimit) { try writer.write(contentsOf: $0) }; hasFile = true
            } else {
                var data = Data(); try reader.part(until: terminator, limit: 1024) { data.append($0) }
                guard let text = String(data: data, encoding: .utf8) else { throw ModelAPIError.invalid("Invalid multipart text.") }; fields[name] = text
            }
            let suffix = try reader.take(2)
            if suffix == Data("--".utf8) {
                let tail = try reader.remainingTail()
                guard tail.isEmpty || tail == Data("\r\n".utf8) else { throw ModelAPIError.invalid("Trailing multipart data is unsupported.") }; break
            }
            guard suffix == Data("\r\n".utf8) else { throw ModelAPIError.invalid("Invalid multipart separator.") }
        }
        guard hasFile, fields["model"] == "whisper-large-v3-turbo", let language = fields["language"], ["en", "nl"].contains(language) else { throw ModelAPIError.invalid("Supply an audio file, model whisper-large-v3-turbo and language en or nl.") }
        try AudioIO.validate(output); complete = true
        return .init(file: output, model: fields["model"]!, language: language)
    }
}
private final class MultipartReader {
    let handle: FileHandle; var buffer = Data(); var eof = false
    init(_ file: URL) throws { handle = try FileHandle(forReadingFrom: file) }
    func close() { try? handle.close() }
    func fill() throws {
        let data = try handle.read(upToCount: 65536) ?? Data(); eof = data.isEmpty; buffer.append(data)
    }
    func line() throws -> String {
        while buffer.range(of: Data("\r\n".utf8)) == nil && !eof { guard buffer.count < 8192 else { throw ModelAPIError.limit("Multipart header too large.") }; try fill() }
        guard let range = buffer.range(of: Data("\r\n".utf8)), range.lowerBound <= 8192, let text = String(data: buffer[..<range.lowerBound], encoding: .utf8) else { throw ModelAPIError.invalid("Truncated multipart header.") }
        buffer.removeSubrange(..<range.upperBound); return text
    }
    func take(_ count: Int) throws -> Data {
        while buffer.count < count && !eof { try fill() }
        guard buffer.count >= count else { throw ModelAPIError.invalid("Truncated multipart body.") }
        let data = Data(buffer.prefix(count)); buffer.removeFirst(count); return data
    }
    func part(until delimiter: Data, limit: Int, write: (Data) throws -> Void) throws {
        var total = 0
        while true {
            if let range = buffer.range(of: delimiter) {
                let data = Data(buffer[..<range.lowerBound]); total += data.count
                guard total <= limit else { throw ModelAPIError.limit("Multipart part is too large.") }
                try write(data); buffer.removeSubrange(..<range.upperBound); return
            }
            guard !eof else { throw ModelAPIError.invalid("Truncated multipart body.") }
            if buffer.count > delimiter.count {
                let count = buffer.count - delimiter.count; let data = Data(buffer.prefix(count)); total += count
                guard total <= limit else { throw ModelAPIError.limit("Multipart part is too large.") }
                try write(data); buffer.removeFirst(count)
            }
            try fill()
        }
    }
    func remainingTail() throws -> Data {
        while !eof { guard buffer.count <= 2 else { throw ModelAPIError.invalid("Unexpected multipart tail.") }; try fill() }; return buffer
    }
}
