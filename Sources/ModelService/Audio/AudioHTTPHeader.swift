import Foundation
import ModelAPI

enum AudioHTTPHeader {
    static func parse(_ data: Data) throws -> (HTTPRequest, Int, Int)? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard split.lowerBound < 16384, let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { throw ModelAPIError.invalid("Invalid headers.") }
        let lines = head.components(separatedBy: "\r\n")
        var length: Int?
        let normalized = try lines.map { line -> String in
            if line.lowercased().hasPrefix("content-length:") {
                guard length == nil, let value = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)), value >= 0 else { throw ModelAPIError.invalid("Invalid or duplicate content length.") }
                length = value; return "Content-Length: 0"
            }
            return line
        }.joined(separator: "\r\n")
        guard var request = try HTTPParser.parse(Data((normalized + "\r\n\r\n").utf8)) else { throw ModelAPIError.invalid("Invalid headers.") }
        guard request.method == "POST", request.path == "/v1/audio/transcriptions" else { return nil }
        guard let length, length > 0, length <= AudioIO.uploadLimit + 65536, request.headers["content-type"]?.lowercased().hasPrefix("multipart/form-data;") == true else { throw ModelAPIError.limit("Use multipart audio with Content-Length, up to 64 MiB plus bounded fields.") }
        request.headers["content-length"] = String(length)
        return (request, length, split.upperBound)
    }
}
