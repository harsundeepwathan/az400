import SwiftUI
import KiraCore

/// Three calm screens: what Kira is, how capture works honestly, and the privacy stance.
struct OnboardingView: View {
    var onFinish: () -> Void
    @State private var page = 0

    var body: some View {
        VStack(spacing: KiraSpacing.xl) {
            TabView(selection: $page) {
                pageView(symbol: "leaf.circle", title: "Know where your ringgit goes",
                         text: "Track spending across your banks, cards, DuitNow and e-wallets — with as little typing as possible.").tag(0)
                pageView(symbol: "wave.3.right.circle", title: "Capture, honestly",
                         text: "Log Apple Pay taps with a Shortcut, scan DuitNow QR codes, or import statements and receipts. Kira marks anything unconfirmed as pending — it never guesses that a payment went through.").tag(1)
                pageView(symbol: "lock.circle", title: "Private by design",
                         text: "Your data stays on this iPhone, encrypted by iOS. Kira never asks for your banking password.").tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < 2 { withAnimation { page += 1 } } else { onFinish() }
            } label: {
                Text(page < 2 ? "Continue" : "Get Started").frame(maxWidth: .infinity)
            }
            .kiraProminentButton()
            .padding(.horizontal, KiraSpacing.l)
            .padding(.bottom, KiraSpacing.xl)
        }
        .background(KiraColor.background.ignoresSafeArea())
    }

    private func pageView(symbol: String, title: String, text: String) -> some View {
        VStack(spacing: KiraSpacing.l) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 72, weight: .light)).foregroundStyle(KiraColor.accent)
            Text(title).font(.title.weight(.bold)).multilineTextAlignment(.center).foregroundStyle(KiraColor.textPrimary)
            Text(text).font(.body).multilineTextAlignment(.center).foregroundStyle(KiraColor.textSecondary)
            Spacer()
        }
        .padding(.horizontal, KiraSpacing.xl)
    }
}

/// Step-by-step setup for the Wallet Transaction automation, with its limits stated up front.
struct ShortcutsGuideView: View {
    @Environment(FinanceStore.self) private var store
    @State private var showingPaywall = false

    private struct Step: Identifiable {
        let number: Int
        let title: String
        let detail: String
        var id: Int { number }
    }

    private let rawSteps: [(String, String)] = [
        ("Open Shortcuts", "Go to the Automation tab and tap New Automation (+)."),
        ("Choose “Transaction”", "Under Wallet, pick Transaction. Select the cards you pay with, and choose all categories."),
        ("Run immediately", "Choose “Run Immediately” so it doesn’t ask each time. Then tap Next."),
        ("Add “Log Payment in Kira”", "Create a New Blank Automation, search for Kira and add Log Payment in Kira."),
        ("Pass the details", "Tap Amount and choose Shortcut Input › Amount. Do the same for Merchant and Card or Pass (tap the variable, then pick the field)."),
        ("Pay as usual", "When you tap your card with Apple Pay, the payment appears in Kira as Pending.")
    ]

    private var steps: [Step] {
        rawSteps.enumerated().map { Step(number: $0.offset + 1, title: $0.element.0, detail: $0.element.1) }
    }

    var body: some View {
        List {
            if !store.gate.isAvailable(.shortcutsCapture) {
                Section {
                    NoticeBanner(tone: .info, text: "Apple Pay capture is part of Kira Plus. Payments logged before you subscribe are kept and added once Plus is active.")
                    Button("See Kira Plus") { showingPaywall = true }
                }
            }
            Section("Set up once") {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: KiraSpacing.m) {
                        Text("\(step.number)").font(.headline).foregroundStyle(.white)
                            .frame(width: 28, height: 28).background(KiraColor.accent, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).font(.headline)
                            Text(step.detail).font(.subheadline).foregroundStyle(KiraColor.textSecondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
                Link(destination: URL(string: "shortcuts://")!) { Label("Open Shortcuts", systemImage: "arrow.up.forward.app") }
            }
            Section("Good to know") {
                Label("Works for in-store taps on the cards you select. Online and in-app Apple Pay may not trigger it.", systemImage: "info.circle")
                Label("iOS sometimes sends blank details. Kira keeps the entry and asks you to fill in the amount.", systemImage: "exclamationmark.circle")
                Label("A tap isn’t a settled payment. Entries stay Pending until they match a statement or you confirm them.", systemImage: "clock")
                Label("Repeated runs for the same payment are ignored.", systemImage: "arrow.triangle.2.circlepath")
            }
            .font(.subheadline)
        }
        .kiraScreen()
        .navigationTitle("Apple Pay automation")
        .sheet(isPresented: $showingPaywall) { PaywallView() }
    }
}
