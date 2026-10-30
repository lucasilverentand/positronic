import XCTest
@testable import ModelAPI
@testable import ModelService
final class ModelTestingTests:XCTestCase {
    func testTemporaryOperatorConfigurationDoesNotEnableAPIOrCloud() throws {
        let original=ServiceConfiguration()
        for (capability,id) in [(ModelCapability.generation,"fixture:small"),(.decision,"fixture:choice"),(.embedding,"fixture:embed"),(.speech,"chatterbox-multilingual-v3"),(.transcription,"whisper-large-v3-turbo")] {
            let temporary=try original.forModelTest(id,capability:capability)
            XCTAssertFalse(temporary.allowApplePCC)
        }
        XCTAssertTrue(original.generationModels.isEmpty);XCTAssertTrue(original.embeddingModels.isEmpty);XCTAssertTrue(original.audioModels.isEmpty)
        XCTAssertFalse(try original.forModelTest("apple-pcc",capability:.generation).allowApplePCC)
        XCTAssertThrowsError(try original.forModelTest("fixture:cloud",capability:.generation))
        var assigned=original;assigned.generationModels=["fixture:choice"]
        let choice=try assigned.forModelTest("fixture:choice",capability:.decision)
        XCTAssertFalse(choice.generationModels.contains("fixture:choice"));XCTAssertTrue(choice.decisionModels.contains("fixture:choice"))
        XCTAssertEqual(assigned.generationModels,["fixture:choice"])
    }
    func testDecisionSampleUsesSelectedModelAndStableChoiceIdentity() throws {
        let request=try ModelTestInput.decision(model:"fixture:choice",text:"A login problem",question:"Which team?",choices:" Support\n\nBilling ")
        XCTAssertEqual(request.model,"fixture:choice");XCTAssertEqual(request.questions["result"]?.criteria,["option_1":"Support","option_2":"Billing"])
        XCTAssertThrowsError(try ModelTestInput.decision(model:"fixture",text:"Sample",question:"Which?",choices:"Same\nSame"))
        XCTAssertThrowsError(try ModelTestInput.decision(model:"fixture",text:"Sample",question:"Which?",choices:"Only one"))
    }
    func testEmbeddingPreviewUsesCosineRatherThanUnboundedCoordinates() {
        let value=EmbeddingResponse(model:"fixture",embeddings:[[1e308,1e308],[1,1],[-1,-1],[0,0]],usage:.init(input:4,output:nil))
        XCTAssertEqual(value.cosineSimilarity(between:0,and:1)!,1,accuracy:0.00001)
        XCTAssertEqual(value.cosineSimilarity(between:0,and:2)!,-1,accuracy:0.00001)
        XCTAssertNil(value.cosineSimilarity(between:0,and:3));XCTAssertNil(value.cosineSimilarity(between:0,and:7))
    }
}
