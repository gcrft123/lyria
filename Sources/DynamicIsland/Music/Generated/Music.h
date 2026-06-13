/*
 * Music.h — minimal ScriptingBridge interface for Apple Music (com.apple.Music).
 *
 * Normally generated with `sdef /System/Applications/Music.app | sdp -fh
 * --basename Music`, but `sdp` needs a full Xcode install, so this is a
 * hand-written subset. Enum codes and property/command names are taken
 * verbatim from /System/Applications/Music.app/Contents/Resources/com.apple.Music.sdef.
 *
 * Design note: these are declared as @protocols, and SBApplication / SBObject
 * are declared (via category) to conform to them. ScriptingBridge fulfils the
 * requirements dynamically at runtime. This avoids referencing concrete
 * `MusicApplication` class symbols (which don't exist), so it links cleanly
 * and needs no casting from Swift — `SBApplication(bundleIdentifier:)` already
 * exposes every member.
 */

#import <AppKit/AppKit.h>
#import <ScriptingBridge/ScriptingBridge.h>

// ePlS — player state.
typedef NS_ENUM(NSInteger, MusicEPlS) {
    MusicEPlSStopped        = 'kPSS',
    MusicEPlSPlaying        = 'kPSP',
    MusicEPlSPaused         = 'kPSp',
    MusicEPlSFastForwarding = 'kPSF',
    MusicEPlSRewinding      = 'kPSR'
};

// eRpt — repeat mode.
typedef NS_ENUM(NSInteger, MusicERpt) {
    MusicERptOff = 'kRpO',
    MusicERptOne = 'kRp1',
    MusicERptAll = 'kAll'
};

@protocol MusicTrack <NSObject>
@property (copy, readonly) NSString *name;
@property (copy, readonly) NSString *artist;
@property (copy, readonly) NSString *album;
@property (copy, readonly) NSString *albumArtist;
@property (readonly) double duration;          // seconds
@property (readonly) NSInteger databaseID;     // stable per track within library
@property (copy, readonly) NSString *persistentID;
// "Favorite" (sdef property name "favorited", code pLov), read/write. This is the
// ONLY real name — there is no `loved` property, so calling `loved`/`setLoved:`
// would send an unrecognized selector through ScriptingBridge and crash.
@property BOOL favorited;
@property (readonly) NSInteger index;          // 1-based position in app order
// Elements are artwork objects; read their `data` (an NSImage) via KVC — the
// runtime protocol cast for SB element classes is unreliable, and 'raw data'
// returns an unrealized specifier rather than bytes.
- (SBElementArray *) artworks;
@end

// The playlist that contains the currently-playing track. Apple Music exposes no
// real "Up Next" queue, so the switcher approximates it from this playlist's
// upcoming tracks. Read element names/artists via KVC (same SB caveat as artwork).
@protocol MusicPlaylist <NSObject>
@property (copy, readonly) NSString *name;
- (SBElementArray *) tracks;
@end

@protocol MusicApplication <NSObject>
@property (readonly) MusicEPlS playerState;
@property double playerPosition;               // seconds into current track (read/write)
@property NSInteger soundVolume;               // 0...100 (read/write)
@property BOOL shuffleEnabled;
@property MusicERpt songRepeat;
@property (copy, readonly) id<MusicTrack> currentTrack;
@property (copy, readonly) id<MusicPlaylist> currentPlaylist;
- (void) playpause;       // toggle play/pause
- (void) nextTrack;
- (void) previousTrack;
- (void) backTrack;       // restart current track / go to previous
@end

// Declare conformance so Swift sees Music's members directly on the live
// SBApplication that ScriptingBridge returns (no class symbols, no casts).
// `currentTrack` is typed `id<MusicTrack>`, so track members work the same way.
@interface SBApplication (DynamicIslandMusic) <MusicApplication>
@end
