import Testing
import Foundation
@testable import HypergraphiaCore

@Suite("Local image cache")
struct LocalImageCacheTests {

    @Test func hitRequiresMatchingModificationDate() {
        let cache = LocalImageCache(maxBytes: 1_000)
        let mtime = Date(timeIntervalSince1970: 100)
        let data = Data([1, 2, 3])

        cache.store(data, forPath: "/a.png", mtime: mtime)
        #expect(cache.data(forPath: "/a.png", mtime: mtime) == data)
        // File rewritten (new mtime) → stale entry must miss.
        #expect(cache.data(forPath: "/a.png", mtime: Date(timeIntervalSince1970: 200)) == nil)
        #expect(cache.data(forPath: "/b.png", mtime: mtime) == nil)
    }

    @Test func evictsLeastRecentlyUsedWhenOverBudget() {
        let cache = LocalImageCache(maxBytes: 100)
        let mtime = Date(timeIntervalSince1970: 1)
        cache.store(Data(repeating: 1, count: 20), forPath: "/one.png", mtime: mtime)
        cache.store(Data(repeating: 2, count: 20), forPath: "/two.png", mtime: mtime)

        // Touch /one so /two becomes the LRU victim.
        _ = cache.data(forPath: "/one.png", mtime: mtime)
        // 80 more bytes forces eviction down to budget.
        cache.store(Data(repeating: 3, count: 25), forPath: "/three.png", mtime: mtime)
        cache.store(Data(repeating: 4, count: 25), forPath: "/four.png", mtime: mtime)
        cache.store(Data(repeating: 5, count: 25), forPath: "/five.png", mtime: mtime)

        #expect(cache.currentBytes <= 100)
        #expect(cache.data(forPath: "/two.png", mtime: mtime) == nil)
    }

    @Test func oversizedEntriesAreNotCached() {
        let cache = LocalImageCache(maxBytes: 100)
        let mtime = Date(timeIntervalSince1970: 1)
        // Above maxBytes/4 → rejected so one image can't monopolize.
        cache.store(Data(repeating: 9, count: 50), forPath: "/big.png", mtime: mtime)
        #expect(cache.data(forPath: "/big.png", mtime: mtime) == nil)
        #expect(cache.currentBytes == 0)
    }

    @Test func replacingAnEntryAccountsBytesCorrectly() {
        let cache = LocalImageCache(maxBytes: 1_000)
        let m1 = Date(timeIntervalSince1970: 1)
        let m2 = Date(timeIntervalSince1970: 2)
        cache.store(Data(repeating: 1, count: 100), forPath: "/a.png", mtime: m1)
        cache.store(Data(repeating: 2, count: 40), forPath: "/a.png", mtime: m2)
        #expect(cache.currentBytes == 40)
        #expect(cache.data(forPath: "/a.png", mtime: m2)?.count == 40)
    }
}
