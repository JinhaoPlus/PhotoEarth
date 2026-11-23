# Photo Earth App Icon — V1

## 状态

这是用于方向评审的首版扁平母图，尚未覆盖 Xcode 里的三层 tvOS App Icon 资源。确认视觉方向后，再将画面拆分为 Back（深空）、Middle（地球）和 Front（旅行光点）三层，制作系统聚焦视差效果。

## 输出

- `PhotoEarth-AppIcon-v1-source.png`：Imagegen 原始输出，1619 × 971
- `PhotoEarth-AppIcon-v1-1280x768.png`：tvOS App Store 图标评审尺寸
- `PhotoEarth-AppIcon-v1-800x480.png`：tvOS 2x 图标评审尺寸
- `PhotoEarth-AppIcon-v1-400x240.png`：tvOS 1x 图标评审尺寸

## 生成方式

使用 Codex 内置 Imagegen，根据用户提供的两张图片进行全新生成。图片 1 只作为近轨道构图、深空与蓝色大气边缘的氛围参考；图片 2 只作为稀疏旅行记忆光点与亚太地理范围的概念参考，不直接修改或复制原图。

## Final prompt

```text
Use case: logo-brand
Asset type: premium Apple TV app icon master artwork for “Photo Earth”, landscape 5:3 composition intended to be cropped/exported at 1280 × 768 and 400 × 240.
Input images: Image 1 is a composition and mood reference for the enormous near-orbit curved Earth horizon, deep space, electric-blue atmosphere, cinematic scale; Image 2 is a concept reference for sparse glowing travel-memory locations across recognizable geography. Do not copy either image literally.
Primary request: create a breathtaking, emotionally resonant icon showing a monumental partial Earth from very low orbit, as if the viewer is just above the planet and seeing their personal journeys awaken across its surface.
Scene/backdrop: almost-black deep space with only a few extremely subtle stars; no nebula, no decorative space clutter.
Subject: a large photorealistic Earth fills roughly the lower 78–85% of the frame and extends beyond the left, right, and bottom edges. Its curved horizon arcs across the upper third. Show recognizable Asia-Pacific geography at night/twilight, with rich satellite land and ocean texture, restrained cloud detail, and a thin luminous cobalt/cyan atmospheric rim. Place about 12–16 sparse, soft blue-white travel-memory lights on the visible land, varied subtly in size and intensity, clustered naturally around East Asia, Southeast Asia, Japan, and Australia. Each point is a compact luminous pearl with a gentle halo, not a map pin, not a ring.
Style/medium: premium cinematic photorealistic space photography fused with refined Apple-platform icon art; iconic, simplified hierarchy that remains legible from across a room; high dynamic range but elegant, not game art.
Composition/framing: strong centered arc and bold silhouette; Earth is the unmistakable hero. Keep the brightest horizon and all important travel lights at least 8% inside the canvas so Apple TV focus/parallax cropping remains safe. Full-bleed rectangular artwork; no baked-in rounded corners, border, frame, bevel, or drop shadow.
Lighting/mood: awe, intimacy, nostalgia, quiet wonder; luminous electric blue edge light against velvety black; travel points feel like memories, not city pollution.
Color palette: midnight black, deep ocean navy, natural dark greens and earth browns, saturated cobalt and cyan highlights, tiny neutral blue-white lights.
Text: none.
Constraints: one Earth only; accurate believable spherical curvature; the travel lights must be visible at small icon size without overwhelming the continents; clean silhouette and strong contrast; no transparency required.
Avoid: all words or letters, logos, camera symbols, photo frames, people, satellites, spacecraft, moon, sun, aurora, lens flare streaks, orbit lines, route lines, network connections, map pins, pulsing rings, dense city-light carpet, excessive stars, fantasy planets, cartoon style, UI overlays, watermark.
```
