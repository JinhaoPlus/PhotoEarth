# Reddit research — 2026-11-07 (Asia/Shanghai)

## Scope and account state

- Used the logged-in Chrome account to read r/appletv's current feed, community rules, the complete visible discussion for two new tvOS apps, and one directly relevant r/ApplePhotos travel-slideshow thread.
- Research stayed within Apple TV / Photo Earth. LensPin, GPS/GPX/EXIF workflows, and the photography-oriented communities were not researched.
- The profile showed **514 total Karma**. The last verified snapshot in this log was 505 on 2026-11-06, so the account-wide change is **+9**. This cannot be attributed to any particular comment.
- The inbox contained one new relevant reply in r/ApplePhotos. No new Apple TV / Photo Earth-specific upvote notification was visible in the inspected notifications.

## Signal 1 — people want a deliberate personal-photo source, not “all favorites”

[Scratched my own itch](https://www.reddit.com/r/appletv/comments/1xm60f3/scratched_my_own_itch/)

### Original post facts

- The developer launched Salon, a tvOS ambient-art app created after dissatisfaction with Samsung Frame's software and subscription model.
- It combines supplied art collections with personal iCloud Photos. The described personal-photo workflow starts from photos favorited on iPhone, with a subset then selectable in the TV app.
- The app uses a one-time purchase and offers frame/mat controls, time/date, manual 16:9 painting crops, portrait handling, rotation, and subtle motion intended to reduce burn-in risk.
- At inspection the thread showed 72 upvotes and 57 comments. The developer was actively answering feature and support questions.

### Comment signals

- One purchaser said Favorites is the wrong source because many favorites are not suitable for display and asked for another way to add photos. A dedicated album was discussed as an alternative.
- Another purchaser wanted to add an entire collection to Favorites instead of selecting images one by one.
- Multiple users requested brightness, gamma, white-point or warmer-border controls so the television looks less emissive and more like framed art.
- Other requests included next/previous navigation, artist search, predictable Back behavior, returning to the previous section, random mats, portrait-TV support, and automation or occupancy-based launching.
- A user said they had bought an Apple TV mainly for its photo screen saver but found the built-in functionality limited. Other commenters defended Samsung Frame's free art mode, sensors, auto-resume, and museum/artist-discovery value.

### Product inference

- Photo Earth should not silently equate Favorites with “photos I want on the television.” If it later adds an ambient or curated mode, source semantics need to be explicit: full library, named album, favorites, a journey, or an app-managed selection are different intents.
- Living-room photo presentation needs room-aware visual controls. Photo Earth's cinematic grade should be tested on real televisions for perceived brightness and white balance; an attractive monitor screenshot does not prove a comfortable ambient TV image.
- Remote recovery and spatial memory are product quality, not polish: Back should not unexpectedly exit, and returning should restore the previous section and focus.
- Occupancy-triggered launch is a real request but may be constrained by tvOS lifecycle and automation APIs. It should be technically verified before becoming a promise.

### Competitors or alternatives

- Salon is a direct adjacent competitor for ambient personal-photo and art display, but not for travel geography or journey reconstruction.
- Samsung Frame's built-in art mode and Apple's photo screen saver remain the obvious alternatives.

### Unverified / next validation

- Engagement was helped by launch promotion and code giveaways, so 72 upvotes and 57 comments do not establish paid demand or retention.
- Test Salon before making claims about its focus behavior, image quality, iCloud scaling, or storage resilience.
- Look for repeated independent requests for dedicated albums and room-calibrated presentation before changing Photo Earth's main scope.

## Signal 2 — a travel slideshow must preserve mixed photos and full video clips

[Play a folder of photos/movies as a slideshow](https://www.reddit.com/r/ApplePhotos/comments/1xoyu8a/play_a_folder_of_photosmovies_as_a_slideshow/)

### Original post facts

- The author wants to play a recent safari as a sequence of photos and short videos, organized into one folder per day and ideally nested under one parent folder.
- Photos should remain on screen for about ten seconds, while each video should play to completion before advancing.
- The author said the Photos slideshow workflow and VLC did not appear to provide that automatic mixed-media behavior.

### Comment signals

- Our earlier reply described the standard Photos slideshow command but did not answer the crucial full-video-autoplay requirement. The author explicitly corrected that gap.
- Another commenter suggested making a prepared movie in iMovie, which preserves full clips but requires assembling and re-exporting the trip and does not follow later folder changes.
- A third-party app was recommended for folder-based slideshows, but the visible comment did not verify mixed-media behavior.

### Product inference

- Photo Earth's planned “Earth Slideshow” should treat static photos, Live Photos, and videos as first-class but different timeline items: photos need a dwell duration; videos need explicit full-clip or capped-duration policy; audio and download state must be predictable.
- A journey is naturally hierarchical to users: trip → day → photos/videos. Even if Photo Earth infers journeys instead of importing folders, its playback and resume model should preserve that understandable structure.
- This thread also exposes a research-quality failure: a technically correct partial answer can still be unhelpful when it misses the user's decisive requirement. Future comments should restate the required outcome before proposing a workaround.

### Competitors or alternatives

- Apple Photos slideshow, iMovie, VLC, and a commenter-recommended album slideshow app are the visible alternatives.
- iMovie solves presentation after manual authoring; it is not a live, automatically updating travel-memory browser.

### Unverified / next validation

- Verify on current macOS and tvOS exactly how Photos handles videos in slideshows; the thread is user evidence, not an exhaustive platform test.
- Decide and test how Photo Earth handles long videos, muted versus original audio, iCloud download delay, cancellation, and resume position before describing seamless mixed-media playback.

## Signal 3 — the television as a shared game board remains a possible tvOS side project

[I built an actual Apple TV party game, not a phone game cast to TV](https://www.reddit.com/r/appletv/comments/1xpiygj/i_built_an_actual_apple_tv_party_game_not_a/)

### Original post facts

- The developer described a native Apple TV party game for two to seven players using Siri Remote, controllers, or phones, with local rooms, online cross-platform play, bots, and Continuity Camera avatars.
- The developer specifically asked for feedback on remote control, focus, readability, cross-platform play, and whether the result feels native to television.

### Comment signals

- The visible discussion was dominated by accusations about AI-assisted development and a privacy concern, followed by the developer's disclosure and explanation that the TestFlight build used Game Center without a separate signup.
- There was not yet strong visible evidence of player demand, repeat play, or willingness to pay.

### Product inference

- The more general side-project opportunity is not another generic party game. It is a shared-screen architecture where the Apple TV is the legible communal board and phones/controllers provide private or asymmetric input.
- Readability at couch distance, fast join flow, controller fallback, and privacy disclosure are core product constraints.

### Competitors or alternatives

- Existing party games, AirPlay/casting games, and console titles are the broad alternatives.

### Unverified / next validation

- The thread is a launch post, not proof of market demand. Seek independent “I wish Apple TV had…” complaints before promoting this direction.
- Test latency, reconnection, accessibility, and mixed-controller households on physical hardware before treating the architecture as low-risk.

## Public activity and skipped actions

- No comment, vote, post, private message, chat, follow, join, or other account action was performed.
- The Salon thread already contained the album-selection, brightness, automation, navigation, and portrait-display requests, with the developer actively responding. Repeating them would not add value.
- The r/ApplePhotos thread already had an iMovie workaround and a third-party recommendation. Because our previous reply missed the user's decisive video requirement, another reply should be based on verified mixed-media behavior rather than improvisation.
- The party-game thread had not produced a concrete support question we could answer from reliable evidence; joining the AI-authorship argument would not help the user or the research.
