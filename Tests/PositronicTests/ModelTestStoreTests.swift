import Foundation
import XCTest
@testable import Positronic
import ModelAPI
import ModelService

@MainActor
final class ModelTestStoreTests: XCTestCase {
    func setup() async throws -> (AppStore,[ManagedModel],URL) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("ModelPanelTests/"+UUID().uuidString)
        let queue=JobQueue(directory:folder,interval:.milliseconds(5),probe:{ .init(physical:36 << 30,available:30 << 30,disk:100 << 30) })
        let transport:ModelAPIClient.Transport = { wire in
            let body:Data
            switch wire.url?.path {
            case "/api/tags":body=Data(#"{"models":[{"name":"fixture:one","size":1024},{"name":"fixture:two","size":1024},{"name":"fixture:choice","size":1024},{"name":"fixture:embed","size":1024}]}"#.utf8)
            case "/api/show":
                let value=try JSONDecoder().decode(JSONValue.self,from:wire.httpBody!)
                let name=value.object?["model"]?.string ?? ""
                let kind=name == "fixture:choice" ? "decision" : name == "fixture:embed" ? "embedding" : "completion"
                body=try JSONEncoder().encode(JSONValue.object(["capabilities":.array([.string(kind)]),"thinking":.object(["values":.array([.bool(false),.bool(true)])])]))
            case "/v1/systemone":
                let request=try JSONDecoder().decode(DecisionRequest.self,from:wire.httpBody!)
                let keys=request.questions["result"]!.criteria.keys.sorted()
                let answer=DecisionAnswer(choice:keys[0],probabilities:Dictionary(uniqueKeysWithValues:keys.map { ($0,1.0/Double(keys.count)) }),confidence:0.5)
                body=try JSONEncoder().encode(DecisionResponse(model:request.model,answers:["result":answer],usage:.init(input:8,output:1)))
            case "/api/embed":
                let input=try JSONDecoder().decode(JSONValue.self,from:wire.httpBody!)
                body=try JSONEncoder().encode(JSONValue.object(["model":input.object!["model"]!,"embeddings":.array([.array([.number(1),.number(0)]),.array([.number(0.8),.number(0.2)])]),"prompt_eval_count":.number(8)]))
            default:
                let input=try JSONDecoder().decode(JSONValue.self,from:wire.httpBody!)
                let prompt=input.object?["prompt"]?.string ?? ""
                if prompt == "Wait" { try await Task.sleep(for:.seconds(30)) }
                body=try JSONEncoder().encode(JSONValue.object(["model":input.object!["model"]!,"response":.string(prompt),"done":.bool(true),"prompt_eval_count":.number(4),"eval_count":.number(2)]))
            }
            return (body,HTTPURLResponse(url:wire.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        let app=AppStore(jobs:queue,transport:transport);app.queueReady=true;app.loadedStatusKnown=true
        app.installedModels=try await ModelLibrary(configuration:.init(),transport:transport).installed()
        return (app,ManagedModel.all(in:app).filter { $0.capability == .generation },folder)
    }
    func wait(_ session:ModelTestStore,limit:Int=200) async throws {
        for _ in 0..<limit { if !session.busy { return };try await Task.sleep(for:.milliseconds(10)) }
        XCTFail("Sample did not finish")
    }
    func testResultsStayWithTheirModelWithoutChangingAPIAccess() async throws {
        let (app,models,folder)=try await setup();defer { try? FileManager.default.removeItem(at:folder) }
        let first=app.testSession(for:models[0]),second=app.testSession(for:models[1])
        first.input="First model sample";second.input="Second model sample"
        first.run();second.run();try await wait(first);try await wait(second)
        if case .generation(let result)=first.result { XCTAssertEqual(result.model,models[0].id);XCTAssertEqual(result.text,"First model sample") } else { XCTFail(first.error) }
        if case .generation(let result)=second.result { XCTAssertEqual(result.model,models[1].id);XCTAssertEqual(result.text,"Second model sample") } else { XCTFail(second.error) }
        XCTAssertTrue(app.testSession(for:models[0]) === first);XCTAssertTrue(app.configuration.generationModels.isEmpty)
        await app.shutdown()
    }
    func testCancelStopsTheQueuedOrRunningSample() async throws {
        let (app,models,folder)=try await setup();defer { try? FileManager.default.removeItem(at:folder) }
        let session=app.testSession(for:models[0]);session.input="Wait";session.run()
        for _ in 0..<100 { if session.job != nil { break };try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertNotNil(session.job);session.cancel();try await wait(session)
        XCTAssertEqual(session.job?.state,.cancelled);XCTAssertTrue(session.error.isEmpty)
        await app.shutdown()
    }
    func testPCCIsNeverEnabledByAnOperatorTest() async throws {
        let (app,_,folder)=try await setup();defer { try? FileManager.default.removeItem(at:folder) }
        let model=ManagedModel(id:"apple-pcc",title:"PCC",location:.appleCloud,capability:.generation,installed:nil,info:nil)
        let session=app.testSession(for:model);session.run();try await wait(session)
        XCTAssertFalse(app.configuration.allowApplePCC);XCTAssertNil(session.job);XCTAssertFalse(session.error.isEmpty)
        await app.shutdown()
    }
    func testDecisionAndEmbeddingSamplesRenderTypedResults() async throws {
        let (app,_,folder)=try await setup();defer { try? FileManager.default.removeItem(at:folder) }
        let models=ManagedModel.all(in:app)
        let choice=app.testSession(for:try XCTUnwrap(models.first { $0.id == "fixture:choice" }))
        let embedding=app.testSession(for:try XCTUnwrap(models.first { $0.id == "fixture:embed" }))
        choice.run();embedding.run();try await wait(choice);try await wait(embedding)
        if case .decision(let response,let labels)=choice.result {
            XCTAssertEqual(response.model,"fixture:choice");XCTAssertEqual(labels[response.answers["result"]!.choice],"Technical support")
        } else { XCTFail(choice.error) }
        if case .embedding(let response)=embedding.result {
            XCTAssertEqual(response.model,"fixture:embed");XCTAssertEqual(response.embeddings.count,2)
            XCTAssertGreaterThan(response.cosineSimilarity(between:0,and:1) ?? 0,0.9)
        } else { XCTFail(embedding.error) }
        XCTAssertTrue(app.configuration.embeddingModels.isEmpty);XCTAssertFalse(app.configuration.decisionModels.contains("fixture:choice"))
        await app.shutdown()
    }

    func testLiveAudioSamplesThroughModelControllers() async throws {
        guard ProcessInfo.processInfo.environment["POSITRONIC_LIVE_MODEL_TESTS"] == "1" else { throw XCTSkip("Explicit bounded physical-Mac controller check") }
        let snapshot=try ResourceMonitor.snapshot()
        if let reason=ResourceMonitor.restriction(snapshot,budget:AudioCatalog.budget("chatterbox-multilingual-v3"),diskBytes:64 << 20).reason { throw XCTSkip(reason) }
        let runtime=AudioRuntime(),queue=JobQueue(waitLimit:20),app=AppStore(jobs:queue,audio:runtime)
        try await queue.start()
        await queue.configure(prepare:{ model in
            if !(await runtime.loaded()).contains(where: { $0.id == model }) { await runtime.stop() }
        },cancelWorker:{ await runtime.stop() },footprint:{ try await runtime.memory() })
        app.queueReady=true;app.installedModels=AudioCatalog.installed()
        let models=ManagedModel.all(in:app)
        let speech=app.testSession(for:try XCTUnwrap(models.first { $0.capability == .speech }))
        let transcript=app.testSession(for:try XCTUnwrap(models.first { $0.capability == .transcription }))
        do {
            for language in ["en","nl"] {
                speech.language=language;speech.input=language == "en" ? "The little robot is ready to help." : "De kleine robot staat klaar om te helpen."
                speech.run();try await wait(speech,limit:12000)
                guard case .speech(let id)=speech.result else { XCTFail(speech.error);break }
                let output=try await queue.result(id);let file=try XCTUnwrap(output.file)
                transcript.language=language;transcript.run(file:file,imported:true);try await wait(transcript,limit:12000)
                if case .transcription(let result)=transcript.result {
                    print("SYNTHETIC_MODEL_SAMPLE \(language): \(result.text)")
                    XCTAssertFalse(result.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty);XCTAssertFalse(result.segments.isEmpty)
                    XCTAssertEqual(result.language,language);XCTAssertEqual(result.model,"whisper-large-v3-turbo")
                } else { XCTFail(transcript.error) }
                XCTAssertTrue(FileManager.default.fileExists(atPath:file.path),"Import must preserve the caller’s audio")
                XCTAssertTrue(app.configuration.audioModels.isEmpty,"Local tests must not expose audio through the API")
            }
        } catch { await app.shutdown();throw error }
        await app.shutdown()
    }

}
