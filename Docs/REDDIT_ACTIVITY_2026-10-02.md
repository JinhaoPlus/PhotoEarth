# Reddit activity — 2026-10-02

## Run status

The Mac remained locked and the authenticated Chrome extension could not attach to Reddit. Public Reddit pages and search indexes were used for read-only research. No comment was published because the logged-in state, action-time rules/open-state check, and resulting permalink could not be verified.

The latest public profile page still returned **4 post Karma, 8 comment Karma, 12 total Karma, and 48 contributions**. Its crawl timestamp was one day old, so this is recorded as the latest visible snapshot rather than a live change. No inbox reply or per-comment external vote was directly verifiable.

Threads reviewed:

- [New Plex Experience on Apple TV. Where's the PHOTOS SUPPORT?!](https://www.reddit.com/r/PleX/comments/1ws6foe/new_plex_experience_on_apple_tv_wheres_the_photos/)
- Recent r/appletv posts and follow-ups
- [Looking for an app to upload my own files for offline viewing](https://www.reddit.com/r/appletv/comments/1wslj74/looking_for_an_app_to_upload_my_own_files_for/), rechecked for new answers

## Signal 1 — Plex removed Apple TV photo browsing and users immediately noticed

### Original-post facts

- The new Plex Apple TV experience removed access to photo libraries.
- The original poster tested the update remotely for a family member and advised photo and music users not to update.
- They explicitly said they do not require geographic browsing, random playback, or AI search; a simple timeline and folder view would satisfy the immediate need.
- Plex previously said photo functionality would return to its main app in the future, but commenters reported that music had returned while photos still had no announced return date.

### User signals from comments

- One commenter described themselves as the family's “digital historian,” maintaining family photos and videos on a server so relatives can view them.
- Another user said the upgrade made them think their storage move had broken the library path before they realized photo libraries were simply missing.
- Multiple users expressed strong frustration despite saying they do not use the photo feature frequently.
- A commenter asked again on 2026-09-30 when photo support would return, showing the gap remains active.

### Product inference

- Photo viewing can be a low-frequency but high-importance Apple TV job. Usage frequency alone will underestimate its value.
- The minimum trusted experience is simpler than Photo Earth's full vision: reliably expose the selected library, timeline, and folder/album structure.
- Advanced globe and trip features cannot compensate if users are unsure which library is active or cannot reach ordinary chronological browsing.
- “Family digital historian” is a useful target persona: one technically capable person curates access for less technical relatives.

### Competitors or substitutes

- The previous Plex Apple TV client remains the direct substitute while rollback is possible.
- Apple Photos, NAS/SMB slideshow apps, and newer apps such as Imagozo cover parts of the gap.
- A narrow tvOS side project could offer read-only Plex/NAS photo browsing with timeline and folders, but authentication, remote-server access, codecs, and library-scale indexing raise the cost well above a simple viewer.

### Unverified

- Plex's current product roadmap and whether photo support is already in beta were not verified from a first-party release note today.
- The number of affected Apple TV users cannot be inferred from one thread.
- No alternative was confirmed to preserve Plex permissions, remote-family sharing, and photo/video browsing together.

### Next validation

- Interview the “family historian” persona about account setup, remote relatives, source permissions, and whether family members need only browsing or also favorites/comments.
- Ensure Photo Earth always provides a plain chronological fallback and an explicit current-source indicator.
- Test update/migration behavior so a library never silently disappears after an app upgrade.

## Signal 2 — Busy interfaces and slow animation are explicit regression complaints

### Original-post facts

- The Plex poster described the redesigned interface as busier and less informative.
- They gave a concrete remote-navigation regression: reaching audio/subtitle controls now takes more directional presses.
- Another commenter said the new animations are too slow.

### User signals

- On television, visual polish is judged together with direction-key cost and information visibility.
- Users notice when a redesign makes routine actions take more presses, even if playback performance remains acceptable.

### Product inference

- Photo Earth's cinematic motion must not slow repeat actions or obscure state.
- Common paths—open timeline, select a source, return one level, resume playback—need a measurable remote-press budget.
- Motion should communicate the memory transition and remain interruptible; decorative delay will read as sluggishness.

### Competitor or substitute

- The old Plex client is the comparison point because users already learned its interaction paths.

### Unverified

- The exact old/new press counts were not independently reproduced on Apple TV hardware.

### Next validation

- Add remote-press and elapsed-time checks to the main Photo Earth flows, especially source selection, Back hierarchy, and slideshow controls.
- Test Reduce Motion and repeated navigation separately from first-view cinematic transitions.

## Comment and account activity

No comment was published. The Plex thread already contained the product-status explanation and concrete user complaints; there was no unanswered diagnostic question where another reply would add specific help. The locked Mac prevented authenticated action and permalink verification.
