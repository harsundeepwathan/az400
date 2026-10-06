#!/usr/bin/env python3
"""Converts free-exercise-db (public domain, github.com/yuhonas/free-exercise-db)
into VectorCore's bundled exercise library.

    git clone --depth 1 https://github.com/yuhonas/free-exercise-db /tmp/fedb
    python3 tools/import_exercises.py /tmp/fedb/dist/exercises.json

Writes Packages/VectorCore/Sources/VectorCore/Resources/exercises.json. The 50
hand-written exercises in ExerciseCatalog.swift keep their stable ids; they only
borrow demonstration images from the dataset (CURATED_IMAGES below).
"""
import json, re, sys, pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / "Packages/VectorCore/Sources/VectorCore/Resources/exercises.json"

# Curated catalog id -> dataset id (for demonstration images only).
CURATED_IMAGES = {
    "back-squat": "Barbell_Squat", "front-squat": "Front_Barbell_Squat", "hack-squat": "Hack_Squat",
    "goblet-squat": "Goblet_Squat", "leg-press": "Leg_Press", "bodyweight-squat": "Bodyweight_Squat",
    "romanian-deadlift": "Romanian_Deadlift", "deadlift": "Barbell_Deadlift",
    "db-romanian-deadlift": "Stiff-Legged_Dumbbell_Deadlift", "hip-thrust": "Barbell_Hip_Thrust",
    "kb-swing": "One-Arm_Kettlebell_Swings", "glute-bridge": "Butt_Lift_Bridge",
    "bulgarian-split-squat": "Split_Squat_with_Dumbbells", "walking-lunge": "Dumbbell_Lunges",
    "reverse-lunge": "Dumbbell_Rear_Lunge", "leg-curl": "Seated_Leg_Curl", "nordic-curl": "Natural_Glute_Ham_Raise",
    "leg-extension": "Leg_Extensions", "standing-calf-raise": "Rocking_Standing_Calf_Raise",
    "single-leg-calf-raise": "Calf_Raise_On_A_Dumbbell", "bench-press": "Barbell_Bench_Press_-_Medium_Grip",
    "incline-db-press": "Incline_Dumbbell_Press", "db-bench-press": "Dumbbell_Bench_Press",
    "machine-chest-press": "Machine_Bench_Press", "push-up": "Pushups", "cable-fly": "Cable_Crossover",
    "overhead-press": "Standing_Military_Press", "db-shoulder-press": "Dumbbell_Shoulder_Press",
    "pike-push-up": "Handstand_Push-Ups", "lateral-raise": "Side_Lateral_Raise",
    "cable-lateral-raise": "Cable_Seated_Lateral_Raise", "barbell-row": "Bent_Over_Barbell_Row",
    "chest-supported-row": "Dumbbell_Incline_Row", "seated-cable-row": "Seated_Cable_Rows",
    "inverted-row": "Inverted_Row", "lat-pulldown": "Wide-Grip_Lat_Pulldown", "pull-up": "Pullups",
    "face-pull": "Face_Pull", "db-curl": "Dumbbell_Bicep_Curl", "ez-bar-curl": "EZ-Bar_Curl",
    "cable-curl": "Standing_Biceps_Cable_Curl", "triceps-pushdown": "Triceps_Pushdown",
    "overhead-triceps-extension": "Cable_Rope_Overhead_Triceps_Extension", "dips": "Dips_-_Triceps_Version",
    "diamond-push-up": "Push-Ups_-_Close_Triceps_Position", "hanging-leg-raise": "Hanging_Leg_Raise",
    "cable-crunch": "Cable_Crunch", "plank": "Plank",
}

MUSCLES = {"quadriceps": "quads", "hamstrings": "hamstrings", "glutes": "glutes", "chest": "chest",
           "lats": "back", "middle back": "back", "lower back": "back", "traps": "back", "shoulders": "shoulders",
           "biceps": "biceps", "triceps": "triceps", "calves": "calves", "abdominals": "core", "forearms": "forearms",
           "adductors": "hamstrings", "abductors": "glutes"}
EQUIPMENT = {"barbell": "barbell", "e-z curl bar": "barbell", "dumbbell": "dumbbell", "machine": "machine",
             "cable": "cable", "body only": "bodyweight", "kettlebells": "kettlebell", "bands": "band",
             "other": "other", "medicine ball": "other", "exercise ball": "other"}
