"""Tests for the Home Designer scripts.

    python3 -m unittest discover -s tests -v      (from the plugin root)
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

import clearances  # noqa: E402
import floorplan  # noqa: E402
import lighting  # noqa: E402
import palette  # noqa: E402
import roomspec  # noqa: E402

EXAMPLES = os.path.join(ROOT, "examples")


def write(tmpdir: str, data: dict) -> str:
    path = os.path.join(tmpdir, "layout.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle)
    return path


BARE = {
    "name": "Test room",
    "room": {"width": 4000, "depth": 3000},
    "openings": [{"type": "door", "wall": "south", "offset": 200, "width": 900}],
    "furniture": [],
}


class GeometryTests(unittest.TestCase):
    def test_corners_unrotated(self):
        corners = roomspec.rect_corners(1000, 1000, 400, 200)
        self.assertEqual(corners[0], (800.0, 900.0))
        self.assertEqual(corners[2], (1200.0, 1100.0))

    def test_rotation_is_clockwise_on_screen(self):
        # y grows downwards, so a 90 degree turn sends local +x to south
        (x, y) = roomspec.rect_corners(0, 0, 200, 100, 90)[1]
        self.assertAlmostEqual(x, 50.0, places=6)
        self.assertAlmostEqual(y, 100.0, places=6)

    def test_overlap_and_touch(self):
        a = roomspec.rect_corners(0, 0, 100, 100)
        b = roomspec.rect_corners(80, 0, 100, 100)
        c = roomspec.rect_corners(200, 0, 100, 100)
        self.assertTrue(roomspec.polygons_overlap(a, b))
        self.assertFalse(roomspec.polygons_overlap(a, c))

    def test_polygon_distance(self):
        a = roomspec.rect_corners(0, 0, 100, 100)
        b = roomspec.rect_corners(300, 0, 100, 100)
        self.assertAlmostEqual(roomspec.polygon_distance(a, b), 200.0, places=6)
        self.assertEqual(roomspec.polygon_distance(a, a), 0.0)

    def test_point_polygon_distance(self):
        poly = roomspec.rect_corners(0, 0, 100, 100)
        self.assertEqual(roomspec.point_polygon_distance((0, 0), poly), 0.0)
        self.assertAlmostEqual(roomspec.point_polygon_distance((150, 0), poly), 100.0, places=6)

    def test_rotated_overlap(self):
        a = roomspec.rect_corners(0, 0, 1000, 100)
        b = roomspec.rect_corners(0, 0, 1000, 100, 90)
        self.assertTrue(roomspec.polygons_overlap(a, b))


class LoadingTests(unittest.TestCase):
    def test_units_convert(self):
        room = roomspec.from_dict({"units": "m", "room": {"width": 4, "depth": 3},
                                   "furniture": [{"name": "x", "x": 1, "y": 1,
                                                  "width": 2, "depth": 0.5}]})
        self.assertEqual(room.width, 4000.0)
        self.assertEqual(room.items[0].w, 2000.0)
        self.assertAlmostEqual(room.area_m2, 12.0)

    def test_rejects_opening_off_the_wall(self):
        with self.assertRaises(roomspec.SpecError):
            roomspec.from_dict({"room": {"width": 2000, "depth": 2000},
                                "openings": [{"wall": "north", "offset": 1800, "width": 900}]})

    def test_rejects_unknown_units_and_walls(self):
        with self.assertRaises(roomspec.SpecError):
            roomspec.from_dict({"units": "furlongs", "room": {"width": 1, "depth": 1}})
        with self.assertRaises(roomspec.SpecError):
            roomspec.from_dict({"room": {"width": 2000, "depth": 2000},
                                "openings": [{"wall": "up", "offset": 0, "width": 100}]})

    def test_missing_centre_is_reported(self):
        with self.assertRaises(roomspec.SpecError):
            roomspec.from_dict({"room": {"width": 2000, "depth": 2000},
                                "furniture": [{"name": "sofa", "x": 100,
                                               "width": 100, "depth": 100}]})

    def test_examples_load_and_pass(self):
        for name in ("living-room.json", "bedroom.json"):
            with self.subTest(example=name):
                room = roomspec.load(os.path.join(EXAMPLES, name))
                report, summary = clearances.analyse(room)
                self.assertEqual(report.counts()["error"], 0, report.findings)
                self.assertEqual(report.counts()["warning"], 0, report.findings)
                self.assertGreater(summary["area_m2"], 0)


class GridTests(unittest.TestCase):
    def test_clearance_map_respects_walls(self):
        room = roomspec.from_dict({"room": {"width": 2000, "depth": 2000}})
        grid = roomspec.Grid(room, cell=50.0)
        clearance = grid.clearance_map()
        centre = clearance[grid.ny // 2][grid.nx // 2]
        self.assertGreater(centre, 900.0)
        self.assertLess(clearance[0][0], 100.0)

    def test_blocked_cells_stop_the_flood(self):
        room = roomspec.from_dict({
            "room": {"width": 4000, "depth": 4000},
            "furniture": [{"name": "wall of stuff", "type": "storage", "x": 2000, "y": 2000,
                           "width": 4000, "depth": 400}],
        })
        grid = roomspec.Grid(room, cell=50.0)
        seen = grid.reachable([grid.index(2000, 600)], 900.0)
        self.assertTrue(seen[grid.index(2000, 600)[1]][grid.index(2000, 600)[0]])
        far = grid.index(2000, 3400)
        self.assertFalse(seen[far[1]][far[0]])


class ClearanceTests(unittest.TestCase):
    def analyse(self, data: dict):
        return clearances.analyse(roomspec.from_dict(data))

    def rules(self, report) -> set:
        return {finding["rule"] for finding in report.findings}

    def test_out_of_bounds(self):
        data = dict(BARE, furniture=[{"name": "Escapee", "type": "chair", "x": 3900,
                                      "y": 1000, "width": 600, "depth": 600}])
        report, _ = self.analyse(data)
        self.assertIn("bounds", self.rules(report))

    def test_overlap(self):
        data = dict(BARE, furniture=[
            {"name": "A", "type": "sofa", "x": 2000, "y": 1500, "width": 1000, "depth": 800},
            {"name": "B", "type": "sofa", "x": 2200, "y": 1500, "width": 1000, "depth": 800},
        ])
        report, _ = self.analyse(data)
        self.assertIn("overlap", self.rules(report))

    def test_mounted_items_are_not_obstacles(self):
        data = dict(BARE, furniture=[
            {"name": "Unit", "type": "media_unit", "x": 2000, "y": 1500,
             "width": 1000, "depth": 400},
            {"name": "TV", "type": "tv", "x": 2000, "y": 1500, "width": 1200,
             "depth": 80, "mounted": True, "diagonal": 1400},
        ])
        report, _ = self.analyse(data)
        self.assertNotIn("overlap", self.rules(report))

    def test_door_swing_is_kept_clear(self):
        data = dict(BARE, furniture=[{"name": "Shelf", "type": "bookshelf", "x": 600,
                                      "y": 2700, "width": 800, "depth": 350}])
        report, _ = self.analyse(data)
        self.assertIn("door-swing", self.rules(report))

    def test_out_swinging_door_is_not_checked_inside(self):
        data = dict(BARE)
        data["openings"] = [{"type": "door", "wall": "south", "offset": 200,
                             "width": 900, "swing": "out"}]
        data["furniture"] = [{"name": "Shelf", "type": "bookshelf", "x": 600, "y": 2700,
                              "width": 800, "depth": 350}]
        report, _ = self.analyse(data)
        self.assertNotIn("door-swing", self.rules(report))

    def test_blocked_route_between_doors(self):
        data = {
            "name": "Corridor",
            "room": {"width": 3000, "depth": 3000},
            "openings": [
                {"type": "door", "wall": "south", "offset": 1000, "width": 900},
                {"type": "door", "name": "far", "wall": "north", "offset": 1000, "width": 900},
            ],
            "furniture": [{"name": "Barricade", "type": "storage", "x": 1500, "y": 1500,
                           "width": 3000, "depth": 400}],
        }
        report, _ = self.analyse(data)
        self.assertIn("circulation", self.rules(report))

    def test_clear_room_has_no_findings(self):
        data = dict(BARE, furniture=[{"name": "Sofa", "type": "sofa", "x": 2000, "y": 400,
                                      "width": 2000, "depth": 800, "rotation": 180}])
        report, _ = self.analyse(data)
        self.assertEqual(report.counts()["error"], 0, report.findings)

    def test_window_blocking_uses_height(self):
        data = {
            "room": {"width": 4000, "depth": 3000},
            "openings": [
                {"type": "door", "wall": "south", "offset": 200, "width": 900},
                {"type": "window", "wall": "north", "offset": 1000, "width": 1500, "sill": 900},
            ],
            "furniture": [{"name": "Tall shelf", "type": "bookshelf", "x": 1700, "y": 200,
                           "width": 900, "depth": 350, "height": 1800, "rotation": 180}],
        }
        report, _ = self.analyse(data)
        self.assertIn("window", self.rules(report))
        data["furniture"][0]["height"] = 700
        report, _ = self.analyse(data)
        self.assertNotIn("window", self.rules(report))

    def test_seating_distance_band(self):
        def gap_for(table_y: float):
            data = dict(BARE, furniture=[
                {"name": "Sofa", "type": "sofa", "x": 2000, "y": 400, "width": 2000,
                 "depth": 800, "rotation": 180},
                {"name": "Table", "type": "coffee_table", "x": 2000, "y": table_y,
                 "width": 1000, "depth": 500},
            ])
            report, _ = self.analyse(data)
            return {f["rule"] for f in report.findings}
        self.assertIn("reach", gap_for(1100))   # 50 mm gap, too close
        self.assertNotIn("reach", gap_for(1400))  # 350 mm gap, right

    def test_bed_needs_both_sides(self):
        data = {
            "room": {"width": 2400, "depth": 3400},
            "openings": [{"type": "door", "wall": "south", "offset": 1400, "width": 800}],
            "furniture": [{"name": "Bed", "type": "bed", "x": 900, "y": 1100,
                           "width": 1500, "depth": 2000, "rotation": 180}],
        }
        report, _ = self.analyse(data)
        self.assertIn("bed", {f["rule"] for f in report.findings})

    def test_side_normals_point_out(self):
        item = roomspec.Item(name="s", kind="sofa", x=0, y=0, w=100, d=100, rotation=0)
        self.assertEqual(clearances.side_normals(item)["front"], (0.0, -1.0))
        turned = roomspec.Item(name="s", kind="sofa", x=0, y=0, w=100, d=100, rotation=180)
        front = clearances.side_normals(turned)["front"]
        self.assertAlmostEqual(front[1], 1.0, places=6)

    def test_limits_can_be_overridden(self):
        room = roomspec.from_dict(dict(BARE, clearances={"primary_walkway": 1200}))
        self.assertEqual(clearances.limits(room)["primary_walkway"], 1200.0)


class FloorplanTests(unittest.TestCase):
    def test_renders_valid_svg(self):
        room = roomspec.load(os.path.join(EXAMPLES, "living-room.json"))
        svg = floorplan.render(room)
        root = ET.fromstring(svg)
        self.assertTrue(root.tag.endswith("svg"))
        text = "".join(node.text or "" for node in root.iter()
                       if node.tag.endswith("text"))
        self.assertIn("Sofa", text)
        self.assertIn("Living room", text)

    def test_true_scale_is_honoured(self):
        room = roomspec.from_dict({"room": {"width": 1000, "depth": 1000}})
        svg = floorplan.render(room, scale_denominator=50)
        root = ET.fromstring(svg)
        # 1000 mm at 1:50 is 20 mm on paper, which is 96/25.4 * 20 CSS px
        expected = 2 * 90.0 + floorplan.PX_PER_MM / 50 * 1000 + 140.0
        self.assertAlmostEqual(float(root.get("width")), round(expected), delta=1.0)

    def test_escapes_names(self):
        room = roomspec.from_dict({"name": "Bill & Ben's <room>",
                                   "room": {"width": 2000, "depth": 2000}})
        ET.fromstring(floorplan.render(room))  # would raise if the name broke the markup

    def test_cli_writes_a_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "plan.svg")
            with contextlib.redirect_stdout(io.StringIO()):
                code = floorplan.main([os.path.join(EXAMPLES, "bedroom.json"), "-o", out])
            self.assertEqual(code, 0)
            self.assertTrue(os.path.getsize(out) > 500)


class PaletteTests(unittest.TestCase):
    def test_known_contrast_ratios(self):
        white, black = (1.0, 1.0, 1.0), (0.0, 0.0, 0.0)
        self.assertAlmostEqual(palette.contrast_ratio(white, black), 21.0, places=2)
        self.assertAlmostEqual(palette.lrv(white), 100.0, places=2)
        self.assertAlmostEqual(palette.lrv(black), 0.0, places=2)
        self.assertAlmostEqual(palette.lrv(palette.hex_to_rgb("#808080")), 21.6, places=1)

    def test_hex_round_trip(self):
        self.assertEqual(palette.rgb_to_hex(palette.hex_to_rgb("#3E5C50")), "#3E5C50")
        self.assertEqual(palette.rgb_to_hex(palette.hex_to_rgb("#abc")), "#AABBCC")

    def test_bad_hex_is_rejected(self):
        for value in ("nope", "#12345", "#12345g"):
            with self.assertRaises(ValueError):
                palette.hex_to_rgb(value)

    def test_targets_lrv(self):
        for swatch in palette.build("#3E5C50", "analogous"):
            target = dict((role[0], role[5]) for role in palette.ROLES)[swatch["role"]]
            self.assertLess(abs(swatch["lrv"] - target), 2.0, swatch)

    def test_ceiling_is_lightest(self):
        swatches = {s["role"]: s for s in palette.build("#C1440E", "triadic")}
        self.assertGreater(swatches["ceiling"]["lrv"], swatches["dominant"]["lrv"])
        self.assertGreater(swatches["dominant"]["lrv"], swatches["anchor"]["lrv"])

    def test_svg_is_wellformed(self):
        ET.fromstring(palette.render_svg(palette.build("#3E5C50"), "Test & co"))


class LightingTests(unittest.TestCase):
    def test_lumens_scale_with_area(self):
        small = lighting.plan(10, "living")
        large = lighting.plan(20, "living")
        self.assertAlmostEqual(large["total_lumens"] / small["total_lumens"], 2.0, delta=0.05)

    def test_dark_walls_need_more_light(self):
        self.assertGreater(lighting.plan(20, "living", "dark")["total_lumens"],
                           lighting.plan(20, "living", "light")["total_lumens"])

    def test_layers_add_up(self):
        result = lighting.plan(18, "kitchen")
        total = sum(layer["lumens"] for layer in result["layers"])
        self.assertAlmostEqual(total, result["total_lumens"], delta=150)
        self.assertAlmostEqual(sum(layer["share"] for layer in result["layers"]), 1.0, places=6)

    def test_unknown_room_type(self):
        with self.assertRaises(ValueError):
            lighting.plan(10, "dungeon")

    def test_task_mode_is_brighter(self):
        self.assertGreater(lighting.plan(12, "office", mode="task")["total_lumens"],
                           lighting.plan(12, "office", mode="ambient")["total_lumens"])


class CliTests(unittest.TestCase):
    def run_checker(self, argv: list[str]) -> tuple[int, str]:
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer), contextlib.redirect_stderr(io.StringIO()):
            code = clearances.main(argv)
        return code, buffer.getvalue()

    def test_checker_exit_codes(self):
        code, output = self.run_checker([os.path.join(EXAMPLES, "living-room.json")])
        self.assertEqual(code, 0)
        self.assertIn("no clearance problems", output)
        with tempfile.TemporaryDirectory() as tmp:
            bad = write(tmp, {"room": {"width": 2000, "depth": 2000},
                              "furniture": [{"name": "Big", "type": "sofa", "x": 1000,
                                             "y": 1000, "width": 4000, "depth": 400}]})
            self.assertEqual(self.run_checker([bad])[0], 1)
            self.assertEqual(self.run_checker([os.path.join(tmp, "missing.json")])[0], 2)

    def test_checker_json_output(self):
        code, output = self.run_checker([os.path.join(EXAMPLES, "bedroom.json"), "--json"])
        self.assertEqual(code, 0)
        payload = json.loads(output)
        self.assertEqual(payload["summary"]["room"], "Main bedroom")
        self.assertIn("primary_walkway", payload["limits"])

    def test_strict_fails_on_warnings(self):
        with tempfile.TemporaryDirectory() as tmp:
            layout = write(tmp, {
                "room": {"width": 3000, "depth": 3000},
                "openings": [{"type": "door", "wall": "south", "offset": 200, "width": 900}],
                "furniture": [
                    {"name": "Sofa", "type": "sofa", "x": 1500, "y": 500,
                     "width": 2000, "depth": 800, "rotation": 180},
                    {"name": "Table", "type": "coffee_table", "x": 1500, "y": 1150,
                     "width": 900, "depth": 400},
                ],
            })
            self.assertEqual(self.run_checker([layout])[0], 0)
            self.assertEqual(self.run_checker([layout, "--strict"])[0], 1)


if __name__ == "__main__":
    unittest.main()
