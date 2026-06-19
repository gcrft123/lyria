import AppKit
import ScriptingBridge

/// The real Apple Music backend (used unless `DI_MOCK_MUSIC=1`).
///
/// - **Library** = the user's playlists + albums via ScriptingBridge, read with KVC
///   the same way `MusicBridge` reads the now-playing queue (SB element protocol
///   casts are unreliable). Albums are derived from the library playlist using the
///   bulk-KVC fast path (one Apple Event per column), grouped by album name.
/// - **Search** = Apple's public iTunes catalog API (fast, rich metadata, real
///   artwork) rather than the fragile library-wide ScriptingBridge `search` command.
/// - **Play / favorite** drive the Music app via small AppleScripts (the user's own
///   library content plays in-app; catalog-only search hits open in Apple Music).
///
/// NOT verified on a live library by the author — every read goes through the same
/// off-main serial queue + KVC discipline as `MusicBridge`, so failures degrade to
/// empty rather than crashing. Bulk album derivation can be slow on very large
/// libraries (it's done once, off-main, and cached).
final class AppleMusicLibrary: MusicLibrary, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.gcrft123.lyria.music.library")
    private var cachedApp: SBApplication?
    private var cachedPlaylists: [MusicCollection]?
    private var cachedAlbums: [MusicCollection]?

    /// System/special playlists that leak into `userPlaylists` and aren't real
    /// user playlists (the reported stray "Music" entry, etc.).
    private let excludedPlaylists: Set<String> = ["Music", "Library", "Downloaded", "Recently Added", "Purchased"]

    private var app: SBApplication? {
        if let cachedApp { return cachedApp }
        cachedApp = SBApplication(bundleIdentifier: "com.apple.Music")
        return cachedApp
    }

    // MARK: Library (ScriptingBridge, KVC)

    func playlists() async -> [MusicCollection] {
        await withCheckedContinuation { cont in queue.async { cont.resume(returning: self.loadPlaylists()) } }
    }

    func albums() async -> [MusicCollection] {
        await withCheckedContinuation { cont in queue.async { cont.resume(returning: self.loadAlbums()) } }
    }

    /// MUST run on `queue`. The user's playlists (name, id, cover) via KVC. Covers
    /// fall back to the first track's artwork (playlists often have none of their own).
    private func loadPlaylists() -> [MusicCollection] {
        if let cachedPlaylists { return cachedPlaylists }
        guard let app, app.isRunning, let lists = app.userPlaylists() else { return [] }
        var result: [MusicCollection] = []
        for i in 0..<min(lists.count, 60) {
            let obj = lists.object(at: i) as AnyObject
            let name = obj.value(forKey: "name") as? String ?? ""
            guard !name.isEmpty, !excludedPlaylists.contains(name) else { continue }
            let pid = obj.value(forKey: "persistentID") as? String ?? "\(i)"
            var art = Self.firstArtwork(of: obj)
            if art == nil, let tracks = obj.value(forKey: "tracks") as? SBElementArray {
                art = Self.artwork(in: tracks, at: 0)
            }
            result.append(MusicCollection(id: "pl:\(pid)", kind: .playlist, title: name,
                                          subtitle: "Playlist", artwork: art, date: nil, songs: []))
        }
        cachedPlaylists = result
        return result
    }

    /// MUST run on `queue`. Derive albums from the whole library: bulk-read each
    /// column in one Apple Event, group by album name, cover from each album's first
    /// track. Capped at 60 albums (with covers) to bound a large library.
    private func loadAlbums() -> [MusicCollection] {
        if let cachedAlbums { return cachedAlbums }
        guard let tracks = libraryTracks(), tracks.count > 0 else { cachedAlbums = []; return [] }
        let names = Self.stringColumn(tracks, "name")
        let albumCol = Self.stringColumn(tracks, "album")
        let artistCol = Self.stringColumn(tracks, "artist")
        let albumArtistCol = Self.stringColumn(tracks, "albumArtist")
        let pidCol = Self.stringColumn(tracks, "persistentID")
        let durCol = Self.doubleColumn(tracks, "duration")
        let favCol = Self.boolColumn(tracks, "favorited")

        var order: [String] = []
        var grouped: [String: [MusicSong]] = [:]
        var firstIndex: [String: Int] = [:]
        var subtitle: [String: String] = [:]
        for i in 0..<albumCol.count {
            let album = albumCol[i]
            guard !album.isEmpty else { continue }
            if grouped[album] == nil {
                order.append(album); firstIndex[album] = i
                let aa = i < albumArtistCol.count ? albumArtistCol[i] : ""
                subtitle[album] = aa.isEmpty ? (i < artistCol.count ? artistCol[i] : "") : aa
            }
            grouped[album, default: []].append(MusicSong(
                id: i < pidCol.count ? pidCol[i] : "\(i)",
                title: i < names.count ? names[i] : "",
                artist: i < artistCol.count ? artistCol[i] : "",
                album: album, albumID: "lal:\(album)", artwork: nil,
                duration: i < durCol.count ? durCol[i] : 0,
                isFavorited: i < favCol.count ? favCol[i] : false))
        }
        var result: [MusicCollection] = []
        for album in order.prefix(60) {
            // One cover per album — reuse it for every song row (they're all this album).
            let cover = Self.artwork(in: tracks, at: firstIndex[album] ?? 0)
            let songs = (grouped[album] ?? []).map { song -> MusicSong in
                var s = song; s.artwork = cover; return s
            }
            result.append(MusicCollection(id: "lal:\(album)", kind: .album, title: album,
                                          subtitle: subtitle[album] ?? "", artwork: cover, date: nil, songs: songs))
        }
        cachedAlbums = result
        return result
    }

    func songs(in collection: MusicCollection) async -> [MusicSong] {
        if collection.id.hasPrefix("pl:") {
            let pid = String(collection.id.dropFirst(3))
            return await withCheckedContinuation { cont in
                queue.async { cont.resume(returning: self.loadPlaylistTracks(persistentID: pid)) }
            }
        }
        if collection.id.hasPrefix("lal:") {
            return await withCheckedContinuation { cont in
                queue.async { cont.resume(returning: self.loadAlbums().first { $0.id == collection.id }?.songs ?? collection.songs) }
            }
        }
        if collection.id.hasPrefix("al:") {
            return await Self.lookupAlbumTracks(collectionID: String(collection.id.dropFirst(3)))
        }
        return collection.songs
    }

    /// MUST run on `queue`. A user playlist's tracks (re-resolved by id), each with
    /// its own cover. Capped at 100 — reading per-track KVC artwork is the slow part,
    /// so very long playlists are truncated to keep the detail open responsive.
    private func loadPlaylistTracks(persistentID pid: String) -> [MusicSong] {
        guard let app, app.isRunning, let lists = app.userPlaylists() else { return [] }
        for i in 0..<lists.count {
            let obj = lists.object(at: i) as AnyObject
            guard (obj.value(forKey: "persistentID") as? String) == pid,
                  let tracks = obj.value(forKey: "tracks") as? SBElementArray else { continue }
            var songs: [MusicSong] = []
            for t in 0..<min(tracks.count, 100) {
                let e = tracks.object(at: t) as AnyObject
                let title = e.value(forKey: "name") as? String ?? ""
                guard !title.isEmpty else { continue }
                let album = e.value(forKey: "album") as? String ?? ""
                songs.append(MusicSong(id: (e.value(forKey: "persistentID") as? String) ?? "\(t)",
                                       title: title,
                                       artist: e.value(forKey: "artist") as? String ?? "",
                                       album: album, albumID: album.isEmpty ? nil : "lal:\(album)",
                                       artwork: Self.firstArtwork(of: e),
                                       duration: e.value(forKey: "duration") as? Double ?? 0,
                                       isFavorited: (e.value(forKey: "favorited") as? NSNumber)?.boolValue ?? false))
            }
            return songs
        }
        return []
    }

    /// The library playlist (the source of all tracks) via `sources`.
    private func libraryTracks() -> SBElementArray? {
        guard let app, app.isRunning, let sources = app.value(forKey: "sources") as? SBElementArray else { return nil }
        for i in 0..<sources.count {
            let src = sources.object(at: i) as AnyObject
            guard let libs = src.value(forKey: "libraryPlaylists") as? SBElementArray, libs.count > 0 else { continue }
            if let tracks = (libs.object(at: 0) as AnyObject).value(forKey: "tracks") as? SBElementArray, tracks.count > 0 {
                return tracks
            }
        }
        return nil
    }

    // MARK: Search (iTunes catalog)

    func search(_ query: String) async -> SearchResults {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .empty }
        async let songsTask = Self.catalogSongs(q)
        async let albumsTask = Self.catalogAlbums(q)
        let songs = await songsTask
        let albums = await albumsTask
        let lc = q.lowercased()
        let matching = await playlists().filter { $0.title.lowercased().contains(lc) }
        return SearchResults(topResults: Array(songs.prefix(3)), albums: albums, songs: songs, playlists: matching)
    }

    private static func catalogSongs(_ q: String) async -> [MusicSong] {
        let results = await itunes(term: q, entity: "song", limit: 25)
        return await withTaskGroup(of: (Int, MusicSong).self) { group in
            for (i, r) in results.enumerated() {
                group.addTask {
                    let art = await loadImage(r["artworkUrl100"] as? String)
                    return (i, MusicSong(
                        id: "sg:\((r["trackId"] as? NSNumber)?.stringValue ?? "\(i)")",
                        title: r["trackName"] as? String ?? "",
                        artist: r["artistName"] as? String ?? "",
                        album: r["collectionName"] as? String ?? "",
                        albumID: (r["collectionId"] as? NSNumber).map { "al:\($0.stringValue)" },
                        artwork: art,
                        duration: ((r["trackTimeMillis"] as? NSNumber)?.doubleValue ?? 0) / 1000))
                }
            }
            var out: [(Int, MusicSong)] = []
            for await item in group { out.append(item) }
            return out.sorted { $0.0 < $1.0 }.map(\.1).filter { !$0.title.isEmpty }
        }
    }

    private static func catalogAlbums(_ q: String) async -> [MusicCollection] {
        let results = await itunes(term: q, entity: "album", limit: 12)
        return await withTaskGroup(of: (Int, MusicCollection).self) { group in
            for (i, r) in results.enumerated() {
                group.addTask {
                    let art = await loadImage(r["artworkUrl100"] as? String)
                    let date = (r["releaseDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                    return (i, MusicCollection(
                        id: "al:\((r["collectionId"] as? NSNumber)?.stringValue ?? "\(i)")", kind: .album,
                        title: r["collectionName"] as? String ?? "", subtitle: r["artistName"] as? String ?? "",
                        artwork: art, date: date, songs: []))
                }
            }
            var out: [(Int, MusicCollection)] = []
            for await item in group { out.append(item) }
            return out.sorted { $0.0 < $1.0 }.map(\.1).filter { !$0.title.isEmpty }
        }
    }

    private static func lookupAlbumTracks(collectionID cid: String) async -> [MusicSong] {
        var comps = URLComponents(string: "https://itunes.apple.com/lookup")
        comps?.queryItems = [URLQueryItem(name: "id", value: cid), URLQueryItem(name: "entity", value: "song")]
        guard let url = comps?.url else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let results = (json?["results"] as? [[String: Any]]) ?? []
            let art = await loadImage(results.first?["artworkUrl100"] as? String)
            return results.filter { ($0["wrapperType"] as? String) == "track" }.compactMap { r in
                let title = r["trackName"] as? String ?? ""
                guard !title.isEmpty else { return nil }
                return MusicSong(id: "sg:\((r["trackId"] as? NSNumber)?.stringValue ?? UUID().uuidString)",
                                 title: title, artist: r["artistName"] as? String ?? "",
                                 album: r["collectionName"] as? String ?? "", albumID: "al:\(cid)", artwork: art,
                                 duration: ((r["trackTimeMillis"] as? NSNumber)?.doubleValue ?? 0) / 1000)
            }
        } catch { return [] }
    }

    private static func itunes(term: String, entity: String, limit: Int) async -> [[String: Any]] {
        var comps = URLComponents(string: "https://itunes.apple.com/search")
        comps?.queryItems = [URLQueryItem(name: "term", value: term),
                             URLQueryItem(name: "entity", value: entity),
                             URLQueryItem(name: "limit", value: "\(limit)")]
        guard let url = comps?.url else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (json?["results"] as? [[String: Any]]) ?? []
        } catch { return [] }
    }

    private static func loadImage(_ urlString: String?) async -> NSImage? {
        guard let urlString else { return nil }
        let large = urlString.replacingOccurrences(of: "100x100bb", with: "200x200bb")
        guard let url = URL(string: large) else { return nil }
        do { return NSImage(data: try await URLSession.shared.data(from: url).0) } catch { return nil }
    }

    // MARK: Actions (AppleScript drives the Music app)

    func play(_ collection: MusicCollection, shuffled: Bool) {
        if collection.id.hasPrefix("pl:") {
            let pid = Self.esc(String(collection.id.dropFirst(3)))
            runScript("""
            tell application "Music"
                set shuffle enabled to \(shuffled ? "true" : "false")
                try
                    play (some playlist whose persistent ID is "\(pid)")
                end try
            end tell
            """)
        } else if collection.id.hasPrefix("lal:") {
            let album = Self.esc(String(collection.id.dropFirst(4)))
            runScript("""
            tell application "Music"
                set shuffle enabled to \(shuffled ? "true" : "false")
                try
                    set theTracks to (every track of library playlist 1 whose album is "\(album)")
                    if theTracks is not {} then play (item 1 of theTracks)
                end try
            end tell
            """)
        } else {
            openInAppleMusic(collection: collection)   // catalog-only album
        }
    }

    func playSong(_ song: MusicSong) {
        if song.id.hasPrefix("sg:") {
            // A catalog hit might still be in the user's library — play it if so,
            // otherwise open it in Apple Music (scripting can't play catalog-only items).
            playLibraryMatch(name: song.title, artist: song.artist) { [self] in openInAppleMusic(song: song) }
        } else {
            runScript("""
            tell application "Music"
                try
                    play (some track of library playlist 1 whose persistent ID is "\(Self.esc(song.id))")
                end try
            end tell
            """)
        }
    }

    /// Play the first library track matching name+artist; run `fallback` (on main)
    /// when there's no match (it's catalog-only).
    private func playLibraryMatch(name: String, artist: String, fallback: @escaping () -> Void) {
        queue.async {
            let source = """
            tell application "Music"
                set matches to (every track of library playlist 1 whose name is "\(Self.esc(name))" and artist is "\(Self.esc(artist))")
                if matches is not {} then
                    play (item 1 of matches)
                    return "1"
                end if
                return "0"
            end tell
            """
            var error: NSDictionary?
            let played = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue == "1"
            if !played { DispatchQueue.main.async(execute: fallback) }
        }
    }

    func toggleFavorite(_ song: MusicSong) {
        guard !song.id.hasPrefix("sg:") else { return }   // not in the library → can't favorite via scripting
        runScript("""
        tell application "Music"
            try
                set theTrack to (some track of library playlist 1 whose persistent ID is "\(Self.esc(song.id))")
                set favorited of theTrack to (not (favorited of theTrack))
            end try
        end tell
        """)
    }

    func addToPlaylist(_ song: MusicSong, to playlist: MusicCollection) {}   // deferred (write)
    func openInAppleMusic(song: MusicSong) { AppleMusicLinks.openSong(title: song.title, artist: song.artist) }
    func openInAppleMusic(collection: MusicCollection) {
        AppleMusicLinks.openSong(title: collection.title, artist: collection.subtitle)
    }

    private func runScript(_ source: String) {
        queue.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    // MARK: KVC helpers

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    private static func firstArtwork(of obj: AnyObject) -> NSImage? {
        guard let arts = obj.value(forKey: "artworks") as? SBElementArray, arts.count > 0 else { return nil }
        return (arts.object(at: 0) as AnyObject).value(forKey: "data") as? NSImage
    }
    private static func artwork(in arr: SBElementArray, at index: Int) -> NSImage? {
        guard index >= 0, index < arr.count else { return nil }
        return firstArtwork(of: arr.object(at: index) as AnyObject)
    }
    /// Bulk-read a property column across an SBElementArray in one Apple Event.
    private static func stringColumn(_ arr: SBElementArray, _ key: String) -> [String] {
        (arr.value(forKey: key) as? [Any])?.map { $0 as? String ?? "" } ?? []
    }
    private static func doubleColumn(_ arr: SBElementArray, _ key: String) -> [Double] {
        (arr.value(forKey: key) as? [Any])?.map { ($0 as? NSNumber)?.doubleValue ?? 0 } ?? []
    }
    private static func boolColumn(_ arr: SBElementArray, _ key: String) -> [Bool] {
        (arr.value(forKey: key) as? [Any])?.map { ($0 as? NSNumber)?.boolValue ?? false } ?? []
    }
}
