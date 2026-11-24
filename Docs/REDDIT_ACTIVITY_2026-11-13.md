# Reddit research — 2026-11-13 (Asia/Shanghai)

## Scope and account state

- Used the logged-in Chrome account to inspect r/appletv's newest feed and current rules, search recent photo/screensaver posts, read the complete visible FamPad and iProTV discussions, revisit our Apple TV photo-map post, and inspect notifications and the profile.
- Research stayed within Apple TV / Photo Earth. LensPin, camera geotagging, GPS/GPX/EXIF workflows, and the excluded photography communities were not researched. Unrelated notifications were only checked to avoid falsely attributing account-wide Karma changes.
- The profile showed **556 total Karma**, a net change of **+1** from the verified 555 snapshot on 2026-11-12. No Apple TV / Photo Earth-specific upvote or reply notification was visible, so the change cannot be attributed to this research line.

## Signal 1 — a shared family display combines planning, photos, ambience, and phone-side configuration

[I built a free Skylight-style family calendar that runs on my Apple TV, iPad and iPhone](https://www.reddit.com/r/appletv/comments/1xuhitc/i_built_a_free_skylightstyle_family_calendar_that/)

### Original post facts

- FamPad was built as a software alternative to a dedicated Skylight-style wall calendar. The author wanted the same household information on Apple TV, iPad, and iPhone rather than buying a single-purpose display.
- On Apple TV it offers day, week, and month views controlled with the Siri Remote. After inactivity it becomes a photo frame showing a clock, the next event, and dinner information; it also dims overnight.
- Photo selection, ordering, weather visibility, and dimming hours are configured on iPhone. The TV pairs with a one-time code and does not require account entry on the television.
- The author described the app as free, without ads or trackers. Search results showed **20 votes and 18 comments** at inspection.

### Comment signals

- Three users independently said they had been looking for something like it or intended to try it. This is stronger than a single launch-post compliment, but still does not establish continued use.
- Multiple users immediately asked for UK or EU availability. The developer expanded availability during the discussion.
- One UK user reported that weather location search failed or went blank. The developer said the issue was later resolved.
- A commenter challenged why a free app collects user content. The developer explained that calendar, photo, and chore data are stored on a server to sync devices, said the data is not used for ads or shared, and pointed to account deletion and a privacy page.
- Another commenter asked for an open-source, self-hostable Docker version. That is a direct signal that some household-display users value data ownership enough to request a more complex deployment model.

### Product inference

- Apple TV can serve as a **shared household surface** rather than only a media player. The strongest product shape is not a calendar alone: it switches between an active planning view and a passive photo/ambient view depending on whether anyone is interacting.
- Phone-side configuration is an important division of labor. The TV remains glanceable and remote-friendly while detailed setup, content selection, and scheduling happen on a touch device.
- For Photo Earth, this supports testing an optional passive state that preserves emotional photo value while exposing only a small amount of household-relevant context. It does **not** justify adding calendar or chore management to the product.
- Privacy expectations become sharper when family photos and household schedules are combined. Photo Earth's PhotoKit-only, on-device indexing is a meaningful differentiator, but it must be explained plainly rather than assumed to be understood.

### Competitors or alternatives

- FamPad competes for passive family-display time and personal-photo presentation, but its primary job is household coordination rather than travel-memory exploration.
- Dedicated Skylight displays, shared calendar apps, Apple's photo screensaver, and always-on dashboard apps are alternatives.

### Unverified / next validation

- The app was not installed or tested. Pairing time, photo quality, sync reliability, dimming behavior, and privacy implementation remain developer claims.
- The discussion does not reveal whether photos come from iCloud Photos directly or are uploaded into FamPad's own service, beyond the developer saying photos live on a server for sync.
- Validate whether Photo Earth users want any persistent clock or event context during passive playback; such information may weaken the product's cinematic, memory-first experience.

## Signal 2 — HomeKit scenes can turn media playback into a room-level experience

[iProTV 3.6.0 is out and it brings HomeKit support for Apple TV](https://www.reddit.com/r/appletv/comments/1xum9mw/iprotv_360_is_out_and_it_brings_homekit_support/)

### Original post facts

- iProTV 3.6 added a Cinema Mode that can trigger Home scenes when video starts, pauses, or ends. Users define the scenes in Apple's Home app; a manual button is also available.
- Its sleep timer can stop at a chosen time or at the end of the current program and can run a Home scene afterward.
- Search results showed **1 vote and 2 comments**. The sole visible user request was for the App Store link, which the developer supplied.

### Comment signals

- No visible user comment validated the HomeKit feature itself, requested a specific automation, or reported actual use.

### Product inference

- This is competitor evidence that a tvOS app can treat playback as a trigger for the physical room, not evidence of demand.
- A future Photo Earth experiment could explore user-created Home scenes for a deliberate “begin the journey / end the evening” ritual, but this is lower priority than the core globe and photo experience and would need platform-capability verification.

### Competitors or alternatives

- Apple's Home app automations, Shortcuts, HDMI-CEC behavior, and media apps with sleep timers cover parts of the workflow.

### Unverified / next validation

- iProTV was not tested. The exact HomeKit permissions, automation reliability, background behavior, and tvOS limitations remain unverified.
- Seek independent user reports before treating room-scene integration as a meaningful Photo Earth opportunity.

## Photo-specific follow-up

- The FamPad post was the only new photo-adjacent thread surfaced in the recent r/appletv photo/screensaver search. Older Floor796, Salon, Overlook, quiet-photo-frame, and screensaver-reliability threads were unchanged evidence already recorded in earlier daily notes.
- Our [Apple TV photo-map recommendation post](https://www.reddit.com/r/appletv/comments/1x95zy2/what_do_you_use_to_browse_your_icloud_photos_on_a/) still showed **1 displayed score, 1 comment, and 6.2K views** with no new reply. The displayed score is not a reliable count of independent upvotes, and views are not product demand.

## Public activity and skipped actions

- No comment, vote, post, private message, chat, follow, join, or other account action was performed.
- FamPad already had substantive discussion about regional availability, weather setup, server-side data collection, and self-hosting. Repeating those questions would not add value, and the app was not tested.
- The iProTV thread contained only a link request and no unresolved user problem that could be answered reliably without testing the app.
- No fresh low-reply Photo Earth-relevant support question met the threshold for a useful, nonduplicative comment.

