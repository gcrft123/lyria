import Foundation

/// Tests for the mock music library that backs Search/Library: catalog shape, search
/// filtering across title/artist/album, Top-Results ranking, and section grouping.
func runMusicLibraryTests() {
    let lib = MockMusicLibrary()

    // Catalog shape.
    let albums = awaitValue { await lib.albums() }
    let playlists = awaitValue { await lib.playlists() }
    expectEqual(albums.count, 6, "album count")
    expectEqual(playlists.count, 5, "playlist count")
    expect(albums.allSatisfy { !$0.songs.isEmpty }, "every album has songs")

    // Title match → Top Result, by prefix.
    let dreams = awaitValue { await lib.search("dreams") }
    expect(dreams.songs.contains { $0.title == "Dreams" }, "‘dreams’ finds the song")
    expectEqual(dreams.topResults.first?.title, "Dreams", "exact title is the top result")
    expect(dreams.topResults.count <= 3, "at most 3 top results")

    // Artist match → albums by that artist + their songs.
    let daft = awaitValue { await lib.search("daft") }
    expectEqual(daft.albums.count, 2, "two Daft Punk albums match")
    expect(daft.albums.allSatisfy { $0.subtitle == "Daft Punk" }, "matched albums are Daft Punk's")
    expect(!daft.songs.isEmpty, "Daft Punk songs match the artist")

    // Prefix matches rank ahead of substring matches in Top Results.
    let d = awaitValue { await lib.search("d") }
    expect(d.topResults.first?.title.lowercased().hasPrefix("d") == true,
           "a title-prefix match leads the Top Results")

    // No match → empty.
    let none = awaitValue { await lib.search("zzqq-nothing") }
    expect(none.isEmpty, "no matches → empty results")

    // Empty query → empty.
    expect(awaitValue { await lib.search("") }.isEmpty, "empty query → empty results")
}

/// Run an async operation to completion from the synchronous test harness. The work
/// (mock library calls) is non-main-isolated, so blocking the main thread on the
/// semaphore can't deadlock.
private func awaitValue<T>(_ operation: @escaping () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: T!
    Task.detached {
        result = await operation()
        semaphore.signal()
    }
    semaphore.wait()
    return result
}
