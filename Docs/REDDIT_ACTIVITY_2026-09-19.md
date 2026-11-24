# Reddit research — 2026-09-19

## Account and interaction check

- Account: `u/Evening-Focus3876`.
- Verified total at the start of this run: **4 post karma, 8 comment karma**, unchanged from the prior recorded check.
- Two new direct replies were verified:
  - In the multi-device photo workflow thread, the author said the advice was helpful and clarified that the real difficulty is decision fatigue after editing and uncertainty about whether a clip will ever be used: https://old.reddit.com/r/ApplePhotos/comments/1whzhos/as_someone_who_likes_to_capture_memories_in/pajfhw1/
  - In the iOS geotagging thread, the author said treating RAW+JPEG as one shot would be a nice-to-have rather than a requirement, and that their older apps treated the pair as one shot: https://old.reddit.com/r/AskPhotography/comments/1vp0u90/geotagging_software_for_ios/paljogi/
- The two comments published on 2026-09-18 still show **1 point each**. This is not counted as external approval because Reddit gives an author's own comment a default score of 1.
- One comment was published after the user's confirmation. No vote, message, or post was submitted.

## Browsed themes

- `r/appletv/new`: AirPlay behavior differing between iPhone and iPad, tvOS 27 update failures, remote button failures, audio delay, color balance, Prime Video audio/playback problems, Wi-Fi failures, SMB playback apps, and home-video playback.
- `r/ApplePhotos/new`: large libraries becoming emotionally inaccessible, suggested experience/album grouping, keyword confusion, duplicate recovery, shared albums, photo cleanup and culling tools.
- Existing replies and the account profile were checked before selecting a new candidate.

## Comment candidate — AirPlay isolation test

**Thread:** [Airplay doesnt work on iphone but ipad....](https://old.reddit.com/r/appletv/comments/1wk8duu/airplay_doesnt_work_on_iphone_but_ipad/)

**Why it is worth replying:** The post had no comments when checked. The same OneDrive-hosted video works from the iPad but shows a black screen and error icon when sent from the iPhone, so a short isolation test can distinguish an iPhone/OneDrive playback-path problem from an Apple TV or file-codec problem without guessing.

**English final draft:**

> Since the exact same file AirPlays from the iPad, I’d first isolate OneDrive from AirPlay. On the iPhone, download one affected video locally, save a copy to Photos or Files, and AirPlay that local copy. If the local copy works, the Apple TV and codec are probably fine and the problem is the iPhone OneDrive app’s streaming path; compare the OneDrive app versions on both devices and then update or reinstall it. If the local copy also fails, restart the iPhone and Apple TV and confirm both are on the same Wi-Fi with any VPN temporarily off. That one test should narrow this down much faster than changing the Apple TV video format settings.

**Status:** Published and verified at https://old.reddit.com/r/appletv/comments/1wk8duu/airplay_doesnt_work_on_iphone_but_ipad/paoyllt/. The thread was still open and had no other comments at submission time. The displayed score was the author's default 1 point, so no external approval is claimed.

## Automation authorization update

The user explicitly authorized future runs of `r-appletv` to publish qualifying ordinary comments without per-run confirmation. The task still requires a final preflight check for relevance, community rules, an open thread, absence of an equivalent answer, and concrete value. New posts, votes, private messages, chat, following, and community membership remain outside this standing authorization.

## Research evidence

### 1. A large photo library can still fail as a memory experience

**Source:** [I have 20,000 photos in Apple Photos, but somehow they feel less like memories over time](https://old.reddit.com/r/ApplePhotos/comments/1wjtefx/i_have_20000_photos_in_apple_photos_but_somehow/)

- **Original-post facts:** The author has about 20,000 photos and says Apple Photos is good when they know the person, date, or place to search for. Their unmet question is exploratory: what they have forgotten, which photos form one experience, and which places recur across years. The author is building an iPhone app called Seen that groups photos into moments and places.
- **Comment signals:** One commenter challenged whether fewer photos would solve the problem. The author replied that 2,000 photos would be easier to browse but would still be individual photos; they want 20,000 photos to become roughly 500 experiences. Another commenter proposed suggested albums and named Curator as an alternative.
- **Product inference:** Photo Earth should treat an inferred visit or experience as the primary object and let the television reveal it, rather than presenting only a spatial grid. Repeated visits to the same place across years are a distinct emotional use case.
- **Competitors or substitutes:** Seen (early iPhone app), Curator, Apple Photos Memories and manually created albums.
- **Unverified:** The post is by a developer describing their own product, and the post score was 0 when checked. It is evidence for a problem formulation and competitive direction, not proof of broad demand.
- **Next validation:** Ask neutral users whether they prefer automatic experience clusters, repeated-place timelines, or a pure map; test whether television viewing adds enough value beyond an iPhone experience browser.

### 2. Plain SMB video playback is crowded and poorly differentiated

**Source:** [I built an Apple TV app for my videos on an SMB share](https://old.reddit.com/r/appletv/comments/1wj2lwq/i_built_an_apple_tv_app_for_my_videos_on_an_smb/)

- **Original-post facts:** The developer built a three-screen tvOS app to stream folders directly from SMB without a media server, priced at EUR 12.99. They explicitly omit a media library, online art, and subtitles.
- **Comment signals:** All four comments pointed to established substitutes: Infuse, Jellyfin, Plex, VLC, SenPlayer, and VidHub. The strongest comment questioning the need had 8 points; the post itself had 0 points and 31% upvoted when checked.
- **Product inference:** A generic SMB player is a weak side-project target. A viable living-room media product needs a sharper job such as family-memory curation, privacy-first guest viewing, instant event reels, or unusually low setup cost.
- **Competitors or substitutes:** Infuse, Jellyfin, Plex, VLC, SenPlayer, VidHub.
- **Unverified:** The discussion does not show whether nontechnical families would pay for a much simpler home-video-only experience; the commenters appear comfortable with existing media tools.
- **Next validation:** Look specifically for users who reject media servers or find metadata-heavy players unsuitable for family videos.

### 3. Device-dependent AirPlay failure remains a useful diagnostics niche

**Source:** [Airplay doesnt work on iphone but ipad....](https://old.reddit.com/r/appletv/comments/1wk8duu/airplay_doesnt_work_on_iphone_but_ipad/)

- **Original-post facts:** The same OneDrive videos work locally on both devices and AirPlay immediately from an older iPad, but fail from an iPhone 17 Pro Max with a black screen and error icon.
- **Comment signals:** None at the time checked.
- **Product inference:** A small Apple TV diagnostics companion could guide source-isolation tests across app streaming, local files, network, codec, and AirPlay route. The recurring value is a deterministic checklist and shareable diagnosis rather than another media player.
- **Competitors or substitutes:** Apple support steps, router troubleshooting, app reinstall, direct playback apps.
- **Unverified:** One report cannot establish frequency, and the root cause has not been confirmed.
- **Next validation:** Track whether the local-copy test resolves the issue and collect more cross-device AirPlay mismatch reports.

## Side-project direction update

The best new direction from today's material is an **experience-based family memory player**: automatically group a large photo library into visits, weekends, recurring places, and years, then provide a calm big-screen rediscovery flow. The direct SMB-player opportunity should be deprioritized because the thread immediately surfaced several mature substitutes. A smaller secondary idea is an **AirPlay diagnostics assistant**, but it needs repeated evidence before it deserves implementation work.
