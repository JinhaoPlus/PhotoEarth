# Reddit research — 2026-09-24

## Account and interaction check

- Account: `u/Evening-Focus3876`.
- Verified account total: **4 post karma and 8 comment karma**, unchanged from yesterday.
- Two previously published comments now show **2 points**: the AirPlay troubleshooting comment (`paoyllt`) and the Apple Photos archive/hide-album comment (`pahv9d0`). Each was at the author's default 1 point yesterday, so this is direct evidence of one external upvote on each comment.
- Reddit showed no unread mail and no new direct reply.
- No comment, vote, private message, or post was submitted in this run.

## Browsed themes

- `r/appletv/new`: unwanted sports items in Continue Watching, remote volume control, receiver audio sync, custom remotes, native tvOS playback, Plex regressions, screensavers during music, and Home Hub failures.
- `r/ApplePhotos/new`: shared albums, shared libraries, camera-roll changes, iCloud backup/storage, duplicates, screenshot organization, and a dense cluster of photo-cleaner promotions.

## Evidence 1 — people want a deterministic queue rather than unexplained recommendations

**Source:** [Apple TV keeps filling Continue Watching with live sports I never followed](https://old.reddit.com/r/appletv/comments/1wojovy/apple_tv_keeps_filling_continue_watching_with/)

- **Original-post facts:** The author says live sports repeatedly appear in Continue Watching despite disabling sports scores and notifications, unfollowing every team in Apple News, disabling My Sports sync, and having no sports app installed. They keep play history enabled because they still want episode progress and cross-device synchronization.
- **Comment signal:** When checked, the thread had one reply from another user who described an apparently related case: the system inserted a sequel after a movie from their personal library. The reply speculated that a recent update may be adding recommendations, but it did not establish a cause or workaround.
- **Product inference:** Living-room users distinguish their own activity history from algorithmic suggestions and want explicit control over that boundary. Photo Earth should keep “recently visited” and user-generated memories traceable to actual library data; any discovery or editorial layer should be visually separate and removable.
- **Competitors or substitutes:** Apple TV Continue Watching, streaming-app queues, Plex watch history, manually curated watchlists.
- **Unverified:** The behavior may be a temporary iOS/tvOS service bug, an intended recommendation change, or content-provider metadata. The thread does not establish platform-wide frequency.
- **Next validation:** Track whether users identify a reproducible trigger and ask separately whether a photo app's home screen should contain only personal memories or also optional rediscovery prompts.

## Evidence 2 — native player adoption continues to produce more discussion than routine support posts

**Source:** `r/appletv/new`, “Pluto TV now uses the tvOS native player!”

- **Original-post facts:** The post announced that Pluto TV had switched to the native tvOS player.
- **Comment signal:** It showed 188 points and 30 comments after about one day, while most nearby support questions had single-digit scores and fewer than twenty comments.
- **Product inference:** Familiar system playback behavior remains a visible source of goodwill. Photo Earth should use AVPlayer and standard remote semantics for videos while preserving its own cinematic transitions around the player.
- **Competitors or substitutes:** Custom streaming players and the native tvOS playback stack.
- **Unverified:** The engagement may reflect Pluto TV's existing audience or dissatisfaction with its earlier implementation rather than a general app-selection criterion.
- **Next validation:** Classify which player details users actually praise before converting this into product requirements.

## Side-project direction update

Today's strongest direction is a **personal media queue with transparent provenance and direct cleanup controls**. A focused tvOS utility could combine household watch-state explanations, “why is this here?” metadata, and fast removal, but feasibility depends on APIs that may not expose another app's Continue Watching state. Inside Photo Earth, the actionable lesson is simpler: never mix inferred suggestions into factual sections such as recent visits without clearly labeling the source.

## Comment decision

- Skipped the Continue Watching thread because the only defensible response was to speculate that the behavior is a server-side or update regression; that would not add a verified setting or troubleshooting step.
- No other open thread had a non-duplicative answer that could be given confidently from the information available.
