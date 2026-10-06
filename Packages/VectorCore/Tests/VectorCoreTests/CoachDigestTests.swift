import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import VectorCore

final class CoachDigestTests: XCTestCase {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()
    /// Monday 5 October 2026, 09:00 UTC.
    let now = Date(timeIntervalSince1970: 1_791_190_800)

    /// The request example from the shared contract, verbatim.
    let contractExample = #"""
    { "digest": {
      "date": "2026-10-06", "goal": "build_muscle", "unit": "kg",
      "training": { "workouts_last_7d": 4, "workouts_prev_7d": 3, "planned_per_week": 4,
                    "volume_change_pct": 6.5,
                    "prs_last_14d": [{ "exercise": "Back Squat", "weight": 82.5, "reps": 8 }],
                    "main_lift": { "exercise": "Back Squat", "e1rm_now": 101.3, "e1rm_30d_ago": 96.3 } },
      "nutrition": { "days_logged_last_7d": 6, "avg_calories": 2240, "target_calories": 2300,
                     "avg_protein": 128, "target_protein": 150, "protein_days_hit": 2 },
      "body": { "trend_weight_now": 77.4, "trend_weight_14d_ago": 77.9, "weigh_ins_last_14d": 11 },
      "recommendations": ["Increase Back Squat to 85 kg × 8"]
    } }
    """#

    override func setUp() {
        Format.locale = Locale(identifier: "en_US")
    }

    // MARK: Fixtures

    func profile(unit: WeightUnit = .kilograms, goal: TrainingGoal = .buildMuscle) -> UserProfile {
        var profile = PlanGenerator().generate(from: SampleData.answers(), now: now).profile
        profile.goal = goal
        profile.unit = unit
        profile.daysPerWeek = 3
        profile.targets = NutritionTargets(calories: 2300, protein: 150, carbs: 250, fat: 70)
        return profile
    }

    let program = TrainingProgram(name: "Upper / Lower", daysPerWeek: 4, workouts: [
        WorkoutTemplate(name: "Lower", exercises: [ExercisePrescription(exerciseID: "back-squat", sets: 3, repRange: RepRange(6, 8))])
    ])

    func day(_ daysAgo: Int, hour: Double = 12) -> Date {
        calendar.startOfDay(for: now).addingTimeInterval(Double(-daysAgo) * 86_400 + hour * 3600)
    }

    func squat(_ daysAgo: Int, _ weight: Double, reps: Int = 8) -> WorkoutSession {
        let start = day(daysAgo, hour: 9)
        return WorkoutSession(name: "Lower", startedAt: start, endedAt: start.addingTimeInterval(3600), exercises: [
            ExerciseLog(exerciseID: "back-squat", sets: (0..<3).map { _ in SetLog(weight: weight, reps: reps, isCompleted: true) },
                        repRange: RepRange(6, 8), restSeconds: 150)
        ])
    }

    func food(_ daysAgo: Int, calories: Double = 2200, protein: Double) -> FoodEntry {
        FoodEntry(date: day(daysAgo), meal: .lunch, name: "Day", macros: Macros(calories: calories, protein: protein, carbs: 200, fat: 70),
                  source: .quickAdd)
    }

    func fullContext(unit: WeightUnit = .kilograms) -> CoachContext {
        let sessions = [squat(35, 80), squat(25, 80), squat(10, 82.5), squat(3, 82.5), squat(1, 85)]
        // 6 of the 7 days before today are logged; today and day 9 are outside the window.
        let food = [food(1, protein: 160), food(2, protein: 160), food(3, protein: 120), food(4, protein: 120),
                    food(5, protein: 120), food(6, protein: 120), food(0, calories: 400, protein: 30), food(9, protein: 200)]
        // A steady 0.1 kg/day loss, weighed every morning for 20 days.
        let weights = (1...20).map { BodyWeightEntry(date: day($0, hour: 7), kilograms: 78 + Double($0) * 0.1) }
        return CoachContext(sessions: sessions, foodEntries: food, bodyWeights: weights, program: program,
                            profile: profile(unit: unit), now: now)
    }

    let increase = ProgressionRecommendation(exerciseID: "back-squat", action: .increaseLoad, weight: 87.5, reps: 8, sets: 3,
                                             reason: "", evidence: [])

    func json(_ digest: CoachDigest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: digest.requestBody()) as! [String: Any]
    }

    /// Every key path in a JSON value, e.g. "digest.training.main_lift.e1rm_now".
    func keyPaths(_ value: Any, prefix: String = "") -> Set<String> {
        var result = Set<String>()
        if let object = value as? [String: Any] {
            for (key, child) in object {
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                result.insert(path)
                result.formUnion(keyPaths(child, prefix: path))
            }
        } else if let array = value as? [Any] {
            for child in array { result.formUnion(keyPaths(child, prefix: prefix + "[]")) }
        }
        return result
    }

    // MARK: Shape

    func testDigestJSONHasExactlyTheContractKeys() throws {
        let digest = CoachDigestBuilder(calendar: calendar).build(fullContext(), recommendations: [increase])
        let contract = try JSONSerialization.jsonObject(with: Data(contractExample.utf8))
        XCTAssertEqual(keyPaths(try json(digest)), keyPaths(contract))
    }

    func testDigestValuesComeFromTheLogs() throws {
        let digest = CoachDigestBuilder(calendar: calendar).build(fullContext(), recommendations: [increase])
        XCTAssertEqual(digest.date, "2026-10-05")
        XCTAssertEqual(digest.goal, "build_muscle")
        XCTAssertEqual(digest.unit, "kg")

        let training = digest.training
        XCTAssertEqual(training.workoutsLast7d, 2)
        XCTAssertEqual(training.workoutsPrev7d, 1)
        XCTAssertEqual(training.plannedPerWeek, 4, "the program's frequency wins over the profile's")
        // (82.5 + 85) × 8 × 3 vs 82.5 × 8 × 3.
        XCTAssertEqual(training.volumeChangePct, 103.0)
        XCTAssertEqual(training.prsLast14d, [CoachDigest.PR(exercise: "Back Squat", weight: 85, reps: 8),
                                             CoachDigest.PR(exercise: "Back Squat", weight: 82.5, reps: 8)])
        XCTAssertEqual(training.mainLift, CoachDigest.MainLift(exercise: "Back Squat", e1rmNow: 107.7, e1rm30dAgo: 101.3))

        let nutrition = digest.nutrition
        XCTAssertEqual(nutrition.daysLoggedLast7d, 6, "today is in progress and excluded")
        XCTAssertEqual(nutrition.avgCalories, 2200)
        XCTAssertEqual(nutrition.avgProtein, 133)
        XCTAssertEqual(nutrition.targetCalories, 2300)
        XCTAssertEqual(nutrition.targetProtein, 150)
        XCTAssertEqual(nutrition.proteinDaysHit, 2)

        XCTAssertEqual(digest.body.weighInsLast14d, 13, "the weigh-in 14 days ago at 07:00 is just outside")
        let trendNow = try XCTUnwrap(digest.body.trendWeightNow)
        let trendBefore = try XCTUnwrap(digest.body.trendWeight14dAgo)
        XCTAssertLessThan(trendNow, trendBefore)

        XCTAssertEqual(digest.recommendations, ["Increase Back Squat to 87.5 kg × 8"])

        let encoded = try json(digest)["digest"] as! [String: Any]
        let lift = (encoded["training"] as! [String: Any])["main_lift"] as! [String: Any]
        XCTAssertEqual(lift["e1rm_now"] as? Double, 107.7)
    }

    func testEmptyHistoryEncodesNullsAndKeepsEveryKey() throws {
        let context = CoachContext(sessions: [], foodEntries: [], bodyWeights: [], program: nil, profile: profile(), now: now)
        let digest = CoachDigestBuilder(calendar: calendar).build(context)
        XCTAssertNil(digest.training.volumeChangePct)
        XCTAssertNil(digest.training.mainLift)
        XCTAssertTrue(digest.training.prsLast14d.isEmpty)
        XCTAssertEqual(digest.training.plannedPerWeek, 3, "falls back to the profile")
        XCTAssertEqual(digest.nutrition.daysLoggedLast7d, 0)
        XCTAssertNil(digest.nutrition.avgCalories)
        XCTAssertNil(digest.nutrition.avgProtein)
        XCTAssertNil(digest.body.trendWeightNow)
        XCTAssertNil(digest.body.trendWeight14dAgo)
        XCTAssertTrue(digest.recommendations.isEmpty)
        XCTAssertFalse(digest.hasLoggedData, "nothing logged: the app doesn't request a summary")
        XCTAssertTrue(CoachDigestBuilder(calendar: calendar).build(fullContext()).hasLoggedData)

        let encoded = try json(digest)["digest"] as! [String: Any]
        let training = encoded["training"] as! [String: Any]
        XCTAssertTrue(training["volume_change_pct"] is NSNull)
        XCTAssertTrue(training["main_lift"] is NSNull)
        let nutrition = encoded["nutrition"] as! [String: Any]
        XCTAssertTrue(nutrition["avg_calories"] is NSNull)
        XCTAssertTrue(nutrition["avg_protein"] is NSNull)
        let body = encoded["body"] as! [String: Any]
        XCTAssertTrue(body["trend_weight_now"] is NSNull)
        XCTAssertTrue(body["trend_weight_14d_ago"] is NSNull)

        // Nested nullable keys are still present when the parent object exists.
        let contract = try JSONSerialization.jsonObject(with: Data(contractExample.utf8))
        let missing = keyPaths(contract).subtracting(keyPaths(try json(digest)))
        XCTAssertEqual(missing, ["digest.training.prs_last_14d[].exercise", "digest.training.prs_last_14d[].weight",
                                 "digest.training.prs_last_14d[].reps", "digest.training.main_lift.exercise",
                                 "digest.training.main_lift.e1rm_now", "digest.training.main_lift.e1rm_30d_ago"],
                       "only children of empty arrays and null objects are absent")
    }

    func testSingleSessionMainLiftHasNoBaselineAndStaleWeighInsAreDropped() {
        let context = CoachContext(sessions: [squat(2, 100)], foodEntries: [],
                                   bodyWeights: [BodyWeightEntry(date: day(40), kilograms: 80)],
                                   program: program, profile: profile(), now: now)
        let digest = CoachDigestBuilder(calendar: calendar).build(context)
        XCTAssertEqual(digest.training.mainLift?.e1rmNow, 126.7)
        XCTAssertNil(digest.training.mainLift?.e1rm30dAgo, "one session is not a 30-day comparison")
        XCTAssertNil(digest.body.trendWeightNow, "a 40-day-old weigh-in is not today's trend")
        XCTAssertNil(digest.body.trendWeight14dAgo)
        XCTAssertEqual(digest.body.weighInsLast14d, 0)
        XCTAssertNil(digest.training.volumeChangePct)
    }

    func testPoundsAndLimits() {
        let recs = (0..<8).map { _ in increase } + [
            ProgressionRecommendation(exerciseID: "bench-press", action: .repeatLoad, weight: 60, reps: 8, sets: 3, reason: "", evidence: [])
        ]
        let digest = CoachDigestBuilder(calendar: calendar).build(fullContext(unit: .pounds), recommendations: recs)
        XCTAssertEqual(digest.unit, "lb")
        XCTAssertEqual(digest.training.prsLast14d.first?.weight, 187.4)
        XCTAssertEqual(digest.training.mainLift?.e1rmNow, 237.4)
        XCTAssertEqual(digest.recommendations.count, CoachDigest.maxRecommendations)
        XCTAssertEqual(digest.recommendations.first, "Increase Back Squat to 192.9 lb × 8")
        XCTAssertEqual(CoachDigest.goalValue(.getStronger), "gain_strength")
        XCTAssertEqual(CoachDigest.goalValue(.loseFat), "lose_fat")
        XCTAssertEqual(CoachDigest.goalValue(.improveFitness), "maintain")
        XCTAssertEqual(CoachDigestBuilder.clip(String(repeating: "a", count: 200)).count, 120)
    }

    func testDigestNumbersAreLocaleIndependent() throws {
        Format.locale = Locale(identifier: "de_DE")
        defer { Format.locale = Locale(identifier: "en_US") }
        let digest = CoachDigestBuilder(calendar: calendar).build(fullContext(), recommendations: [increase])
        XCTAssertEqual(digest.recommendations, ["Increase Back Squat to 87.5 kg × 8"])
    }

    // MARK: API client

    let base = URL(string: "https://api.example.com")!

    func signedIn() -> InMemoryTokenStore {
        InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r", userID: "u1", accessExpiresAt: now.addingTimeInterval(3000)))
    }

    func testCoachSummaryPostsDigestAndDecodes() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.url!.path, "/v1/coach/summary")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer a")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let digest = body["digest"] as! [String: Any]
            XCTAssertEqual(digest["goal"] as? String, "build_muscle")
            XCTAssertNotNil(digest["training"] as? [String: Any])
            return (200, #"{"summary":"Two sessions this week.","cached":true,"generated_at":"2026-10-05T07:12:00.000Z"}"#)
        }
        let api = APIClient(baseURL: base, transport: transport, tokens: signedIn(), now: { self.now })
        let digest = CoachDigestBuilder(calendar: calendar).build(fullContext(), recommendations: [])
        let summary = try await api.coachSummary(digest: digest)
        XCTAssertEqual(summary.text, "Two sessions this week.")
        XCTAssertTrue(summary.cached)
        XCTAssertEqual(summary.generatedAt, ISO8601DateFormatter().date(from: "2026-10-05T07:12:00Z"))
    }

    func testCoachSummaryErrorMapping() async {
        var reply: (Int, String) = (402, #"{"error":"pro_required"}"#)
        let transport = StubTransport { _ in reply }
        let api = APIClient(baseURL: base, transport: transport, tokens: signedIn(), now: { self.now })
        let digest = CoachDigestBuilder(calendar: calendar).build(fullContext(), recommendations: [])
        let cases: [((Int, String), CoachSummaryError)] = [
            ((402, #"{"error":"pro_required"}"#), .proRequired),
            ((400, #"{"error":"invalid_request"}"#), .invalidDigest),
            ((429, #"{"error":"rate_limited"}"#), .rateLimited),
            ((503, #"{"error":"busy"}"#), .unavailable),
            ((200, #"{"summary":"  "}"#), .unavailable)
        ]
        for (response, expected) in cases {
            reply = response
            do {
                _ = try await api.coachSummary(digest: digest)
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? CoachSummaryError, expected)
            }
        }

        let signedOut = APIClient(baseURL: base, transport: transport, tokens: InMemoryTokenStore())
        do {
            _ = try await signedOut.coachSummary(digest: digest)
            XCTFail("Expected sign-in required")
        } catch {
            XCTAssertEqual(error as? CoachSummaryError, .signedOut)
        }
    }

    func testProRequiredIsNotAScanQuota() {
        XCTAssertEqual(APIClient.error(status: 402, data: Data(#"{"error":"pro_required"}"#.utf8), authorized: true),
                       .rejected(status: 402, code: "pro_required"))
        guard case .scanQuotaExceeded = APIClient.error(status: 402, data: Data(#"{"error":"scan_quota_exceeded"}"#.utf8), authorized: true) else {
            return XCTFail("Scan quota mapping must be unchanged")
        }
    }
}
