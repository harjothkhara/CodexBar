import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageContainsAsciiTests {
    private func bytes(_ text: String) -> Data {
        Data(text.utf8)
    }

    @Test
    func `finds a needle present in the middle`() {
        #expect(self.bytes(#"{"type":"event_msg","payload":{}}"#).containsAscii(#""event_msg""#))
    }

    @Test
    func `rejects an absent needle`() {
        #expect(!self.bytes(#"{"type":"turn_context"}"#).containsAscii(#""event_msg""#))
    }

    @Test
    func `empty needle matches nothing like Data range of`() {
        #expect(!self.bytes("{}").containsAscii(""))
        #expect(!Data().containsAscii(""))
        #expect(self.bytes("{}").range(of: Data()) == nil)
    }

    @Test
    func `needle longer than the haystack is absent`() {
        #expect(!self.bytes("{}").containsAscii(#""usage""#))
        #expect(!Data().containsAscii("a"))
    }

    @Test
    func `finds matches at the start and at the end`() {
        let haystack = self.bytes(#""usage":1,"token_count""#)
        #expect(haystack.containsAscii(#""usage""#))
        #expect(haystack.containsAscii(#""token_count""#))
        #expect(haystack.containsAscii(#""usage":1,"token_count""#))
    }

    @Test
    func `skips partial first byte matches`() {
        let haystack = self.bytes("aab abac abab abc")
        #expect(haystack.containsAscii("abc"))
        #expect(!self.bytes("aab abac abab ab").containsAscii("abc"))
    }

    @Test
    func `searches a sliced haystack by its own bounds`() {
        let full = self.bytes("xxabcxx")
        let slice = full[full.index(full.startIndex, offsetBy: 2)..<full.index(full.startIndex, offsetBy: 5)]
        #expect(slice.containsAscii("abc"))
        #expect(!slice.containsAscii("xa"))
    }
}
