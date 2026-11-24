# Reddit activity — 2026-10-06

## Run status

The authenticated Chrome session was available. I reviewed the newest r/appletv and r/ApplePhotos posts, current r/appletv rules, account notifications, and the live profile. The newest r/appletv topics were a tvOS beta profile-picture change, a thank-you post, and a Prime Video audio-sync support request. None supplied a distinct, unresolved tvOS app need that was strong enough to add to the side-project shortlist.

The live profile remained at **13 total Karma: 4 post Karma and 9 comment Karma**. No new reply or verified external upvote appeared after the Utkik interaction recorded on 2026-10-04.

## Adjacent signal — Third-party photo pickers can obscure recently created copies

Source: [Snapseed 4.1.3 slow-to-sync with iOS 27 Photos](https://www.reddit.com/r/ApplePhotos/comments/1wyh50i/snapseed_413_slowtosync_with_ios_27_photos/)

### Original-post facts

- A user exported an edit from Snapseed and could see the copy beside its older original in the Photos library.
- The copy did not appear where the user expected in the mini-printer app's picker, Photos Recents, or the Snapseed album.
- Screenshots appeared immediately, while the edited export seemed inconsistent.
- The r/ApplePhotos cross-post had no comments at review time; the original r/snapseed post had one moderator asking privately for an image of the printer picker, without a public diagnosis.

### User signal

- Users describe a discovery or sorting mismatch as “sync” even when the asset is already present in Photos.
- Capture-date order, date-added order, album membership, and a third-party picker's filtering are easily conflated.

### Product inference

- Photo Earth should explain why a photo appears at a particular time or place when its import date differs from its capture date.
- The product should keep PhotoKit capture time as the travel timeline fact while exposing a clear refresh state for newly added assets.
- This is an adjacent trust signal, not evidence for a new Apple TV app by itself.

### Unverified

- The exported asset's metadata, album membership, picker sort order, and PhotoKit authorization scope were not inspected.
- It is unknown whether the cause was Snapseed, Photos, the mini-printer app, or the user's expectation of Recents ordering.

### Next validation

- Verify Photo Earth's incremental scan when an old photo is edited or duplicated today but retains an old capture date.
- Ensure recent-import messaging does not imply recent travel and that the globe remains ordered by capture time.

## Comment activity

No comment was published. The Apple TV threads lacked a verified, non-duplicative answer, and the Snapseed report needed metadata and picker-state checks before a specific diagnosis would be reliable.
