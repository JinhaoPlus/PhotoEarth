# Reddit research — 2026-09-21

## Account and interaction check

- Account: `u/Evening-Focus3876`.
- Verified total: **4 post karma and 8 comment karma**, unchanged from the previous daily check.
- Reddit showed no unread mail. No new direct reply was visible on the profile during this run.
- The Smart Albums comment remains the only recent comment with a directly verifiable external upvote: **2 points**. Other recent comments checked remain at the author's default 1 point, so no external vote is claimed for them.
- No comment, vote, private message, or post was submitted in this run. Two relevant reply drafts are recorded below; public submission requires action-time confirmation in the browser.

## Browsed themes

- `r/appletv/new`: advertising in the Apple TV interface, remote connection reliability, a new LAN-based tvOS DVR, legacy Apple TV sign-in, frame-rate behavior, remote redesign, play history, and recurring heat/update failures.
- `r/ApplePhotos/new`: batch resizing, Shared Albums, selective iCloud backup, photo cleanup, filename automation, ambient photo walls, and the difficulty of turning a large library back into meaningful memories.
- Existing comment scores and account Karma were checked before selecting discussion candidates.

## Prepared comment — experiences across repeated places

**Thread:** [I have 20,000 photos in Apple Photos, but somehow they feel less like memories over time](https://old.reddit.com/r/ApplePhotos/comments/1wjtefx/i_have_20000_photos_in_apple_photos_but_somehow/)

**Why it adds value:** The author distinguishes a static album from connections across repeated visits and wants prompts that recover personal meaning. Existing comments debate albums and AI-written posts, but none asks how grouping errors should be corrected or suggests testing the experience as a shared living-room moment.

**English final draft:**

> The repeated-place idea feels more distinctive than automatically making another album. I would test the smallest version as: show the same place across several years, explain why those photos were grouped, and ask one specific question such as “What kept bringing you back here?” The important control would be letting someone correct or dismiss a grouping before any story is generated; one wrong person or place could break trust quickly. I’d also be curious whether people want to answer privately on a phone but revisit the finished sequence together on a TV, because those may be two different parts of the experience.

**Status:** Draft only. Not entered into Reddit.

## Research evidence

### 1. Users distinguish retrieval from reconstructing an experience

**Source:** [20,000 photos feel less like memories](https://old.reddit.com/r/ApplePhotos/comments/1wjtefx/i_have_20000_photos_in_apple_photos_but_somehow/)

- **Original-post facts:** The author has almost 20,000 photos and says Apple Photos is good at finding a known person, date, or place, but poor at revealing experiences when the user does not know what to search for. They are building an iPhone app called Seen.
- **Comment signals:** The author says 80 photos from a weekend should feel like one experience and repeated visits to the same place should connect across years. A commenter pointed to Curator as a substitute for suggested albums; the author answered that albums already solve grouping, while their desired value is prompting the user to explain personal meaning.
- **Product inference:** Photo Earth's stronger job is not merely map search or automatic albums. A globe-to-place-to-time sequence can make repeated visits visible, while explanations and confidence controls preserve trust. Private reflection may belong on iPhone; communal playback may belong on Apple TV.
- **Competitors or substitutes:** Seen, Curator, Apple Photos Memories and albums, printed photo books.
- **Unverified:** The thread is itself developer research, has 0 points, and does not establish demand for a tvOS experience. The proposed AI-generated fantasy stories received no positive user validation in the thread.
- **Next validation:** Ask users whether repeated-place sequences, chronological trip stories, or ambient playback cause them to stop and watch with others; test how much correction is needed when visits are grouped incorrectly.

### 2. A tvOS DVR competes on reliability and continuity, not discovery

**Source:** [Mimir — a new tvOS app seeking feedback](https://old.reddit.com/r/appletv/comments/1wlvdb7/mimir_a_new_tvos_app_seeking_feedback/)

- **Original-post facts:** Mimir uses a tvOS client plus a local LAN server to record M3U/XMLTV or HDHomeRun streams. The developer says existing Emby, Plex, NextPVR, and Channels DVR workflows failed on interrupted streams or produced unplayable recordings. It supports cross-TV/mobile resume and playback of in-progress recordings.
- **Comment signal:** The post had 0 points, 40% upvoted, and no substantive comments at the time checked.
- **Product inference:** Apple TV side projects can win by making a fragile home-media workflow reliable and visible. Cross-device continuity is part of the value, but requiring a local server raises setup and support costs.
- **Competitors or substitutes:** Emby, Plex, NextPVR, Channels DVR, HDHomeRun apps.
- **Unverified:** The post supplies the developer's claims only; recording reliability, demand, and willingness to maintain a server were not independently verified.
- **Next validation:** Look for user-authored complaints about interrupted recordings and setup complexity before treating this as a market opportunity.

### 3. Remote connection and remote-app redesign remain recurring pain, but are crowded

- **Original-post facts:** Today's newest page contained separate threads about remote connection failures and a demand for a complete remote-app redesign.
- **Comment signal:** The connection thread had four comments within its first hour; the redesign thread had eight comments after roughly 19 hours.
- **Product inference:** Remote reliability and navigation create discussion, but an independent tvOS app cannot repair Apple's system remote stack. A companion remote utility would face platform restrictions and heavy competition.
- **Competitors or substitutes:** Apple's physical Siri Remote, Control Center remote, HDMI-CEC, third-party hardware remotes.
- **Unverified:** The posts were not followed to a confirmed root cause, and comment count alone does not establish unmet willingness to pay.
- **Next validation:** Track user-authored requests that are feasible through public APIs, such as household launchers, shared queues, or app-specific companion controls.

## Side-project direction update

The strongest product signal today is **shared memory reconstruction across repeated places and years**. It supports Photo Earth's existing emotional direction more than a generic photo wall does. The useful design split is private correction/reflection on a phone and cinematic shared playback on Apple TV. LAN DVR reliability is a separate side-project category worth monitoring, but today's developer post is not enough evidence to prioritize it.
