#!/usr/bin/env python3
"""Unity 에셋(Abandoned_Asylum)에서 이 게임이 쓰는 텍스처만 골라 Godot용으로 변환한다.

사용법:
    python3 tools/import_unity_assets.py "<projecthospital>/My project (1)/Assets/Abandoned_Asylum"

- Unity .mat 파일의 _MainTex / _BumpMap GUID를 .meta에서 찾아 실제 PNG로 연결
- 1024px로 줄여 JPG로 저장 (원본 2048 PNG는 용량이 너무 큼)
- assets/materials.json 에 "FBX 머티리얼 이름 -> 텍스처" 매핑을 기록
"""
import json
import re
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT_TEX = ROOT / "assets" / "textures"
SIZE = 1024

# FBX 안의 머티리얼 이름 -> Unity .mat 파일 이름 (다르면 명시)
PROP_MATERIALS = {
    "Bed": "Bed", "Bench": "Bench", "Box_V1": "Box_V1", "Box_V2": "Box_V2",
    "CanOld_Damaged": "CanOld_Damaged", "ChairOffice": "ChairOffice", "Crutches": "Crutches",
    "Cupboard": "Cupboard", "Cupboard_Door": "Cupboard_Door", "CurtainsMedic": "CurtainsMedic",
    "Heater": "Heater", "LampWall": "LampWall", "MainDoor": "MainDoor", "Mattress": "Mattress",
    "MedRack": "MedRack", "MedRackDoor_R": "MedRackDoor_R", "MedRackDoor_L": "MedRackDoor_L",
    "MorgueBox": "MorgueBox", "MorgueBox_Bed": "MorgueBox_Bed", "MorgueBox_Door": "MorgueBox_Door",
    "MorgueTable": "MorgueTable", "MorgueWheelBed": "MorgueWheelBed", "PC_Monitor": "PC_Monitor",
    "Paper": "Paper", "SingleLight": "SingleLight", "Construction": "SurgeryChair_Construction",
    "Pillow": "SugeryChair_Pillow", "SurgeryLamp": "SurgeryLamp", "SurgeryTable": "SurgeryTable",
    "TV_Retro": "TV_Retro", "TableOffice": "TableOffice", "TableSmall": "TableSmall",
    "WheelChair": "WheelChair",
}
# 맵(바닥/벽/천장)용 타일 텍스처 (Textures/Tiled 기준 경로)
LEVEL_TEXTURES = {
    "floor_corridor": "Tiles/Tiles_5", "floor_room": "Tiles/Tiles_12", "floor_medical": "Tiles/Tiles_10",
    "wall": "Walls/Wall_1", "wall_medical": "Walls/Wall_4", "ceiling": "Walls/Wall_5",
}

GUID_RE = re.compile(r"guid:\s*([0-9a-f]{32})")


def build_guid_index(base: Path) -> dict:
    index = {}
    for meta in base.rglob("*.meta"):
        m = re.search(r"^guid:\s*([0-9a-f]{32})", meta.read_text(errors="ignore"), re.M)
        if m:
            index[m.group(1)] = meta.with_suffix("")
    return index


def tex_guid(mat_text: str, prop: str):
    m = re.search(rf"- {prop}:\s*\n\s*m_Texture:\s*\{{[^}}]*\}}", mat_text)
    if not m:
        return None
    g = GUID_RE.search(m.group(0))
    return g.group(1) if g else None


def color(mat_text: str):
    m = re.search(r"- _Color: \{r: ([\d.]+), g: ([\d.]+), b: ([\d.]+)", mat_text)
    return [float(m.group(i)) for i in (1, 2, 3)] if m else [1, 1, 1]


def convert(src: Path, dst: Path) -> str:
    dst.parent.mkdir(parents=True, exist_ok=True)
    img = Image.open(src).convert("RGB")
    if max(img.size) > SIZE:
        img = img.resize((SIZE, SIZE), Image.LANCZOS)
    img.save(dst, "JPEG", quality=88)
    return "res://" + dst.relative_to(ROOT).as_posix()


def main() -> None:
    base = Path(sys.argv[1])
    index = build_guid_index(base)
    result = {}
    for key, stem in LEVEL_TEXTURES.items():
        tiled = base / "Textures" / "Tiled"
        result[key] = {
            "color": [1, 1, 1],
            "albedo": convert(tiled / f"{stem}_Albedo.png", OUT_TEX / "level" / f"{Path(stem).name}_Albedo.jpg"),
            "normal": convert(tiled / f"{stem}_Normal.png", OUT_TEX / "level" / f"{Path(stem).name}_Normal.jpg"),
        }
    for key, mat_name in PROP_MATERIALS.items():
        group = "props"
        mat_path = base / "Materials" / f"{mat_name}.mat"
        text = mat_path.read_text(errors="ignore")
        entry = {"color": color(text)}
        for prop, kind in (("_MainTex", "albedo"), ("_BumpMap", "normal")):
            g = tex_guid(text, prop)
            if g and g in index and index[g].suffix.lower() in (".png", ".tga", ".jpg"):
                src = index[g]
                entry[kind] = convert(src, OUT_TEX / group / f"{src.stem}.jpg")
        result[key] = entry
        print(f"{key:16s} {list(entry)}")
    (ROOT / "assets" / "materials.json").write_text(json.dumps(result, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
