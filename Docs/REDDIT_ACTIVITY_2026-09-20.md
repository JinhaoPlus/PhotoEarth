# Reddit research — 2026-09-20

## Account and interaction check

- Account: `u/Evening-Focus3876`.
- Verified total: **4 post karma and 8 comment karma**, unchanged from the previous daily check.
- Yesterday's AirPlay troubleshooting comment remains public at 1 point: https://old.reddit.com/r/appletv/comments/1wk8duu/airplay_doesnt_work_on_iphone_but_ipad/paoyllt/. Because 1 is the author's default score, no external upvote is claimed. The thread still has only that one comment.
- One new direct reply was verified in the Smart Albums discussion. The author said they use several compound Smart Albums, primarily based on keywords; the value is automatic ongoing collection, such as all photos tagged `dog`, rather than repeating searches: https://old.reddit.com/r/ApplePhotos/comments/1wgo2ep/smart_albums/papxqin/
- No comment, vote, private message, or post was submitted in this run. One Apple TV support comment is ready but requires action-time confirmation before it can be submitted through the browser.

## Browsed themes

- `r/appletv/new`: heat-related lag on a 2022 Apple TV, remote volume control, tvOS 27 audio routing, purchased-content visibility, 4K/HDR streaming behavior, and update failures.
- `r/ApplePhotos/new`: slow thumbnail loading, high-quality media download errors, external-drive transfer, cleanup apps, filename automation, photo-wall rediscovery products, Smart Albums, and large-library memory browsing.
- Existing replies, recent comment scores, and total Karma were checked first.

## Prepared comment — hot Apple TV lagging

**Thread:** [Apple TV 2022 got to the point where it’s visibly lagging. What can I do?](https://old.reddit.com/r/appletv/comments/1wl0cpm/apple_tv_2022_got_to_the_point_where_its_visibly/)

**Why it adds value:** Existing replies asked when the device was rebooted, the climate, ambient temperature, and proximity to heat sources. The draft adds a bounded isolation sequence and distinguishes enclosure/airflow, one-app load, and recurring thermal behavior across apps.

**English final draft:**

> If it is actually hot enough to throttle, I’d treat airflow as the first variable: power it off, let it cool completely, then test it in open air rather than inside a cabinet or sitting on another warm device. Try the same app and then a different app. If only one app makes it heat up and lag, update or reinstall that app; if the whole interface slows down again across apps while the Apple TV is in open air, note the room temperature and contact Apple Support. A 2022 model should not need a factory reset just because the UI has started lagging, and resetting it before isolating the heat source would erase useful evidence.

**Status:** Draft only. The browser submission was not performed.

## Research evidence

### 1. Smart Albums are valued as persistent automation, especially for keywords

**Source:** [Smart Albums?? — direct reply](https://old.reddit.com/r/ApplePhotos/comments/1wgo2ep/smart_albums/papxqin/)

- **Original-post facts:** The discussion concerns the absence of Mac-style Smart Albums from iPhone and iPad.
- **Comment signal:** The author relies on multiple combined rules, but keywords are primary. Their example is an album that continuously gathers every photo tagged `dog`, saving them from repeating the same search.
- **Product inference:** A tvOS photo experience could treat saved dynamic collections as first-class sources for slideshows or passive displays. The underlying job is a collection that stays current without maintenance, rather than a one-time search result.
- **Competitors or substitutes:** Mac Photos Smart Albums, repeated Photos search, manual albums, third-party dynamic-album tools.
- **Unverified:** The reply does not establish demand for Apple TV playback specifically, and Photos' public APIs may limit access to Mac-only keywords or Smart Album definitions.
- **Next validation:** Determine which rules are visible through PhotoKit and whether users would accept re-creating a small subset of dynamic rules inside a tvOS/iOS companion.

### 2. Everflow competes for ambient rediscovery rather than map exploration

**Source:** [I got tired of my photos just sitting in a grid, so I built this](https://old.reddit.com/r/ApplePhotos/comments/1wkl0y0/)

- **Original-post facts:** The developer describes Everflow, which turns a photo library into a continuously moving photo wall with adjustable layout and speed, music, external-display support, and individual photos in 3D. The motivating use is leaving forgotten photos moving on another display while editing.
- **Comment signal:** The cross-post had no comments and 0 points at the time checked.
- **Product inference:** Ambient rediscovery is a distinct product category. Photo Earth's defensible difference should be spatial and narrative context—places, visits, repeated destinations, and movement from globe to memory—rather than merely animating a grid.
- **Competitors or substitutes:** Everflow, Apple Photos slideshows/Memories, screensavers, digital photo frames.
- **Unverified:** The post gives no evidence about Apple TV availability, library scale, privacy architecture, or user adoption.
- **Next validation:** Compare user preference for ambient wall, automatic trip playback, and interactive map exploration; test whether music and passive continuous movement should appear only in a dedicated mode.

### 3. Thermal troubleshooting exposes a small but recurring diagnostics job

**Source:** [Apple TV 2022 got to the point where it’s visibly lagging](https://old.reddit.com/r/appletv/comments/1wl0cpm/apple_tv_2022_got_to_the_point_where_its_visibly/)

- **Original-post facts:** The author clarified that the Apple TV becomes hot enough that the interface visibly lags. They had unplugged it a few weeks earlier.
- **Comment signals:** Replies asked about rebooting, climate, ambient temperature, placement, and nearby heat sources.
- **Product inference:** This reinforces the possible Apple TV diagnostics assistant direction: ask a short sequence, distinguish device-wide from app-specific failure, and produce a shareable support summary. Thermal, storage, network, HDMI, and audio cases could use the same structure.
- **Competitors or substitutes:** Reddit troubleshooting, Apple Support, generic device checklists.
- **Unverified:** No root cause or resolution has been posted, and a single thermal report does not justify a product.
- **Next validation:** Track the eventual resolution and look for repeated requests where users cannot tell whether the problem belongs to tvOS, one app, HDMI/network equipment, or hardware.

## Side-project direction update

Today's clearest addition is **dynamic living-room collections**: persistent keyword/person/place rules that automatically feed a slideshow or screensaver. Everflow confirms interest in ambient rediscovery but also makes a generic moving photo wall less differentiated. Photo Earth should keep the map, inferred visits, and emotional trip narrative as its core advantage. The Apple TV diagnostics assistant remains a secondary idea that needs several resolved cases before implementation.
