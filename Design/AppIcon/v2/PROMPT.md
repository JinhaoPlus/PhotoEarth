# Photo Earth App Icon — V2

## 状态

这是以 V1 为编辑目标生成的欧洲构图版本。该版本已经配置到 Xcode 的 tvOS 三层图标资源：Back 为深空，Middle 为带透明轮廓的地球，Front 为旅行记忆光点。资源脚本会同时生成 400 × 240、800 × 480 和 1280 × 768 三种尺寸。

分层资源可以通过 `Scripts/generate_app_icon_layers.py` 从本目录的 1280 × 768 母图重新生成。

## 输出

- `PhotoEarth-AppIcon-v2-source.png`：Imagegen 原始输出，1619 × 971
- `PhotoEarth-AppIcon-v2-1280x768.png`：tvOS App Store 图标评审尺寸
- `PhotoEarth-AppIcon-v2-800x480.png`：tvOS 2x 图标评审尺寸
- `PhotoEarth-AppIcon-v2-400x240.png`：tvOS 1x 图标评审尺寸

## Final prompt

```text
Use case: precise-object-edit
Asset type: second visual-direction version of a premium Apple TV app icon, 5:3 landscape.
Input image: the supplied Photo Earth V1 artwork is the edit target.
Primary request: recompose the same concept so Europe is unmistakably the main visible region, and make the Earth’s curvature dramatically stronger and more awe-inspiring, like an astronaut seeing an enormous living planet immediately outside a spacecraft window.
Geography: center Western and Central Europe and the Mediterranean. Keep the British Isles, Iberian Peninsula, France, Italy, the Alps, Germany/Central Europe, Scandinavia, Balkans, Greece and Turkey recognizable; include the upper edge of North Africa and a portion of the North Atlantic as supporting context. Europe must occupy the emotional and visual center, not Asia or Australia.
Composition/framing: replace the shallow near-horizontal horizon with a bold, strongly convex planetary arc. The luminous limb should enter around the middle-left edge, rise close to the upper-center, and descend toward the middle-right edge, so the roundness of Earth is immediately felt. The planet remains monumental and fills about 80–88% of the frame, extending beyond the left, right, and bottom edges. Use an intimate ultra-wide astronaut-eye viewpoint with strong depth and scale, but do not show a literal window frame or spacecraft hardware. Preserve 5:3 full-bleed layout and keep important lights safely inset for tvOS focus/parallax cropping.
Travel-memory lights: relocate the sparse blue-white pearls to believable visited locations across Europe—roughly London, Paris, Lisbon, Madrid/Barcelona, Amsterdam, Berlin, Prague/Vienna, Rome, Athens, Istanbul, Copenhagen/Stockholm and one or two Alpine or Adriatic locations. Use only about 12–15 compact lights with varied subtle intensity and soft halos. No map pins, no rings, no route lines, no dense city-light carpet.
Lighting/mood: push the scene toward blue-hour/night-side orbit, with a razor-thin electric cobalt/cyan atmosphere against velvety black space, deep navy oceans, richly textured but restrained European terrain and clouds. The feeling is overwhelming scale, quiet wonder, intimacy and nostalgia—an astronaut’s breath-catching first sight, not a scientific map.
Invariants: retain the original V1’s photorealistic premium cinematic finish, dark blue palette, sparse stars, clean icon hierarchy, no text, and no baked-in rounded corners, border, bevel or drop shadow.
Change only: geographic focus, planet orientation/framing, curvature strength, and corresponding travel-light positions.
Avoid: Asia-Pacific as the focus, Australia, flat map view, weak/shallow horizon, fisheye distortion of landforms, literal porthole rim, cabin interior, reflections on glass, people, satellites, spacecraft, moon, sun, aurora, lens-flare streaks, city-light carpet, orbit or route lines, map pins, network graphics, logos, letters, UI, watermark, fantasy planet, cartoon or game-art style.
```
