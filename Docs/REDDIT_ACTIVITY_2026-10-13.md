# Reddit activity — 2026-10-13

## Run status

The authenticated Chrome session was available. I reviewed the newest r/appletv and r/ApplePhotos feeds, opened the strongest posts and their visible comments, checked r/appletv's visible rules, searched r/AskPhotography for recent geotagging questions, and checked the account profile and notifications.

The account remains at **13 total Karma**, split as 4 post Karma and 9 comment Karma. The newest notification was a recommendation based on visiting r/ApplePhotos, not a reply or verified upvote. No new external engagement is claimed.

No comment was published. One useful correction for an r/ApplePhotos transfer question is ready, but posting a public comment through the browser requires action-time confirmation. The final draft is recorded in the LensPin activity file for today.

## Signal 1 — A second tvOS 27 thread reports severely limited photo-screen-saver rotation

Source: [Is screensaver using photos even worse in os27?](https://www.reddit.com/r/appletv/comments/1x3pd6j/is_screensaver_using_photos_even_worse_in_os27/)

### Original-post facts

- The poster uses an album of about 200 photos and says tvOS 27 repeatedly shows the same roughly 40 images without adding new ones.
- They said the behavior was already poor in tvOS 26 and became worse after updating.
- At review time the post was about 22 hours old, showed 5 points and 4 comments.

### Comment signal

- One commenter said a session showed only eight pictures from a collection of hundreds, too few to fill more than two layouts.
- Another asked whether photo quality had also degraded compared with earlier behavior.
- A fourth wanted the portrait screensaver to allow explicit photo selection.
- This independent thread strengthens yesterday's 3–5-photo report, but the exact subset sizes differ and no root cause was established.

### Product inference

- Rotation breadth, visual quality, and explicit curation are three distinct requirements. A large eligible library does not create a satisfying television experience if the player repeatedly samples a tiny subset.
- Photo Earth should expose aggregate preparation state and test rotation coverage across sessions, while keeping its presentation cinematic. A quiet “prepared N of M memories” state is more trustworthy than an unexplained narrow loop.
- Users also want control over portrait treatment. Photo Earth's existing `.fit` foreground policy with a soft side background is aligned with preserving the full image, but the app still needs a user-facing way to understand why a photo appears or is skipped.

### Competitors or alternatives

- Apple's built-in Photos screensaver and portrait screensaver are the direct alternatives discussed.

### Unverified

- Apple TV model, album type, iCloud state, available storage, network state, and exact tvOS build were not supplied.
- The thread does not establish whether the problem is sampling, caching, sync, download availability, or layout generation.

### Next validation

- Add deterministic tests for no-repeat windows, fair coverage, portrait preservation, and restart behavior over 200, 1,000, and 10,000 eligible assets.
- Distinguish “eligible,” “metadata indexed,” “thumbnail ready,” and “full-resolution requested” in diagnostics without exposing photo identifiers or coordinates.
- Validate whether users prefer chronological, shuffled, favorite-weighted, or manually curated rotation before adding controls.

## Signal 2 — A calm live-map app received unusually strong early engagement

Source: [I made Spår, an Apple TV app for watching trains move around a live map](https://www.reddit.com/r/appletv/comments/1x43om6/i_made_sp%C3%A5r_an_apple_tv_app_for_watching_trains/)

### Original-post facts

- Spår shows real-time trains in Sweden, Finland, and Norway on a dark map, colors them by delay, and lets the viewer follow one train.
- The developer designed it to remain on the television as an ambient display: controls fade, the map drifts slowly, an optional clock can remain visible, and the app prevents the system screensaver from starting.
- It supports Apple TV HD and newer, costs US $3.99, and claims no account, advertising, or tracking.
- At review time, after about nine hours, the post showed 118 points, 11 comments, one repost, and 61 shares.

### Comment signal

- A first-generation Siri Remote user reported that holding the touch surface edges zoomed and that navigation and train selection worked well; the developer said that remote had not been tested previously.
- Another commenter described the experience as “very relaxing” and asked for all-Europe coverage.
- Discussion about Denmark exposed a material expansion constraint: a commenter and developer discussed an API believed to be noncommercial-only, with the commercial option reportedly around €5,500 per year. This amount was not independently verified.
- Other replies asked about data provenance. The developer named national transport APIs and their licenses.

### Product inference

- The engagement is evidence that a television can succeed as a calm, glanceable, spatial canvas rather than only as a video launcher. This is highly relevant to Photo Earth's “private travel film” direction.
- The successful elements are restraint and legibility: dark map, one primary visual system, disappearing controls, slow drift, optional clock, and direct remote navigation.
- Photo Earth should test a passive “leave it running” state after the user starts a slideshow, but should not copy the live-data product. Personal photos and emotional pacing remain the differentiation.
- Old Siri Remote compatibility can create goodwill even when newer hardware is the main target. Product behavior needs explicit remote-generation coverage, especially for edge gestures and wake-versus-move semantics.

### Competitors or alternatives

- Spår is a direct example of an ambient live-map tvOS product.
- Flight and ship radar apps are adjacent living-room map products already seen in earlier research.

### Unverified

- Reddit engagement does not reveal paid conversions, retention, session length, or refund rate.
- The app was not purchased or tested, and the claims about tracking, screen protection, data freshness, and remote behavior were not independently audited.
- Share counts and points are a snapshot and can change.

### Next validation

- Prototype a Photo Earth ambient mode with controls fading, slow camera movement, and optional minimal clock, then test whether it deepens emotion or distracts from photos.
- Run task-based remote tests across first- and later-generation Siri Remotes: move, zoom, open menu, follow/select, wake after fade, and recover from accidental input.
- Measure repeat viewing and session length before treating high Reddit engagement as product-market fit.

## Signal 3 — iOS 27 photo keywords expand curation, but PhotoKit query limits remain

Source: [This Apple Community question about tagging photos on iPhone is 10 years old](https://www.reddit.com/r/ApplePhotos/comments/1x3u3d2/this_apple_community_question_about_tagging/)

### Original-post facts

- The developer cited a 2016 Apple Community request with 1,351 “Me too” reactions for adding Mac-style keywords on iPhone.
- Their EyeSay app uses on-device classification, requires user review, and can save albums, Photos keywords, or both. It adds only missing keywords and offers undo history.
- At review time the Reddit post showed 1 point and no comments, so the old support count is historical demand evidence, not current Reddit validation of EyeSay.

### Verified platform context

- Apple's WWDC26 Camera and Photo Technologies Group Lab says keywords are editable and searchable in the iOS Photos info panel and appear in IPTC metadata on export.
- Apple documents a beta `PHAssetChangeRequest.addKeyword(_:)` API, but the same lab says there is currently no PhotoKit-level API to fetch or query assets by keyword.
- Therefore keywords are not yet a reliable general-purpose browsing index for Photo Earth.

### Product inference

- Review-before-write, add-only behavior, and undo history are strong trust patterns for metadata tools.
- Photo Earth should remain read-only. If keywords become reliably readable through PhotoKit later, they could become optional curation signals, but they should never replace time/location truth or force users to tag first.

### Competitors or alternatives

- EyeSay, Apple Photos albums, Photos search, and Mac Photos keywords.

### Unverified

- EyeSay was not installed or tested.
- The exact behavior of keyword sync, conflict handling, and third-party readability across iOS, macOS, and tvOS was not tested.

### Next validation

- Monitor PhotoKit keyword read/query capabilities in later SDK updates.
- Do not add keyword-dependent product requirements until a supported read path and sync behavior are verified end to end.

## Comment activity

No comment was published. The screensaver threads contain useful problem reports but no verified fix; the Spår discussion already had relevant remote feedback; and the keyword post was product promotion without user discussion. The only strong help candidate was a separate iPhone-to-Windows transfer question, recorded with its final draft in the LensPin file pending action-time confirmation.
