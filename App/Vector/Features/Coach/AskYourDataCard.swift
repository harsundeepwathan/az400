import SwiftUI
import VectorCore

/// "Ask your data" (Pro): a question about your own training, food or
/// weight, answered from this week's digest. The app's rules still make
/// every decision; the answer only explains what the logged numbers show.
struct AskYourDataCard: View {
    @Environment(AppModel.self) private var model
    @State private var question = ""
    @State private var exchanges: [Exchange] = []
    @State private var isAsking = false
    @State private var problem: String?
    @State private var asksLeft: Int?
    @FocusState private var fieldFocused: Bool

    private struct Exchange: Identifiable {
        let id = UUID()
        var question: String
        var answer: String
    }

    private let suggestions = [
        "Why isn't my weight moving?",
        "Am I eating enough protein?",
        "Is my main lift improving?"
    ]

    var body: some View {
        WidgetSection(title: "Ask your data", symbol: "bubble.left.and.text.bubble.right", tint: .insight, spacing: Space.sm) {
            if !model.isPro {
                locked
            } else if !model.canShowCoachSummary {
                Text("Sign in from Profile to ask questions about your training, food and weight.")
                    .font(.subheadline)
                    .foregroundStyle(WColor.textSecondary)
            } else {
                ForEach(exchanges) { exchange in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(exchange.question)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(WColor.onSelected)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(WColor.selected, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(exchange.answer)
                            .font(.body)
                            .foregroundStyle(WColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
                if exchanges.isEmpty {
                    Text("Ask about your own logs: training, food, weight or a lift. Answers use only your numbers.")
                        .font(.subheadline)
                        .foregroundStyle(WColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.xs) {
                            ForEach(suggestions, id: \.self) { suggestion in
                                Button(suggestion) { send(suggestion) }
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(WColor.textPrimary)
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: Size.minTouch)
                                    .background(WColor.innerStrong, in: Capsule())
                                    .buttonStyle(.pressable)
                                    .disabled(isAsking)
                            }
                        }
                    }
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(WColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                inputRow
                if let asksLeft {
                    Text(asksLeft == 1 ? "1 question left today" : "\(asksLeft) questions left today")
                        .font(.caption)
                        .foregroundStyle(WColor.textSecondary)
                }
            }
        }
        .padding(.horizontal, -Space.gutter)
    }

    private var inputRow: some View {
        HStack(spacing: Space.xs) {
            TextField("Ask about your training, food or weight", text: $question, axis: .vertical)
                .lineLimit(1...3)
                .focused($fieldFocused)
                .submitLabel(.send)
                .onSubmit { send(question) }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(WColor.innerStrong, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button {
                send(question)
            } label: {
                Group {
                    if isAsking {
                        ProgressView().tint(WColor.onStrong)
                    } else {
                        Image(systemName: "arrow.up").font(.body.weight(.bold))
                    }
                }
                .foregroundStyle(WColor.onStrong)
                .frame(width: Size.minTouch, height: Size.minTouch)
                .background(WColor.strong, in: Circle())
            }
            .buttonStyle(.pressable)
            .disabled(isAsking || trimmed(question).count < 3)
            .accessibilityLabel(isAsking ? "Asking" : "Ask")
        }
    }

    private var locked: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("With Pro, ask questions like “Why isn’t my weight moving?” and get an answer from your own logs, with the numbers behind it.")
                .font(.subheadline)
                .foregroundStyle(WColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Button("See Vector Pro") { model.presentPaywall(.coach) }
                .buttonStyle(.widgetSecondary)
        }
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send(_ raw: String) {
        let text = String(trimmed(raw).prefix(200))
        guard text.count >= 3, !isAsking, let digest = model.coachDigest else { return }
        isAsking = true
        problem = nil
        fieldFocused = false
        Task {
            defer { isAsking = false }
            do {
                let answer = try await model.askCoach(text, digest: digest)
                withAnimation(Motion.snappy) {
                    exchanges.append(Exchange(question: text, answer: answer.text))
                }
                asksLeft = answer.asksLeftToday
                question = ""
            } catch let error as CoachSummaryError {
                problem = message(for: error)
            } catch {
                problem = "Couldn't answer right now. Try again in a moment."
            }
        }
    }

    private func message(for error: CoachSummaryError) -> String {
        switch error {
        case .proRequired: "Ask your data is part of Vector Pro."
        case .signedOut: "Sign in from Profile to ask questions."
        case .offline: "You're offline. Try again when you're connected."
        case .rateLimited(let retryAfter) where (retryAfter ?? 0) > 120: "That's today's questions used. Ask again tomorrow."
        case .rateLimited: "Still answering your last question. Try again in a few seconds."
        default: "Couldn't answer right now. Try again in a moment."
        }
    }
}