INCREMENT = {"barbell": 2.5, "dumbbell": 2, "machine": 5, "cable": 2.5, "kettlebell": 4, "bodyweight": 0, "band": 0, "other": 2.5}
LOWER = {"quads", "hamstrings", "glutes", "calves"}
SYMBOL = {"squat": "figure.strengthtraining.traditional", "hinge": "figure.strengthtraining.functional",
          "lunge": "figure.step.training", "horizontalPush": "figure.strengthtraining.traditional",
          "verticalPush": "figure.arms.open", "horizontalPull": "figure.rower", "verticalPull": "figure.climbing",
          "elbowFlexion": "dumbbell", "elbowExtension": "dumbbell", "isolationLower": "figure.cooldown",
          "isolationUpper": "figure.arms.open", "core": "figure.core.training"}

def has(name, *words):
    return any(re.search(r"\b" + w, name) for w in words)

def pattern(x, primary):
    n = x["name"].lower(); p0 = primary[0]
    if p0 == "core": return "core"
    if has(n, "calf", "leg curl", "leg extension", "hamstring curl"): return "isolationLower"
    if has(n, "lunge", "split squat", "step-up", "step up"): return "lunge"
    if has(n, "squat", "leg press"): return "squat"
    if has(n, "deadlift", "good morning", "hip thrust", "swing", "hyperextension", "bridge", "pull through", "glute ham"): return "hinge"
    if p0 == "biceps" or has(n, "curl"): return "elbowFlexion" if p0 in ("biceps", "forearms") else "isolationLower"
    if p0 == "triceps" or has(n, "pushdown", "skull", "kickback"): return "elbowExtension"
    if has(n, "pulldown", "pullup", "pull-up", "chin"): return "verticalPull"
    if has(n, "row"): return "horizontalPull"
    if has(n, "fly", "flye", "crossover", "raise", "shrug", "face pull", "pullover"): return "isolationLower" if p0 in LOWER else "isolationUpper"
    if p0 == "shoulders" and x.get("force") == "push": return "verticalPush"
    if p0 == "chest" or has(n, "bench", "push-up", "pushup", "dip"): return "horizontalPush"
    if p0 == "back": return "horizontalPull"
    if x.get("mechanic") == "isolation": return "isolationLower" if p0 in LOWER else "isolationUpper"
    if p0 == "quads": return "squat"
    if p0 in ("hamstrings", "glutes"): return "hinge"
    return "isolationUpper"

def slug(s):
    return "fedb-" + re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")

def main(src):
    data = json.load(open(src))
    curated_ids = set(CURATED_IMAGES.values())
    known = {x["id"] for x in data}
    missing = [v for v in CURATED_IMAGES.values() if v not in known]
    if missing: sys.exit(f"Curated image ids not in dataset: {missing}")
    out = []
    for x in data:
        if x["category"] not in ("strength", "powerlifting") or x["id"] in curated_ids: continue
        equipment = EQUIPMENT.get(x.get("equipment") or "")
        primary = list(dict.fromkeys(MUSCLES[m] for m in x["primaryMuscles"] if m in MUSCLES))
        if not equipment or not primary or not x["instructions"]: continue
        secondary = [m for m in dict.fromkeys(MUSCLES[m] for m in x["secondaryMuscles"] if m in MUSCLES) if m not in primary]
        compound = x.get("mechanic") == "compound"
        pat = pattern(x, primary)
        rest = 150 if compound and equipment == "barbell" else (120 if compound else 75)
        out.append({
            "id": slug(x["id"]), "name": x["name"], "primaryMuscles": primary, "secondaryMuscles": secondary,
            "equipment": equipment, "pattern": pat, "instructions": [s.strip() for s in x["instructions"]],
            "defaultRestSeconds": rest, "loadIncrement": INCREMENT[equipment], "isCompound": compound,
            "symbol": SYMBOL[pat], "images": x["images"], "level": x.get("level") or "beginner",
        })
    out.sort(key=lambda e: e["name"].lower())
    images = {k: [f"{v}/0.jpg", f"{v}/1.jpg"] for k, v in CURATED_IMAGES.items()}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({"source": "free-exercise-db (public domain)", "curatedImages": images, "exercises": out},
                              ensure_ascii=False, separators=(",", ":")))
    print(f"Wrote {len(out)} imported exercises + images for {len(images)} curated ones to {OUT}")

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/tmp/fedb/dist/exercises.json")
