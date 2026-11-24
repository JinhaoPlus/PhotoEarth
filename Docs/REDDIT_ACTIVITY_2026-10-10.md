# Reddit activity — 2026-10-10

## Run status

The authenticated Chrome session was available. I reviewed current r/appletv and r/ApplePhotos discussions, their existing comments, the live notification inbox, and the account profile. The profile remains at **13 total Karma: 4 post Karma and 9 comment Karma**.

Reddit showed one new external upvote notification on the account's profile post, [Add locations to camera photos in Apple Photos—for free, for a limited time](https://www.reddit.com/r/u_Evening-Focus3876/comments/1x1aeag/add_locations_to_camera_photos_in_apple_photosfor/), 18 hours before review. The notification proves at least one external upvote event; it does not identify the voter or prove that the point remains attached to the post. A separate new reply in r/ApplePhotos is recorded below.

No comment was published. The strongest current threads already contained the same practical answers I could responsibly provide, so another reply would have repeated existing advice.

## Signal 1 — Multi-Apple-TV households want a room-pinned, reliable iPhone remote

Source: [Controlling an AppleTV (the device, not the streaming service) with an iPhone is an absolutely miserable experience](https://www.reddit.com/r/appletv/comments/1x1zz12/controlling_an_appletv_the_device_not_the/)

### Original-post facts

- The household has two Apple TVs, one in the living room and one in the bedroom, and both adults use iPhones.
- The poster described repeatedly opening Control Center, opening Remote, correcting the guessed Apple TV, and waiting for an unreliable connection after the phone sleeps.
- They want a quick way to skip ads or change a show and said they would pay a small amount for a better third-party experience.
- Their physical remotes are frequently lost because they are small and slim.
- At review time the thread showed 32 comments; the displayed score was 0, so the discussion volume should not be interpreted as broad approval.

### Comment signal

- Multiple commenters recommended assigning Apple's Remote to the iPhone Action Button or creating one Shortcut per Apple TV with “Show remote control for [device]”, then placing the shortcuts in Control Center or on the Home Screen.
- itsyTV was recommended as a paid alternative; commenters described one-time pricing and Family Sharing, but those current commercial details were not independently verified today.
- Other commenters recommended replacement or universal remotes, larger cases, and AirTag attachments.
- Experiences with iOS 27 differed: some said a dedicated Remote app or Live Activity made reconnection easier, while the poster and another commenter said Control Center behavior became worse after upgrading.

### Product inference

- The unmet job is not a novel remote-control layout. It is reliable **device binding and re-entry**: one tap should open the intended room's Apple TV and remain useful after the phone locks.
- A possible side project is a small iPhone companion that exposes clearly named living-room and bedroom launchers, remembers the last valid device, explains connection state, and supports household sharing with a one-time purchase.
- This idea has stronger discussion evidence than most recent tvOS utility requests and includes explicit willingness to pay, but it may be blocked by Apple's public APIs. A shortcut wrapper without better connection reliability would add little value.

### Competitors or alternatives

- Apple's Control Center Remote, dedicated Remote app behavior, Action Button, Live Activities, and Shortcuts.
- itsyTV.
- Replacement and universal physical remotes, cases, and AirTag attachments.

### Unverified

- I did not install or test itsyTV.
- I did not verify whether public iOS/tvOS APIs allow a third-party app to bind to a specific Apple TV, wake it, reconnect reliably, and expose transport controls outside the app.
- The iOS 27 reports are user observations from one thread and conflict with each other.

### Next validation

- Verify the current public APIs and App Store policy before treating the idea as feasible.
- Interview multi-device households about the exact failure point: wrong device selection, discovery delay, authentication, wake, lock-screen return, or lost physical remote.
- Compare a named per-room Shortcut with itsyTV and Apple's Remote on two Apple TVs across phone lock/unlock cycles. If the shortcut already solves the problem reliably, do not build a standalone product.

## Signal 2 — Large iCloud libraries need a verifiable inventory, not just a sync indicator

Source: [How to get a list of photos stored in iCloud?](https://www.reddit.com/r/ApplePhotos/comments/1x20jaf/how_to_get_a_list_of_photos_stored_in_icloud/)

### Original-post facts

- The poster transferred about 50,000 old photos from a Windows PC using iCloud for Windows and knows that some are missing.
- They want a filename and capture-date inventory of the photos actually present in iCloud, so they can find time gaps and compare it with the Windows file list.
- Their iCloud library is synced to the iPhone.

### Comment signal

- One commenter suggested `icloud-photos-downloader` and thought a dry-run mode might produce a file list; that exact behavior was not verified.
- Another suggested copying the library to USB and comparing it with the source, possibly by checksum, and said the workflow would be easier with a Mac.

### Product inference for Photo Earth

- A travel-photo experience must distinguish “no travel photos exist” from “the accessible PhotoKit library is currently incomplete.” A suddenly lower asset count should not silently replace a healthy last-known index.
- Index status should expose the last complete scan count, current accessible count, and whether rebuilding is waiting on iCloud availability. This is especially important for large libraries where silent omissions can erase remembered destinations from the globe.
- Photo Earth should remain a derived viewer, not become a general cloud-backup verifier. The relevant scope is resilient indexing and honest incomplete-library status.

### Competitors or alternatives

- `icloud-photos-downloader`, manual USB export, source-file lists, and checksum comparison.

### Unverified

- The missing items may result from iCloud for Windows, upload state, unsupported files, duplicates, or a comparison error; the thread does not establish the cause.
- I did not verify the suggested command-line tool's current dry-run output or its ability to preserve every iCloud Photos variant.

### Next validation

- Test Photo Earth's index behavior while a large iCloud library is still downloading and after Photo access becomes temporarily limited.
- Add a last-known-good guard: do not replace a complete index with a sharply reduced snapshot until the app can explain the library state or complete a later verification pass.
- Show truthful counts and timestamps without implying that Photo Earth audits or backs up original files.

## Existing interaction check

- A new r/ApplePhotos reply from `u/Photo_Froggy` appeared 16 hours before review on [Transfering alot of Photos is NOT User Friendly](https://www.reddit.com/r/ApplePhotos/comments/1wfdscg/comment/peszo8r/?context=1). The developer disclosed their affiliation and described PhotoFroggy as a Windows USB-transfer tool that reports copied and failed items and only deletes phone items after byte-for-byte verification on the PC.
- This is a useful competitor signal for verifiable handoff and deletion safety. It is a product claim from the developer; the application was not tested today.
- No reply was posted. The new message is promotional but relevant, and it does not ask a question that requires an answer.

## Comment activity

No comment was published. The Apple TV remote thread already contained Action Button, Shortcuts, dedicated-app, third-party-app, and hardware solutions. The iCloud inventory thread already contained the practical tool and export/checksum approaches. Repeating them would not add enough value.
