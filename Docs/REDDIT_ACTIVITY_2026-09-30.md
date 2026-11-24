# Reddit activity — 2026-09-30

## Run status

The authenticated Chrome session could not be controlled because the Mac was locked and the browser bridge timed out while attaching to the Reddit tab. Public Reddit pages and search indexes were therefore used for read-only research. No comment was published because the logged-in state, final thread state, and resulting permalink could not be verified.

The public profile currently shows **4 post Karma, 8 comment Karma, 12 total Karma, and 48 contributions**. This matches the last verified Karma split from 2026-09-28; no change can be attributed to any individual comment. The public profile does not expose inbox state, so new direct replies were not claimed without evidence.

Communities and threads reviewed:

- r/appletv and recent indexed posts
- r/ApplePhotos and recent indexed posts
- [Best App for slideshow of photos on Apple TV?](https://www.reddit.com/r/appletv/comments/1rmyv1e/best_app_for_slideshow_of_photos_on_apple_tv/)
- [Looking for an app to upload my own files for offline viewing](https://www.reddit.com/r/appletv/comments/1wslj74/looking_for_an_app_to_upload_my_own_files_for/)
- Public account overview for prior-comment and Karma checks

## Signal 1 — A paying user exposed two critical failures in a competing tvOS photo app

### Original-post facts

- The six-month-old slideshow request asks for genuine shuffle across thousands of photos because Apple's screensaver repeatedly cycles through a small cached subset.
- The requester explicitly says the television slideshow is used during family gatherings and that they are willing to pay for a good app.
- Two developers later promoted tvOS photo apps in the thread. One, Imagozo, offers Apple Photos/shared albums, OneDrive, NAS/SMB, metadata, and a story mode that groups photos by time and place.

### User signals from comments

- A user who bought Imagozo reported on 2026-09-27 that the app is not intuitive, Back from Settings > General jumps to the main menu instead of the Settings parent, and a selected source still allows unrelated photos into the slideshow.
- The developer acknowledged the feedback on 2026-09-29 and said a UI/UX redesign, performance work, and a new album system are in progress.
- Another commenter described the slideshow as emotionally important after a brain injury because old photos help recover personal memories and prompt “where was that?” conversations.

### Product inference

- Correct source boundaries are a trust requirement. Showing photos outside a selected album or source is more damaging than a missing animation because the living room is a shared and potentially sensitive context.
- Predictable Back hierarchy is core tvOS usability. The confirmed Photo Earth navigation rule—detail → wall → globe → home, and Settings child → Settings parent—matches an observed competitor failure.
- “Genuine shuffle” needs a visible fairness model: avoid recent repeats, show progress through the selected set, and define what happens when the library changes.
- The emotional value is not abstract. For some users, a television photo experience is a memory aid and a family conversation surface.

### Competitors or substitutes

- Apple Photos screensaver and album slideshow.
- Imagozo for multi-source story/slideshow playback.
- LumaFrame for HDR/4K viewing from Apple Photos.

### Unverified

- Imagozo's current App Store build and the promised redesign were not tested.
- The source-mixing report is one user's experience and may depend on configuration, but it is concrete enough to treat as a high-priority regression class.

### Next validation

- Add an acceptance test proving a selected place, album, or source cannot leak unrelated assets into playback.
- Test every Back transition on a physical Siri Remote, including nested Settings and photo-detail flows.
- Prototype a no-repeat/fair-shuffle mode with a simple “shown X of Y” state and a reset action.

## Signal 2 — Users want a portable offline presentation mode on Apple TV

### Original-post facts

- A recent r/appletv post asks to preload a specific video onto Apple TV, carry the device elsewhere, and play it without Wi-Fi or AirPlay.
- Multiple commenters initially assumed Apple TV storage was unusable for this purpose.
- Other users reported that VLC Remote Playback can upload media into the app's container and play it locally, while warning that tvOS may purge app data under storage pressure.
- Alternatives suggested included a USB-capable television, Android stick, iPad with HDMI, portable router plus SSD, and a second device acting as a local server.

### User signals from comments

- The requester repeatedly clarified that the destination may have no Wi-Fi and that bringing a computer defeats the purpose.
- The response only became useful after users identified an app-specific download workflow; generic Plex/server advice did not match the travel scenario.

### Product inference

- “Prepare at home, verify, then carry one box” is a distinct tvOS job. A side project could provide a small offline presentation vault with file transfer, storage estimates, download verification, and a pre-departure readiness check.
- For Photo Earth, an optional offline trip or album could be valuable for family visits, exhibitions, and locations with poor internet. It must disclose that tvOS storage is app-managed and purgeable, so it cannot promise permanent archival storage.
- Readiness should be explicit: number of items available offline, missing iCloud originals, total size, last verification, and a test-play action.

### Competitors or substitutes

- VLC Remote Playback is the strongest software substitute mentioned.
- Hardware substitutes include USB playback, an Android stick, an iPad/HDMI adapter, or a portable router and storage device.

### Unverified

- VLC's current tvOS limits, maximum practical file size, background-transfer behavior, and purge behavior were not tested.
- It is unknown whether users would pay for a dedicated presentation app rather than use VLC or another device.

### Next validation

- Interview users who present family videos, trade-show loops, classroom material, or client reels away from home.
- Test whether tvOS reliably retains a bounded 5–20 GB app cache across reboots and normal app usage, while treating any result as best-effort rather than durable storage.

## Comment and account activity

No comment was published. The offline-media thread already had tested VLC answers and hardware alternatives, while the slideshow thread's latest branch was an active support exchange between a buyer and the developer. Adding another reply would not have supplied new help. The locked Mac also prevented the authenticated final-state check required before publishing.
