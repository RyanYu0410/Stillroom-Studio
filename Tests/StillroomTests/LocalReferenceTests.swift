import XCTest
import AppKit
@testable import Stillroom

final class ReferenceProtocol:URLProtocol {
    static var loaded = false
    static var fail = false
    static var movieBusy = false
    static var png = Data()
    static var paths:[String] = []
    static var body:[String:Any] = [:]
    static var escapedSlashes = false
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        let path = request.url!.path;Self.paths.append(path)
        var status = 200,json:[String:Any] = [:]
        switch path {
        case "/queue":json = ["queue_running":Self.movieBusy ? [[0,"other-job"]] : [],"queue_pending":[]]
        case "/v1/models":json = ["data":[["id":"local/flux-9b","loaded":Self.loaded,"bytes_on_disk":1000,"capabilities":["image"]]]]
        case "/v1/load-model", "/v1/unload-model":json = ["ok":true]
        case "/v1/images/generations":
            var data = request.httpBody ?? Data()
            if data.isEmpty,let stream = request.httpBodyStream {
                stream.open();defer {stream.close()};var buffer = [UInt8](repeating:0,count:8192)
                while stream.hasBytesAvailable {let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 {break};data.append(contentsOf:buffer.prefix(n))}
            }
            Self.escapedSlashes = data.range(of:Data([92,47])) != nil
            Self.body = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
            if Self.fail {status = 500;json = ["error":["message":"Fixture image failure"]]}
            else {json = ["data":[["b64_json":Self.png.base64EncodedString()]]]}
        default:status = 404
        }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:json))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LocalReferenceTests:XCTestCase {
    @MainActor private func fixture(loaded:Bool = false,fail:Bool = false,movieBusy:Bool = false) async throws -> (LocalReference,LocalGeneration,StudioStore,FilmProject) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let context = CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:0,space:VideoColor.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red:0.3,green:0.5,blue:0.4,alpha:1));context.fill(CGRect(x:0,y:0,width:64,height:64))
        let data = try VideoColor.referencePNG(context.makeImage()!)
        let file = root.appendingPathComponent("Source.png");try data.write(to:file)
        ReferenceProtocol.loaded = loaded;ReferenceProtocol.fail = fail;ReferenceProtocol.movieBusy = movieBusy;ReferenceProtocol.png = data;ReferenceProtocol.paths = [];ReferenceProtocol.body = [:]
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [ReferenceProtocol.self]
        let session = URLSession(configuration:config)
        let lab = LocalGeneration(session:session,outputDirectory:root.appendingPathComponent("Video"));lab.address = "http://127.0.0.1:8188"
        let service = LocalReference(session:session,outputDirectory:root.appendingPathComponent("References"))
        let store = StudioStore(sessionDirectory:root.appendingPathComponent("Session"),recoverSession:false)
        let media = MediaAsset(name:"Original",path:file.path,kind:.image,width:64,height:64)
        store.project.assets = [media];store.project.shots = [Shot(assetID:media.id,name:"Shot",sourceDuration:5)]
        let before = store.project
        service.generate(source:media,shot:store.project.shots[0],direction:ShotDirection(referenceDirection:"Make the lighting softer."),store:store,lab:lab)
        let deadline = Date().addingTimeInterval(8)
        while service.busy && Date() < deadline {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertFalse(service.busy);XCTAssertFalse(lab.referenceBusy)
        return (service,lab,store,before)
    }
    @MainActor func testLocalEditUsesActualSourceAndRequiresExplicitReferenceSelection() async throws {
        let (service,_,store,before) = try await fixture()
        let id = try XCTUnwrap(service.candidateID,service.message)
        let image = try XCTUnwrap(store.project.assets.first {$0.id == id})
        XCTAssertEqual(store.project.shots,before.shots)
        XCTAssertNil(store.project.assets[0].referenceAssetID)
        XCTAssertEqual(image.referenceRecipe?.model,"local/flux-9b")
        XCTAssertEqual(image.referenceRecipe?.steps,12)
        XCTAssertTrue(ReferenceProtocol.paths.contains("/v1/load-model"));XCTAssertTrue(ReferenceProtocol.paths.contains("/v1/unload-model"))
        XCTAssertFalse(ReferenceProtocol.escapedSlashes,"The native image engine needs literal base64 slashes.")
        XCTAssertEqual(ReferenceProtocol.body["mode"] as? String,"edit")
        let sent = try XCTUnwrap(ReferenceProtocol.body["image"] as? String)
        XCTAssertEqual(Data(base64Encoded:sent),try Data(contentsOf:store.url(before.assets[0])))
        XCTAssertTrue(FileManager.default.fileExists(atPath:image.path))
    }
    @MainActor func testAlreadyResidentUserModelIsNotUnloaded() async throws {
        let (service,_,_,_) = try await fixture(loaded:true)
        XCTAssertNotNil(service.candidateID)
        XCTAssertFalse(ReferenceProtocol.paths.contains("/v1/load-model"))
        XCTAssertFalse(ReferenceProtocol.paths.contains("/v1/unload-model"))
    }
    @MainActor func testFailureReleasesOnlyOwnedModelAndLeavesProjectUnchanged() async throws {
        let (service,_,store,before) = try await fixture(fail:true)
        XCTAssertNil(service.candidateID);XCTAssertEqual(store.project,before)
        XCTAssertTrue(service.message.contains("Fixture image failure"))
        XCTAssertTrue(ReferenceProtocol.paths.contains("/v1/unload-model"))
    }
    @MainActor func testRunningVideoPreventsStartingImageJob() async throws {
        let (service,_,store,before) = try await fixture(movieBusy:true)
        XCTAssertNil(service.candidateID);XCTAssertEqual(store.project,before)
        XCTAssertFalse(ReferenceProtocol.paths.contains("/v1/images/generations"))
        XCTAssertFalse(ReferenceProtocol.paths.contains("/v1/load-model"))
    }
}
