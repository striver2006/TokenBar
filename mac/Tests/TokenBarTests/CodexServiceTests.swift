import XCTest
@testable import TokenBar

final class CodexServiceTests: XCTestCase {
    func testCodexEnvironmentPreservesInheritedValuesAndAddsStandardPaths() {
        let env = CodexService.codexEnvironment(["PATH": "/custom/bin:/usr/local/bin:/usr/bin", "CUSTOM": "value"], home: "/Users/example")
        XCTAssertEqual(env["PATH"], "/custom/bin:/usr/local/bin:/usr/bin:/opt/homebrew/bin:/Users/example/.local/bin")
        XCTAssertEqual(env["CUSTOM"], "value")
        let fallback = CodexService.codexEnvironment([:], home: "/Users/example")
        XCTAssertEqual(fallback["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:/Users/example/.local/bin")
    }

    private func parse(_ json: String) throws -> (TokenWindow?, TokenWindow?) {
        try CodexService.parseRateLimits(JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])
    }

    func testSubscriptionWindowsUseServerPercentAndReset() throws {
        let (primary, secondary) = try parse("""
        {"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800000000},"secondary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1800100000}}}
        """)
        XCTAssertEqual(primary?.remainingPercentage, 75)
        XCTAssertEqual(primary?.titleKind, .fiveHour)
        XCTAssertEqual(primary?.endTime.timeIntervalSince1970, 1800000000)
        XCTAssertEqual(primary?.endTime.timeIntervalSince(primary!.startTime), 18000)
        XCTAssertEqual(secondary?.remainingPercentage, 0)
        XCTAssertEqual(secondary?.titleKind, .weekly)
    }

    func testCodexBucketTakesPrecedenceAndNullWindowIsAbsent() throws {
        let (primary, secondary) = try parse("""
        {"rateLimits":{"primary":{"usedPercent":80,"windowDurationMins":300,"resetsAt":1800000000}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":12,"windowDurationMins":60,"resetsAt":1800000000},"secondary":null}}}
        """)
        XCTAssertEqual(primary?.remainingPercentage, 88)
        XCTAssertEqual(primary?.titleKind, .custom("Codex (60 min)"))
        XCTAssertNil(secondary)
    }

    func testMissingOrMalformedLimitsDoNotBecomeFullQuota() {
        for json in ["{}", "{\"rateLimits\":{}}", "{\"rateLimits\":{\"primary\":null,\"secondary\":null}}",
                     "{\"rateLimits\":{\"primary\":{\"usedPercent\":true,\"windowDurationMins\":300,\"resetsAt\":1800000000}}}",
                     "{\"rateLimits\":{\"primary\":{\"usedPercent\":25,\"windowDurationMins\":0,\"resetsAt\":1800000000}}}"] {
            XCTAssertThrowsError(try parse(json))
        }
    }

    func testLegacySettingsKeepAPIAndSubscriptionSettingsRoundTrip() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{\"openAIApiKey\":\"test-key\"}".utf8))
        XCTAssertFalse(old.openAIUseCodexSubscription)
        XCTAssertEqual(old.openAIApiKey, "test-key")
        XCTAssertEqual(old.codexExecutablePath, "")
        var settings = old
        settings.openAIUseCodexSubscription = true
        settings.codexExecutablePath = "/Applications/Codex.app/Contents/Resources/codex"
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(restored.openAIUseCodexSubscription)
        XCTAssertEqual(restored.codexExecutablePath, settings.codexExecutablePath)
        XCTAssertEqual(restored.openAIApiKey, "test-key")
    }

    private func withFakeCodex(_ body: String, test: (String) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("codex")
        try ("#!/usr/bin/python3\nimport sys,json,time\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try test(script.path)
    }

    func testRPCHandshakeIgnoresNotificationsAndReadsSubscription() throws {
        try withFakeCodex("""
        import os
        assert '/opt/homebrew/bin' in os.environ['PATH'].split(':')
        def read(): return json.loads(sys.stdin.readline())
        def send(o): print(json.dumps(o),flush=True)
        assert read()['method']=='initialize'
        send({'id':1,'result':{}})
        assert read()['method']=='initialized'
        assert read()['method']=='account/read'
        send({'method':'account/updated','params':{}})
        send({'id':2,'result':{'account':{'type':'chatgpt','planType':'plus'}}})
        assert read()['method']=='account/rateLimits/read'
        send({'id':3,'result':{'rateLimits':{'primary':{'usedPercent':35,'windowDurationMins':300,'resetsAt':1800000000}}}})
        time.sleep(3)
        """) { path in
            let result = try CodexService.query(executablePath: path, isZh: true)
            XCTAssertEqual(result.0?.remainingPercentage, 65)
            XCTAssertEqual(result.2, "Codex · plus")
        }
    }

    func testAPIKeyLoginIsRejectedBeforeRateLimitQuery() throws {
        try withFakeCodex("""
        json.loads(sys.stdin.readline())
        print('{"id":1,"result":{}}',flush=True)
        sys.stdin.readline()
        sys.stdin.readline()
        print('{"id":2,"result":{"account":{"type":"apiKey"}}}',flush=True)
        time.sleep(3)
        """) { path in
            XCTAssertThrowsError(try CodexService.query(executablePath: path, isZh: true)) { error in
                XCTAssertTrue(error.localizedDescription.contains("codex login"))
            }
        }
    }

    func testHungProcessHasBoundedTimeout() throws {
        try withFakeCodex("time.sleep(30)\n") { path in
            let start = Date()
            XCTAssertThrowsError(try CodexService.query(executablePath: path, isZh: true, timeoutSeconds: 0.2))
            XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        }
    }
}
