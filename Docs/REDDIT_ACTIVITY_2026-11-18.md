# Reddit research — 2026-11-18 (Asia/Shanghai)

## Scope and account state

- Used the logged-in Chrome account to inspect r/appletv's newest feed and current rules, search recent photo/screensaver discussions, read the new subtitle-accessibility report and the active memory-limit discussion, revisit two Apple TV help comments plus the FamPad and photo-map threads, check r/ApplePhotos for Apple TV-specific posts, and inspect notifications and the profile.
- Research stayed within Apple TV / Photo Earth. LensPin, camera geotagging, GPS/GPX/EXIF workflows, and the excluded photography communities were not researched. Unrelated notifications were viewed only to avoid attributing account-wide Karma changes to Apple TV activity.
- The profile showed **602 total Karma**, a net change of **+6** from the verified 596 snapshot on 2026-11-17. Because the account had activity and notifications in several unrelated communities, the account-wide change cannot be attributed to the Apple TV comments alone.

## Signal — apps can undermine system subtitle readability choices

[NOW / Peacock ignoring OS-level subtitle font?](https://www.reddit.com/r/appletv/comments/1xz1qkd/now_peacock_ignoring_oslevel_subtitle_font/)

### Original post facts

- The author reported that Peacock in the US and NOW in the UK replace the selected Apple TV subtitle font with a thin branded font when System Font Medium/Regular or Helvetica is selected.
- They said `Video Overrides Style` was off and that color, size, and edge-style choices were still respected. They also said the behavior had persisted for more than a year.
- At inspection the post showed **1 displayed score and 0 comments**. These observations are the author's report; this run did not reproduce the behavior on hardware.

### Comment signals

- There were no comments to corroborate the report or identify whether both apps share the same playback stack.
- No reply was added: without access to either service and a reproducible test, a generic suggestion to recheck the setting would repeat diagnostics the author had already completed.

### Product inference

- For a living-room app, respecting system text, contrast, Reduce Motion, and Reduce Transparency choices is part of the core experience rather than optional polish. A visually branded treatment can directly reduce readability on a television viewed from several metres away.
- Photo Earth controls its own captions and overlays, so it should test system accessibility combinations directly and avoid substituting thin decorative typography for user-selected readable text.
- A general “Apple TV accessibility checker” is not yet a credible side project from this evidence. A third-party app cannot inspect or correct another app's subtitle renderer, so the actionable opportunity may be limited to guided diagnostics and evidence collection.

### Competitors or alternatives

- The reported products are Peacock and NOW. The author did not identify a tvOS alternative or workaround that preserves the selected system font.

### Unverified / next validation

- Reproduce with the current Peacock and NOW builds before treating this as a platform-wide defect.
- Look for independent reports involving the same font presets or other streaming apps; one uncorroborated post is a usability hypothesis, not a market conclusion.
- Add Photo Earth television-distance checks for every persistent caption, count, and empty-state label under larger text and high-contrast combinations.

## Signal — users respond to concrete Apple TV audio diagnostics

[Audio low in Apple TV for PCM](https://www.reddit.com/r/appletv/comments/1xy7eh6/audio_low_in_apple_tv_for_pcm/)

### Original post facts

- The author reported low PCM volume with a Sonos Arc and Apple TV, louder output after converting to Dolby Digital 5.1, and an Atmos readout when Continuous Audio Connection was enabled.
- At inspection the thread showed **9 comments**.

### Comment signals

- The account's [existing diagnostic reply](https://www.reddit.com/r/appletv/comments/1xy7eh6/comment/19sr12b0qdu05/) explained the distinction between the connection format and the original mix, recommended testing Auto plus Continuous Audio Connection, and treated Dolby Digital conversion as a fallback.
- Reddit delivered a **5-upvote notification** for that reply. The author answered “Thank you” and said they hoped Continuous Audio Connection would raise PCM volume.

[AppleTV dialog audio volume](https://www.reddit.com/r/appletv/comments/1xya07d/appletv_dialog_audio_volume/)

- The author described large loudness differences between action and dialogue when playing a NAS video in Infuse Pro.
- The account's [existing reply](https://www.reddit.com/r/appletv/comments/1xya07d/comment/19sr652ad67xf/) distinguished Reduce Loud Sounds from Enhance Dialogue and suggested Voice Isolation as a stronger fallback. Reddit delivered a **first-upvote notification** for it; the thread showed **2 comments** at inspection.

### Product inference

- Users appear to value a decision tree that maps an audible symptom to the correct tvOS setting and explains tradeoffs. The positive interaction is evidence for helpful troubleshooting content, not proof of demand for a standalone app.
- A lightweight Apple TV setup companion could be worth validating around audio, subtitles, HDMI, HomePods, and remote behavior. The main constraint is platform authority: an app may be able to explain and test its own playback, but not read or change every relevant system or third-party-app setting.
- For Photo Earth, soundtrack and video playback controls should use plain language and expose the actual consequence of each option; connection-format labels must not be presented as proof of the media's original format.

### Unverified / next validation

- Search for repeated questions that share the same diagnostic branches before defining a product.
- Verify which settings a tvOS app can observe or deep-link to; do not design a “one-click fixer” around permissions the platform does not expose.

## New-feed screening

- The newest feed was dominated by new-hardware setup, HomePod audio, Wi-Fi, activation, Siri voice-command gaps, HDMI/audio behavior, and app-specific playback failures.
- The [2 GB / Picture-in-Picture experiment](https://www.reddit.com/r/appletv/comments/1xydvfz/2gb_ram_limit_per_app_meet_pictureinpicture/) showed **52 votes and 22 comments** in search results, but the discussion was largely jokes about a redacted private IP address plus disagreement over whether two processes could help one workload. The title's memory-limit claim was not independently verified, and the thread does not establish a user-facing product need.
- A new Apple TV review had **24 votes and 28 comments** and praised picture, sound, smoothness, and OS responsiveness while criticizing price. A separate voice-command thread reported that volume, Back, and Home commands fell back to “use the remote.” These are useful interaction constraints but did not expose a Photo Earth-specific feature request.

## Ongoing photo and screensaver evidence

- The [FamPad thread](https://www.reddit.com/r/appletv/comments/1xuhitc/i_built_a_free_skylightstyle_family_calendar_that/) remained at **25 votes and 32 comments**. No new photo/screensaver signal appeared since the prior record.
- Our [Apple TV photo-map recommendation post](https://www.reddit.com/r/appletv/comments/1x95zy2/what_do_you_use_to_browse_your_icloud_photos_on_a/) remained at a **displayed score of 2** with **1 comment** and no new reply.
- r/appletv's recent photo/screensaver search produced no new photo-specific post. r/ApplePhotos likewise had no fresh Apple TV photo discussion; the visible map-browsing result was two months old.

## Public activity and skipped actions

- No new comment, vote, post, private message, chat, follow, join, or other account action was performed during this run.
- The only fresh low-reply candidate was the subtitle-font report. It already contained the necessary setting checks, and this run could not reproduce the issue or add a verified workaround.
- Existing Apple TV replies received directly verifiable interaction, but they were posted before this run; this record does not claim them as today's publishing activity.
- No fresh Photo Earth-relevant support question met the threshold for a useful, nonduplicative comment.
