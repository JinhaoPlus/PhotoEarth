# Reddit research — 2026-11-09 (Asia/Shanghai)

## Scope and account state

- Used the logged-in Chrome account to inspect r/appletv's new feed and current rules, search recent photo and screensaver posts and comments, read the complete visible discussions for a new universe visualizer, a Home Sharing photo-source complaint, and a music quiz party game, check r/ApplePhotos only for Apple TV-related results, revisit our existing map-photo post, and inspect notifications and the profile.
- Research stayed within Apple TV / Photo Earth. LensPin, camera geotagging, GPS/GPX/EXIF workflows, and the excluded photography communities were not researched.
- The profile showed **532 total Karma**. The previous verified snapshot was 522 on 2026-11-08, so the account-wide change is **+10**. The account had unrelated activity during this interval, so the change cannot be attributed to any Apple TV post or comment.
- No new Apple TV / Photo Earth-specific reply or upvote notification was visible.

## Signal 1 — users repeatedly ask for cinematic visual apps to become ambient modes

[I made a free Apple TV app where the universe forms, galaxies collide and you can fly into the Orion Nebula](https://www.reddit.com/r/appletv/comments/1xr9480/i_made_a_free_apple_tv_app_where_the_universe/)

### Original post facts

- The developer launched Everdust, a free Apple TV app with no ads or account requirement. It visualizes cosmic history, galaxy collisions, black holes, Saturn, strange attractors synchronized to AirPlay music, and a real-sky mode that can fly into objects such as the Orion Nebula with the remote.
- The post showed **31 upvotes and 5 comments** at inspection. The developer also linked an App Store listing and said the app requires tvOS 27.
- The developer explicitly asked what users would want to see next on the big screen.

### Comment signals

- Three visible commenters independently asked for the visuals as a screensaver or agreed with that request. The first request showed 6 upvotes and the newest agreement showed 2 at inspection.
- The developer said an app-level ambient or screensaver-like mode was planned, while noting that tvOS does not let a third-party app replace the system screensaver.
- The developer also mentioned publishing 4K HDR versions with little or no audio, suggesting a passive-display use case distinct from the interactive app.

### Product inference

- Users are not only asking for visual content; they want it to remain on the television with minimal UI and minimal maintenance. “Ambient mode” is a clearer and more technically honest product category than promising a third-party system screensaver.
- This supports Photo Earth's existing cinematic, low-chrome direction and suggests that a long-running passive journey or globe mode could have value after the interactive core works.
- The request also raises product costs that are easy to miss: burn-in mitigation, Reduce Motion behavior, stable long sessions, predictable audio, download/network failure states, and returning cleanly to interaction.
- It does not prove that users want personal photos or a geographic globe specifically; the attraction here may be astronomy visuals alone.

### Competitors or alternatives

- Everdust is an adjacent competitor for cinematic Apple TV visualization and ambient display, not a personal-photo travel product.
- Apple's aerial and photo screensavers remain the system-level alternatives, with capabilities third-party apps cannot replace.

### Unverified / next validation

- This is a launch post with a small comment sample. Upvotes and repeated screensaver requests show interest, not retention or willingness to pay.
- Test Everdust before making claims about its image quality, remote feel, session stability, or ambient-mode implementation.
- For Photo Earth, validate whether users want a passive globe journey, a passive photo sequence, or both; those are different playback products.

## Signal 2 — loss of a large local photo source creates room for app-level folder playback

[No access to Home Sharing Photo Library](https://www.reddit.com/r/appletv/comments/1xay8rx/no_access_to_home_sharing_photo_library/)

### Original post facts

- The author reported that after updating a third-generation Apple TV 4K, they could no longer select a Mac Home Sharing photo library as a screensaver source and could only choose iCloud Photos.
- They said the previous setup could rotate through hundreds of photos from a Mac folder, while the current iCloud-based result appeared to repeat roughly a dozen at a time.
- In a follow-up, the author identified tvOS 27 as the affected version and said older Apple TV HD devices still exposed the Home Sharing source.

### Comment signals

- Another commenter agreed that losing the source was a regression. A separate commenter linked Apple's guide, which still described Home Sharing, but the author said the documented path no longer existed on their current tvOS version.
- A new comment from the developer of Pixette proposed a workaround: share a regular Mac folder over SMB and leave the Apple TV app open to shuffle a folder of any size.
- The Pixette developer clearly disclosed the affiliation and also stated the platform boundary: it is an app-level slideshow, not a third-party system screensaver.

### Product inference

- A substantial subset of living-room photo users values breadth and source control more than automatic curation. Repetition from a small effective pool is experienced as a product failure even if the interface technically works.
- Photo Earth's promise should remain PhotoKit-based and automatic; requiring Mac folders and SMB would contradict the confirmed onboarding goal. The competing workflow is still useful evidence that large-library playback and transparent source scope matter.
- An app-level ambient mode can be a viable answer when system screensaver APIs are unavailable, but the limitation must be stated plainly.
- The strongest opportunity is not merely “support SMB.” It is letting users understand exactly which photos are eligible, why a photo appears, and whether the full intended collection is rotating.

### Competitors or alternatives

- Apple's iCloud Photos screensaver and former Home Sharing source are the native alternatives.
- Pixette is a direct adjacent alternative for Mac-folder/SMB photo shuffle, but its workflow requires manual folder preparation, File Sharing, and leaving the app open.

### Unverified / next validation

- The reported tvOS 27 behavior was not reproduced on hardware in this run. Apple's guide and the observed UI report conflict, so removal should not be stated as an independently confirmed platform fact.
- The “roughly a dozen photos” count is the author's observation, not a measured system limit.
- Test Pixette with a large folder before making claims about shuffle quality, SMB reliability, privacy, performance, or image fidelity.

## Signal 3 — the TV-as-stage pattern needs cross-platform participation

[I made a music quiz party game for Apple TV: the TV is the stage, everyone's phone is the buzzer](https://www.reddit.com/r/appletv/comments/1xqvllg/i_made_a_music_quiz_party_game_for_apple_tv_the/)

### Original post facts

- Quizcendo uses the Apple TV or an iPad as the shared stage while two to twelve players join through a free iPhone/iPad buzzer app by scanning a QR code.
- The first game is free, followed by a one-time purchase; the developer described more than 13,000 songs and ten round types.
- The post showed 0 upvotes and 5 comments at inspection.

### Comment signals

- One commenter immediately compared it with Jackbox, showing that the category already has a strong mental incumbent.
- The only concrete feature request was Android-phone participation. In a group setting, requiring every guest to have an iPhone or iPad can break the otherwise low-friction join model.
- Other visible comments focused on whether the app was AI-assisted rather than on game demand.

### Product inference

- The Apple TV as a communal stage with private phone input remains a plausible side-project architecture, but cross-platform guest access is part of the core product, not a later expansion.
- A QR code alone does not guarantee low friction if it leads to an app install, platform restriction, account step, or network problem.

### Competitors or alternatives

- Jackbox is the explicit incumbent mentioned by commenters; general console and casting party games are additional alternatives.

### Unverified / next validation

- The launch post's engagement is weak and does not establish demand. Seek independent complaints about existing party-game setup, pricing, or content before investing.
- Validate whether browser-based guest input can meet latency and privacy requirements without requiring a native Android app.

## Follow-up checks

- Our [Apple TV photo-map recommendation post](https://www.reddit.com/r/appletv/comments/1x95zy2/what_do_you_use_to_browse_your_icloud_photos_on_a/) still showed **2 upvotes and 1 comment**. The page reported 6.2K views, but views are not approval or product demand. There was no new reply.
- The earlier [AirPlay overlay support post](https://www.reddit.com/r/appletv/comments/1xqlcbc/airplay_isnt_playing/) now had 7 comments. A 6-upvote reply identified Conference Room Display under AirPlay and Apple Home as the likely overlay source and linked Apple documentation, so the previously unresolved support case no longer needed another answer.
- The Salon thread remained at 74 upvotes and 58 comments in the inspected search results.
- r/ApplePhotos produced no new Apple TV-specific post; the newest directly relevant map-photo request remained the older thread already tracked.

## Public activity and skipped actions

- No comment, vote, post, private message, chat, follow, join, or other account action was performed.
- The Everdust thread already contained three screensaver requests and a direct developer response about the ambient-mode plan. Repeating the request would add no value.
- The Home Sharing thread already contained both the documented-settings check and a disclosed SMB-app workaround. The underlying platform behavior was not independently verified, so another confident diagnosis would be unsafe.
- The party-game thread offered a useful Android-participation signal, but the existing comment had already made that request. No non-duplicative, reliable reply met the quality threshold.
