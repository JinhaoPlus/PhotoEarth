# Reddit activity — 2026-10-11

## Run status

The authenticated Chrome session was available. I reviewed the newest r/appletv and r/ApplePhotos posts, opened the strongest candidate discussions and their existing comments, checked the visible community rules, searched recent photo-geotagging discussions, and checked the account profile and reply inbox.

The profile remains at **13 total Karma**. The current profile page no longer exposes the earlier 4-post/9-comment split, so only the total is confirmed today. The current Reddit notifications page failed to populate after a reload; the old Reddit reply inbox showed no comment reply newer than four days. Therefore, no new reply or upvote is claimed today.

No comment was published. The strongest candidates either already contained the relevant answer, lacked enough verified detail for a responsible answer, or were self-promotional product discussions where another speculative comment would not help the original poster.

## Signal 1 — Families want a continuously updated, duplicate-free people album

Source: [Is this photo automation possible](https://www.reddit.com/r/ApplePhotos/comments/1x2knej/is_this_photo_automation_possible/)

### Original-post facts

- The poster wants photos of a person recognized in Apple Photos to be placed automatically into a shared album.
- Their partner would run the same automation in the other direction.
- They want duplicates removed and want to stop manually checking the People collection, the partner's uploads, and the last photo sent.
- At review time the post showed 2 points and 2 comments.

### Comment signal

- One commenter only said they had made an app that removes duplicates.
- Another user asked for more information. No existing comment answered the full people-recognition, mutual sharing, and duplicate-prevention workflow.

### Product inference

- The actual job is a **self-maintaining household memory feed**, not simply a duplicate cleaner.
- A separate Apple-platform side project could combine an explicitly selected set of people, review-before-share, bidirectional deduplication, and a living-room slideshow. The privacy and API boundaries are substantial: face labels, shared-library membership, and background automation may not be available to third-party apps in the required form.
- For Photo Earth, this supports a future household-viewing mode only if the data can come from PhotoKit without duplicating or silently publishing photos. It does not justify changing the current single-library travel-globe MVP.

### Competitors or alternatives

- Apple Shared Albums and iCloud Shared Photo Library are obvious adjacent system features, but their current ability to implement this exact ongoing person-based workflow was not verified today.
- Duplicate-cleaner apps address only one part of the job.

### Unverified

- It is not yet verified whether PhotoKit exposes the user's People identifications to third-party tvOS/iOS apps in a way that could drive this automation.
- It is not established that both partners want every recognized photo shared without review; sensitive, unflattering, or mistaken matches create a meaningful privacy risk.

### Next validation

- Verify current PhotoKit, Shared Photo Library, and Shortcuts capabilities before treating the idea as feasible.
- Ask whether users prefer automatic sharing, a daily approval queue, or a private shared-TV feed that never changes either library.
- Test duplicate identity across edits, Live Photos, re-exports, and two contributors before promising deduplication.

## Signal 2 — Apple TV social games have demand, but subscription tolerance is low

Source: [Too many weekend nights chilling with friends on the couch led to this...](https://www.reddit.com/r/appletv/comments/1x1jo4y/too_many_weekend_nights_chilling_with_friends_on/)

### Original-post facts

- The developer described recurring couch nights with friends and fatigue with Picolo, Jackbox, and the small number of alternatives.
- They released Couch Questions for tvOS, iOS, and iPadOS as a conversation starter with a drinking-game lean.
- The developer disclosed more than a decade of iOS experience and said the current user base is very small, roughly one or two new users per week.
- The post showed 0 points and 3 comments at review time.

### Comment signal

- A commenter objected to a displayed **$2 per week** price.
- The developer replied that the relevant feature would remain free for the foreseeable future, agreed the price felt too high, and asked what would feel reasonable.

### Product inference

- There is a recognizable living-room job around low-setup conversation and party play, but this thread is weak evidence of product-market fit: engagement and reported acquisition were small.
- Subscription pricing is especially hard to justify for an occasional couch-night utility. One-time purchase, free starter deck, or paid themed packs may fit the usage pattern better.
- A photo-based “memory questions” product could use family photos to prompt stories on Apple TV, but it should remain separate from Photo Earth's quiet travel-film experience unless repeated research shows users want active party mechanics inside the globe.

### Competitors or alternatives

- Picolo, Jackbox, and Couch Questions.

### Unverified

- Couch Questions was not installed or tested.
- The $2-per-week display, free-feature scope, conversion, and retention were not independently verified.
- One pricing objection is not enough to set a market price.

### Next validation

- Interview small groups after an actual couch session and measure whether they return without a host preparing content.
- Test a one-time or pack-based offer before considering a subscription.
- For a photo-memory variant, validate whether private on-device selection and television presentation create more value than a generic question deck.

## Signal 3 — A 60,000-item family archive creates anxiety about growth, lock-in, and loss

Source: [How I Organized, Culled, and Backed Up 60,000 Family Photos from iCloud](https://www.reddit.com/r/selfhosted/comments/1x2svn0/how_i_organized_culled_and_backed_up_60000_family/), cross-posted to r/ApplePhotos.

### Original-post facts

- The poster described a 60,000-item family archive accumulated over about 20 years of Apple use.
- The household creates many photos and videos, cleanup was neglected, and the poster did not want to move beyond a 2 TB iCloud plan.
- They were worried about relying on one Apple account and designed a system using a NAS as the archive source of truth, iCloud for devices, optional Lightroom for DSLR ingestion, and multiple cloud backups.
- They disclosed an open-source culling application named Daddy, Cull.

### Comment signal

- Another user approaching the 2 TB limit described archiving part of the library, considering Immich and `icloudpd`, and worrying that another cloud provider would receive dates, metadata, and location history.
- The poster emphasized vendor independence and multiple backup destinations.

### Product inference for Photo Earth

- Photo Earth's 50,000-photo design target is realistic rather than theoretical. Startup must remain summary-first, scanning must remain metadata-only, and large-library status must be explicit.
- Users with mature archives may have multiple copies and providers. Photo Earth should continue treating the authorized PhotoKit library as its sole fact source and avoid implying that it backs up or reconciles originals.
- The emotional opportunity is strong: after users do the hard work of culling and protecting an archive, a private television experience can make the archive worth revisiting. That value depends on speed and trust, not more library-management complexity.

### Competitors or alternatives

- NAS/Unraid, Immich, `icloudpd`, Lightroom, Dropbox, Google Drive, Amazon Photos, and the poster's Daddy, Cull tool.

### Unverified

- The architecture, costs, data integrity, and disaster-recovery properties were not independently audited.
- Vendor statements about storage and privacy were not checked today.

### Next validation

- Run Photo Earth against a 50,000-item synthetic index and a partially available iCloud library, measuring launch memory, scan duration, pagination, and cancellation.
- Keep all location analysis on device and make the distinction between derived index, source library, and backup explicit in onboarding and settings.
- Interview users with NAS or self-hosted archives about whether they will still keep an iCloud Photos subset for Apple TV viewing.

## Comment activity

No comment was published. The family-album automation thread needs current API verification before giving a definitive answer; the party-game thread was primarily product promotion and pricing discussion; the 60,000-item workflow already had active, informed responses. I did not add a low-value or repetitive comment.
