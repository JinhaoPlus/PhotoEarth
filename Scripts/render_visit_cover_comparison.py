#!/usr/bin/env python3
"""Render a local three-way visit cover experiment, from its exported results.json."""

import argparse
import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps


SCHEMES = ("baseline", "sampling", "bonus")
SCHEME_NAMES = ("A · 现行算法", "B · 密度采样", "C · 密度采样与加分")


def contact_sheet(root, visit):
    """Show actual proportions and which candidate(s) won each treatment."""
    rows = [(photo, scheme) for scheme, photo in zip(SCHEME_NAMES, (visit[k] for k in SCHEMES))]
    rows += [(photo, "") for photo in visit["candidates"]]
    width, height, columns = 248, 220, 3
    canvas = Image.new("RGB", (columns * width, 95 + math.ceil(len(rows) / columns) * height), "#171917")
    draw = ImageDraw.Draw(canvas)
    font_path = "/System/Library/Fonts/STHeiti Medium.ttc"
    heading = ImageFont.truetype(font_path, 24)
    caption = ImageFont.truetype(font_path, 15)
    draw.text((14, 11), f"{visit['city']} · 三版封面与候选", font=heading, fill="#f1f0e9")
    draw.text((14, 53), f"{visit['date']} 至 {visit['end']} · {visit['count']} 项素材 · B/C 实评 {len(visit['candidates'])} 张",
              font=caption, fill="#b9beb7")
    for index, (photo, scheme) in enumerate(rows):
        x, y = index % columns * width, 89 + index // columns * height
        if photo.get("img"):
            with Image.open(root / photo["img"]) as im:
                fit = ImageOps.contain(ImageOps.exif_transpose(im).convert("RGB"), (width - 12, 156))
            canvas.paste(fit, (x + (width - fit.width) // 2, y + (156 - fit.height) // 2))
        else:
            draw.text((x + 12, y + 65), "本机缺图", font=caption, fill="#bdc1bb")
        draw.text((x + 7, y + 164), photo.get("filename") or "无文件名", font=caption, fill="#eeeee8")
        winners = " / ".join(s[0] for s, k in zip(SCHEME_NAMES, SCHEMES) if photo.get("id") and photo["id"] == visit[k].get("id"))
        label = scheme or (f"候选 {index - 2} · {winners} 选中" if winners else f"候选 {index - 2}")
        draw.text((x + 7, y + 186), label, font=caption, fill="#b9cdbb")
    filename = f"granada-{visit['n']}.jpg"
    canvas.save(root / filename, quality=90, optimize=True)
    return filename


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path, help="Exported private experiment results.json")
    args = parser.parse_args()
    root = args.results.parent
    visits = json.loads(args.results.read_text())["visits"]
    if len(visits) != len({v["n"] for v in visits}):
        raise ValueError("Duplicate visit numbers")
    cards = []
    for visit in visits:
        card = {key: visit[key] for key in ("n", "city", "country", "date", "end", "count")}
        card["photos"] = []
        for key in SCHEMES:
            photo = visit[key]
            if photo["reason"] not in {"scored", "fallback", "unavailable"}:
                raise ValueError(f"Unknown cover outcome for visit {visit['n']} in {key}")
            if photo.get("img") and not (root / photo["img"]).is_file():
                raise FileNotFoundError(root / photo["img"])
            card["photos"].append({k: photo.get(k) for k in ("img", "filename", "ts", "reason")})
        ids = [visit[k].get("id") for k in SCHEMES]
        card["ab"], card["bc"], card["ac"] = ids[0] != ids[1], ids[1] != ids[2], ids[0] != ids[2]
        if card["city"].casefold() in {"granada", "格拉纳达"}:
            card["sheet"] = contact_sheet(root, visit)
            panorama = next((photo for photo in visit["candidates"] if photo.get("filename") == "DSCF2280.JPG"), None)
            diagnostic = root / "granada-diagnostics.json"
            if panorama and diagnostic.is_file():
                details = json.loads(diagnostic.read_text()).get(panorama["filename"])
                if details and details["id"] == panorama["id"]:
                    card["panorama"] = {"img": panorama["img"], "filename": panorama["filename"],
                                        "old": details["inOld"], "new": details["inNew"],
                                        "strength": details["strength"], "tier": details["tier"]}
        cards.append(card)
    cards.sort(key=lambda c: c["n"])
    template = Path(__file__).with_name("visit_cover_comparison.html").read_text()
    embedded = json.dumps(cards, ensure_ascii=False, separators=(",", ":")).replace("<", r"\u003c")
    (root / "index.html").write_text(template.replace("/*VISITS*/", embedded))


if __name__ == "__main__":
    main()
