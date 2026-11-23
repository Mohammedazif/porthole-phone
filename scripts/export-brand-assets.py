#!/usr/bin/env python3
"""Export the approved logo and sharing UI variant as light/dark vector assets.

Requires Pycairo only when rebuilding artwork; the iOS build uses the PDFs.
"""

import argparse
import json
import math
from pathlib import Path

import cairo


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "PortholePull/Assets.xcassets"
ICON = json.loads((ROOT / "Branding/porthole-icon-paths.json").read_text())
THEMES = {"light": ("#111111", "#B8B8B8"), "dark": ("#FFFFFF", "#A3A3A3")}


def transformed(paths, scale, x, y):
    def point(values):
        return [round(value * scale + (x if i % 2 == 0 else y), 6)
                for i, value in enumerate(values)]
    return [{"start": point(path["start"]),
             "curves": [point(curve) for curve in path["curves"]]} for path in paths]


def svg_path(paths):
    return " ".join("M" + " ".join(map(str, path["start"])) + " "
                    + " ".join("C" + " ".join(map(str, curve)) for curve in path["curves"])
                    + " Z" for path in paths)


def append_paths(context, paths):
    for path in paths:
        context.move_to(*path["start"])
        for curve in path["curves"]:
            context.curve_to(*curve)
        context.close_path()


def color(context, value):
    context.set_source_rgb(*(int(value[i:i + 2], 16) / 255 for i in (1, 3, 5)))


# Keep the original cursor outline. Only its size and placement change for the lens.
CURSOR = transformed([ICON["layers"]["ink"][1]], 0.6, 145, 135)
# A slightly expanded outline leaves a transparent gap without rasterizing the PDF.
CLEARANCE = transformed([ICON["layers"]["ink"][1]], 0.69, 118.9, 107.37)
REFLECTIONS = transformed(ICON["layers"]["reflection"], 0.6, 112, 20)


def draw(context, sharing, theme):
    ink, reflection = THEMES[theme]
    if sharing:
        context.save()
        context.rectangle(0, 0, 380, 380)
        append_paths(context, CLEARANCE)
        context.set_fill_rule(cairo.FILL_RULE_EVEN_ODD)
        context.clip()
        context.arc(190, 190, 180, 0, math.tau)
        context.set_line_width(19)
        color(context, ink)
        context.stroke()
        context.restore()
        append_paths(context, CURSOR)
        color(context, ink)
        context.fill()
        append_paths(context, REFLECTIONS)
        color(context, reflection)
        context.fill()
    else:
        # A 32 pt tab image contains the exact full logo at 24 pt, with 4 pt padding.
        context.translate(4, 4)
        context.scale(24 / 380, 24 / 380)
        context.set_fill_rule(cairo.FILL_RULE_EVEN_ODD)
        for layer, tone in (("ink", ink), ("reflection", reflection)):
            append_paths(context, ICON["layers"][layer])
            color(context, tone)
            context.fill()


def svg(sharing, theme):
    ink, reflection = THEMES[theme]
    if sharing:
        size = 380
        body = ('<defs><clipPath id="rim-clearance"><path clip-rule="evenodd" '
                f'd="M0 0H380V380H0Z {svg_path(CLEARANCE)}"/></clipPath></defs>'
                f'<circle cx="190" cy="190" r="180" fill="none" stroke="{ink}" '
                'stroke-width="19" clip-path="url(#rim-clearance)"/>'
                f'<path fill="{ink}" d="{svg_path(CURSOR)}"/>'
                f'<path fill="{reflection}" d="{svg_path(REFLECTIONS)}"/>')
    else:
        size = 32
        body = '<g transform="translate(4 4) scale(0.06315789473684211)">'
        for layer, tone in (("ink", ink), ("reflection", reflection)):
            body += f'<path fill="{tone}" fill-rule="evenodd" d="{svg_path(ICON["layers"][layer])}"/>'
        body += '</g>'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" '
            f'viewBox="0 0 {size} {size}">{body}</svg>\n')


def export(preview_dir=None):
    if preview_dir:
        preview_dir.mkdir(parents=True, exist_ok=True)
    for name, sharing in (("PortholeLogo", False), ("PortholeShareMark", True)):
        folder = ASSETS / f"{name}.imageset"
        folder.mkdir(parents=True, exist_ok=True)
        images = []
        for theme in THEMES:
            filename = f"{name}-{theme}.pdf"
            size = 380 if sharing else 32
            surface = cairo.PDFSurface(str(folder / filename), size, size)
            draw(cairo.Context(surface), sharing, theme)
            surface.finish()
            image = {"filename": filename, "idiom": "universal"}
            if theme == "dark":
                image["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
            images.append(image)
            if preview_dir:
                (preview_dir / f"{name}-{theme}.svg").write_text(svg(sharing, theme))
        catalog = {"images": images, "info": {"author": "xcode", "version": 1},
                   "properties": {"preserves-vector-representation": True,
                                  "template-rendering-intent": "original"}}
        (folder / "Contents.json").write_text(json.dumps(catalog, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preview-dir", type=Path, help="Also export SVGs for a browser preview")
    export(parser.parse_args().preview_dir)
