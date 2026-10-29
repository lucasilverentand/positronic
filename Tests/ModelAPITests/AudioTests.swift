import Foundation
import AVFoundation
import XCTest
@testable import ModelAPI
@testable import ModelService

final class AudioTests: XCTestCase, @unchecked Sendable {
    func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AudioTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); return folder
    }
    func wave(_ path: URL, seconds: Double = 0.1, rate: Double = 44100) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let file = try AVAudioFile(forWriting: path, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * rate))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 { for n in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][n] = Float(sin(Double(n)*0.1))*0.1 } }
        try file.write(from: buffer)
    }
    func testNormalizeAndValidateWithoutLoadingAModel() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("input.wav"), output = dir.appendingPathComponent("out.wav")
        try wave(input); try AudioIO.validate(input); try await AudioIO.normalize(input, to: output)
        let result = try AVAudioFile(forReading: output)
        XCTAssertEqual(result.processingFormat.sampleRate, 16000); XCTAssertEqual(result.processingFormat.channelCount, 1)
        XCTAssertEqual(Double(result.length)/16000, 0.1, accuracy: 0.02)
        let bad = dir.appendingPathComponent("bad"); try Data([0,1]).write(to: bad); XCTAssertThrowsError(try AudioIO.validate(bad))
    }
    func testMultipartStreamingParserAndCleanup() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("input.wav"); try wave(input)
        var bytes = Data("--fixture\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-large-v3-turbo\r\n--fixture\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nnl\r\n--fixture\r\nContent-Disposition: form-data; name=\"file\"; filename=\"../../private.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        bytes.append(try Data(contentsOf: input)); bytes.append(Data("\r\n--fixture--\r\n".utf8))
        let upload = dir.appendingPathComponent("multipart"); try bytes.write(to: upload)
        let result = try MultipartAudio.parse(file: upload, contentType: "multipart/form-data; boundary=fixture", directory: dir)
        XCTAssertEqual(result.language,"nl"); XCTAssertEqual(result.file.deletingLastPathComponent().path,dir.path)
        XCTAssertEqual(try Data(contentsOf: result.file), try Data(contentsOf: input))
        try FileManager.default.removeItem(at: result.file)
        bytes.removeLast(8); try bytes.write(to: upload)
        XCTAssertThrowsError(try MultipartAudio.parse(file: upload, contentType: "multipart/form-data; boundary=fixture", directory: dir))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasSuffix(".upload") })
    }
    func testAudioHeadersAndSpeechLimits() throws {
        let valid = "POST /v1/audio/transcriptions HTTP/1.1\r\nContent-Length: 2097152\r\nContent-Type: multipart/form-data; boundary=test\r\n\r\n"
        XCTAssertEqual(try AudioHTTPHeader.parse(Data(valid.utf8))?.1, 2097152)
        XCTAssertThrowsError(try AudioHTTPHeader.parse(Data(valid.replacingOccurrences(of:"2097152",with:"999999999").utf8)))
        XCTAssertThrowsError(try SpeechRequest(input:String(repeating:"a",count:5001)).validate())
        XCTAssertThrowsError(try SpeechRequest(input:"Test",language:"fr").validate())
        XCTAssertThrowsError(try SpeechRequest(input:"Test",voice:"clone").validate())
        try SpeechRequest(input:"Hallo",language:"nl").validate()
    }
}
extension AudioTests {
    func testRemovalPreservesSharedAudioAssetsUntilLastModelIsRemoved() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let repo = dir.appendingPathComponent("huggingface/hub/models--fixture--shared"), snapshot = repo.appendingPathComponent("snapshots/pinned")
        try FileManager.default.createDirectory(at:snapshot,withIntermediateDirectories:true)
        try Data([1]).write(to:snapshot.appendingPathComponent("weights.safetensors"))
        try FileManager.default.createDirectory(at:dir.appendingPathComponent("models"),withIntermediateDirectories:true)
        for id in AudioCatalog.ids {
            let local=dir.appendingPathComponent("Installed/"+id);try FileManager.default.createDirectory(at:local,withIntermediateDirectories:true)
            let receipt: [String:JSONValue] = ["dependencies":.object(["shared":.string(snapshot.path)])]
            try JSONEncoder().encode(receipt).write(to:AudioCatalog.receipt(id,at:dir))
        }
        try AudioCatalog.remove(AudioCatalog.ids[0],at:dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath:repo.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:AudioCatalog.receipt(AudioCatalog.ids[0],at:dir).path))
        try AudioCatalog.remove(AudioCatalog.ids[1],at:dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath:repo.path))
    }
}
extension AudioTests {
    func testSwiftClientStreamsMultipartLargerThanJSONLimitAndServerCleansUp() async throws {
        let dir=try folder();defer { try? FileManager.default.removeItem(at:dir) }
        let input=dir.appendingPathComponent("input.wav");try wave(input,seconds:4)
        XCTAssertGreaterThan(try Data(contentsOf:input).count,1_000_000)
        let ready=expectation(description:"Ready"),seen=expectation(description:"Streamed upload")
        let server=try LoopbackServer(port:0,uploadDirectory:dir,authorizeUpload:{ $0.bearer == "synthetic-test-token" }) { request in
            do {
                XCTAssertTrue(request.body.isEmpty)
                let source=try XCTUnwrap(request.upload)
                let upload=try MultipartAudio.parse(file:source,contentType:try XCTUnwrap(request.headers["content-type"]),directory:dir)
                defer { try? FileManager.default.removeItem(at:upload.file) }
                XCTAssertEqual(upload.language,"nl");seen.fulfill()
                return try .json(ModelJob(model:"whisper-large-v3-turbo",operation:"transcription"),status:202)
            } catch { XCTFail(error.localizedDescription);return .error("Invalid synthetic upload",status:400) }
        }
        let task=Task { try await server.run { ready.fulfill() } }
        await fulfillment(of:[ready],timeout:3)
        defer { server.stop();task.cancel() }
        let client=try ModelAPIClient(baseURL:URL(string:"http://127.0.0.1:\(try XCTUnwrap(server.port))")!,apiKey:"synthetic-test-token")
        _ = try await client.transcribe(file:input,language:"nl")
        await fulfillment(of:[seen],timeout:2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:dir.appendingPathComponent("Uploads").path).isEmpty)
        server.stop();try await task.value
    }
}
