import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct BAIPluginTests {
    static let personal = #"""
    {"success":true,"message":"","data":{"api_key_type":"personal","personal_balance":1250000,
    "active_status":"active"}}
    """#
    static let team = #"""
    {"success":true,"data":{"api_key_type":"team","team":{"team_role":"admin",
    "quota_limit_type":"limited","team_balance":8000000,"member_quota_limit":3000000,
    "member_quota_used":450000,"member_reset_interval":2592000,"quota_reset_at":"2026-09-30T16:00:00Z"}}}
    """#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `personal Credits have no fabricated percentage`(engine: ProviderPluginEngineKind) async throws {
        let usage = try await Self.fetch(Self.personal, engine: engine)
        #expect(usage.primary == nil)
        #expect(usage.providerCost == nil)
        #expect(usage.details.first?.rows.map(\.value) == ["1,250,000 Credits"])
        #expect(usage.identity?.loginMethod == "Personal API key")
        #expect(usage.dataConfidence == .exact)
        for (balance, expected) in [
            (0, "0 Credits"), (-12, "-12 Credits"), (9_007_199_254_740_991, "9,007,199,254,740,991 Credits"),
        ] {
            let body = Self.personal.replacingOccurrences(of: "1250000", with: String(balance))
                .replacingOccurrences(of: #""active_status":"active""#, with: #""active_status":{}"#)
            let snapshot = try await Self.fetch(body, engine: engine)
            #expect(snapshot.primary == nil)
            #expect(snapshot.details.first?.rows.map(\.value) == [expected])
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `team quota and admin balance remain separate`(engine: ProviderPluginEngineKind) async throws {
        let usage = try await Self.fetch(Self.team, engine: engine)
        #expect(usage.primary?.usedPercent == 15)
        #expect(usage.primary?.resetsAt == ISO8601DateFormatter().date(from: "2026-09-30T16:00:00Z"))
        #expect(usage.primary?.windowMinutes == nil)
        #expect(usage.secondary == nil)
        #expect(usage.providerCost == nil)
        #expect(usage.details.first?.rows.map(\.value) == [
            "450,000 Credits", "3,000,000 Credits", "2,550,000 Credits", "2026-09-30T16:00:00.000Z",
            "8,000,000 Credits",
        ])
        #expect(usage.identity?.loginMethod == "Team API key")
        #expect(usage.dataConfidence == .exact)
        let member = Self.team.replacingOccurrences(of: #""team_balance":8000000,"#, with: "")
            .replacingOccurrences(of: #""admin""#, with: #""member""#)
        let memberUsage = try await Self.fetch(member, engine: engine)
        #expect(memberUsage.primary == usage.primary)
        #expect(memberUsage.details.first?.rows.count == 4)
        #expect(memberUsage.details.first?.rows.contains { $0.label == "Team balance" } == false)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unlimited quotas never invent a percentage or remaining balance`(
        engine: ProviderPluginEngineKind) async throws
    {
        for extra in ["", #", "member_quota_limit":0"#] {
            let usage = try await Self.fetch(
                #"""
                {"success":true,"data":{"api_key_type":"team","team":{
                "quota_limit_type":"unlimited","member_quota_used":450000\#(extra)}}}
                """#,
                engine: engine)
            #expect(usage.primary == nil)
            #expect(usage.providerCost == nil)
            #expect(usage.details.first?.rows.map(\.value) == ["450,000 Credits", "Unlimited"])
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero limited quotas and overspending remain exhausted`(engine: ProviderPluginEngineKind) async throws {
        for (limit, used) in [(0, 0), (0, 12), (100, 120), (100, 100)] {
            let usage = try await Self.fetch(
                #"""
                {"success":true,"data":{"api_key_type":"team","team":{"quota_limit_type":"limited",
                "member_quota_limit":\#(limit),"member_quota_used":\#(used)}}}
                """#,
                engine: engine)
            #expect(usage.primary?.usedPercent == 100)
            #expect(usage.primary?.resetsAt == nil)
            #expect(usage.details.first?.rows[2].value == "0 Credits")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `invalid optional reset times do not hide valid quota`(engine: ProviderPluginEngineKind) async throws {
        for reset in [#""private-response""#, "null", "123", "{}"] {
            let usage = try await Self.fetch(
                Self.team.replacingOccurrences(of: #""2026-09-30T16:00:00Z""#, with: reset),
                engine: engine)
            #expect(usage.primary?.usedPercent == 15)
            #expect(usage.primary?.resetsAt == nil)
            #expect(usage.details.first?.rows.contains { $0.label == "Quota reset" } == false)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed responses fail instead of fabricating balance`(engine: ProviderPluginEngineKind) async {
        for value in ["null", "true", "0.5", "9007199254740992", #""private-response""#, "{}", "[]"] {
            await Self.expectFailure(
                Self.personal.replacingOccurrences(of: "1250000", with: value), engine: engine, kind: .parseFailure)
            for (field, original) in [
                ("member_quota_limit", "3000000"), ("member_quota_used", "450000"), ("team_balance", "8000000"),
            ] {
                await Self.expectFailure(
                    Self.team.replacingOccurrences(of: "\"\(field)\":\(original)", with: "\"\(field)\":\(value)"),
                    engine: engine,
                    kind: .parseFailure)
            }
        }
        for body in [
            "private-response", "null", "[]", "{}", #"{"success":true,"data":[]}"#,
            Self.personal.replacingOccurrences(of: #""success":true,"#, with: ""),
            Self.personal.replacingOccurrences(of: #""personal_balance":1250000,"#, with: ""),
            Self.personal.replacingOccurrences(of: #""personal""#, with: #""unknown""#),
            Self.team.replacingOccurrences(of: #""member_quota_limit":3000000,"#, with: ""),
            Self.team.replacingOccurrences(of: #""member_quota_used":450000,"#, with: ""),
            Self.team.replacingOccurrences(of: #""member_quota_used":450000"#, with: #""member_quota_used":-1"#),
            Self.team.replacingOccurrences(of: #""member_quota_limit":3000000"#, with: #""member_quota_limit":-1"#),
            Self.team.replacingOccurrences(of: #""limited""#, with: #""unknown""#),
        ] {
            await Self.expectFailure(body, engine: engine, kind: .parseFailure)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `failures are classified without echoing private data`(engine: ProviderPluginEngineKind) async {
        for (code, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (403, .permissionDenied),
            (429, .rateLimited), (500, .providerUnavailable), (400, .apiFailure),
        ] {
            await Self.expectFailure("private-response", engine: engine, code: code, kind: kind)
        }
        await Self.expectFailure(
            #"{"success":false,"message":"private-response"}"#, engine: engine, kind: .apiFailure)
    }

    @Test
    func `registration uses only the BAI key and defaults off`() throws {
        let provider = try #require(UsageProvider(rawValue: "bai"))
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(!descriptor.metadata.widgetSelectable)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        let credentials = try #require(descriptor.credentials)
        #expect(credentials.resolveToken(environment: ["BAI_API_KEY": "fixture-key"])?.token == "fixture-key")
        #expect(credentials.resolveToken(environment: ["BAI_API_KEY": "  "]) == nil)
        #expect(credentials.resolveToken(environment: ["OTHER_API_KEY": "fixture-key"]) == nil)
        let environment = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: ["BAI_API_KEY": "environment-key"],
            provider: provider,
            config: ProviderConfig(id: provider.instanceID, apiKey: "config-key"))
        #expect(environment["BAI_API_KEY"] == "config-key")
    }

    private static func expectFailure(
        _ body: String,
        engine: ProviderPluginEngineKind,
        code: Int = 200,
        kind: ProviderFetchClassifiedError.Kind) async
    {
        do {
            _ = try await self.fetch(body, engine: engine, code: code)
            Issue.record("Expected classified failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            #expect(!error.message.contains("private-response"))
            if code == 429 { #expect(error.retryAfterSeconds == 10) }
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }
    }

    private static func fetch(
        _ body: String, engine: ProviderPluginEngineKind, code: Int = 200) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "bai",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.absoluteString == "https://api.b.ai/v1/balance")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: code,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "Retry-After": "30"]))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(secrets: ["BAI_API_KEY": "fixture-key"])
    }
}
