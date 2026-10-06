#!/usr/bin/env python3
# downloads a real test set for --eval, usage: fetch_real_set.py <outdir>
# flowers from wikimedia commons "quality images of flowers" (1600 px), receipts from SROIE scans,
# resumes from MIT CAPD samples, _none is other commons photos, an arxiv paper and an irs form
import json, os, sys, time, urllib.request, urllib.parse

OUT = sys.argv[1]
UA = "DynamicIslandManager-eval/1.0 (local testing; contact via repo owner)"
sources = []

def get(url, path):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return True
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=60) as response, open(path, "wb") as f:
                f.write(response.read())
            return True
        except Exception as error:
            print("  retry", url, error)
            time.sleep(2)
    return False

def commons(category, count, folder, prefix=""):
    api = "https://commons.wikimedia.org/w/api.php?" + urllib.parse.urlencode({
        "action": "query", "generator": "categorymembers", "gcmtitle": category, "gcmtype": "file",
        "gcmlimit": 60, "prop": "imageinfo", "iiprop": "url|mime|extmetadata", "iiurlwidth": 1600, "format": "json"})
    request = urllib.request.Request(api, headers={"User-Agent": UA})
    pages = json.load(urllib.request.urlopen(request, timeout=60)).get("query", {}).get("pages", {})
    files = sorted((p for p in pages.values() if p.get("imageinfo") and p["imageinfo"][0]["mime"] == "image/jpeg"),
                   key=lambda p: p["title"])
    step = max(1, len(files) // count)
    picked = files[::step][:count]
    os.makedirs(os.path.join(OUT, folder), exist_ok=True)
    for page in picked:
        info = page["imageinfo"][0]
        name = prefix + page["title"][5:].replace("/", "_")
        if not name.lower().endswith((".jpg", ".jpeg")):
            name += ".jpg"
        license = info.get("extmetadata", {}).get("LicenseShortName", {}).get("value", "?")
        if get(info.get("thumburl") or info["url"], os.path.join(OUT, folder, name)):
            sources.append(f"{folder}/{name}\t{info['descriptionurl']}\t{license}")
    return len(picked)

def direct(url, folder, name, note):
    os.makedirs(os.path.join(OUT, folder), exist_ok=True)
    if get(url, os.path.join(OUT, folder, name)):
        sources.append(f"{folder}/{name}\t{url}\t{note}")

print("flowers", commons("Category:Quality_images_of_flowers", 12, "flowers"))
for index in ["002", "017", "033", "048", "061", "077", "090", "104", "119", "133", "148", "162"]:
    direct(f"https://raw.githubusercontent.com/zzzDavid/ICDAR-2019-SROIE/refs/heads/master/data/img/{index}.jpg",
           "receipts", f"IMG_{4100 + int(index)}.jpg", "SROIE 2019 scanned receipt (research dataset)")
mit = "https://cdn.uconnectlabs.com/wp-content/uploads/sites/123/2025/05/"
for name in ["FirstYearResume_MechEng-1.pdf", "MastersResume_Engineering.pdf", "MastersResume_PublicDevelopment-1.pdf",
             "MITCAPD-Alum-1.pdf", "MITCAPD-FirstYear-1.pdf", "MITCAPD-FirstYearII-1.pdf", "MITCAPD-GlobalResume.pdf",
             "MITCAPD-MastersI.pdf", "MITCAPD-MastersII.pdf", "MITCAPD-Undergraduate.pdf", "MITCAPD-UndergraduateII.pdf",
             "UG-Resume-with-Projects-1.pdf"]:
    direct(mit + name, "resumes", name, "MIT CAPD sample resume")
for category, count in [("Category:Quality_images_of_mammals", 3), ("Category:Quality_images_of_birds", 2),
                        ("Category:Quality_images_of_food", 3), ("Category:Quality_images_of_bridges", 2)]:
    try:
        print("_none", category, commons(category, count, "_none"))
    except Exception as error:
        print("skip", category, error)
direct("https://arxiv.org/pdf/1706.03762", "_none", "1706.03762.pdf", "arXiv paper")
direct("https://www.irs.gov/pub/irs-pdf/fw9.pdf", "_none", "fw9.pdf", "IRS form W-9 (public domain)")
with open(os.path.join(OUT, "SOURCES.tsv"), "w") as f:
    f.write("file\tsource\tlicense\n" + "\n".join(sources) + "\n")
for folder in sorted(os.listdir(OUT)):
    path = os.path.join(OUT, folder)
    if os.path.isdir(path):
        print(folder, len(os.listdir(path)))
