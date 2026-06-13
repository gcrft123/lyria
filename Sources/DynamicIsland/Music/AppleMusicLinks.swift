import AppKit

/// Resolves and opens Apple Music pages for the current song / artist.
///
/// Uses the public iTunes Search API to get a canonical `music.apple.com` URL,
/// then opens it (which hands off to the Music app). Falls back to an Apple
/// Music search URL if the lookup fails.
enum AppleMusicLinks {

    static func openSong(title: String, artist: String) {
        let term = "\(title) \(artist)"
        resolve(term: term, entity: "song", urlKeys: ["trackViewUrl", "collectionViewUrl"])
    }

    static func openArtist(_ artist: String) {
        resolve(term: artist, entity: "musicArtist", urlKeys: ["artistLinkUrl", "artistViewUrl"])
    }

    private static func resolve(term: String, entity: String, urlKeys: [String]) {
        let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let fallback = URL(string: "https://music.apple.com/search?term=\(encoded)")!

        guard let api = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=\(entity)&limit=1") else {
            NSWorkspace.shared.open(fallback)
            return
        }

        URLSession.shared.dataTask(with: api) { data, _, _ in
            var target: URL?
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["results"] as? [[String: Any]],
               let first = results.first {
                for key in urlKeys {
                    if let value = first[key] as? String, let url = URL(string: value) {
                        target = url
                        break
                    }
                }
            }
            DispatchQueue.main.async {
                NSWorkspace.shared.open(target ?? fallback)
            }
        }.resume()
    }
}
