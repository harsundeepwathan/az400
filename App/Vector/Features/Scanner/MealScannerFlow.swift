import PhotosUI
import SwiftUI
import VectorCore

/// State machine for a single scan. Kept separate from the views so the
/// flow is easy to reason about: capture → analyzing → review (or error).
@Observable
@MainActor
final class MealScanSession {
    enum Phase: Equatable {
        case capture
        case analyzing
        case review
        case failed(MealRecognitionError)
    }

    var phase: Phase = .capture
    var image: UIImage?
    var items: [RecognizedFood] = []
    /// What the AI returned, kept to measure how much the user corrected.
    private(set) var originalItems: [RecognizedFood] = []
    var meal: MealType
    private let recognizer: MealRecognizing
    private var task: Task<Void, Never>?

    init(meal: MealType, recognizer: MealRecognizing) {
        self.meal = meal
        self.recognizer = recognizer
    }

    var total: Macros { items.reduce(.zero) { $0 + $1.macros } }

    func analyze(_ image: UIImage, onSuccess: @escaping () -> Void) {
        self.image = image
        withAnimation(Motion.smooth) { phase = .analyzing }
        task?.cancel()
        let recognizer = recognizer
        let data = image.downscaled(maxDimension: 1024).jpegData(compressionQuality: 0.7) ?? Data()
        task = Task {
            do {
                let analysis = try await recognizer.analyze(imageData: data)
                guard !Task.isCancelled else { return }
                items = analysis.items
                originalItems = analysis.items
                onSuccess()
                withAnimation(Motion.smooth) { phase = .review }
            } catch {
                guard !Task.isCancelled else { return }
                let failure = (error as? MealRecognitionError) ?? .network
                withAnimation(Motion.smooth) { phase = .failed(failure) }
            }
        }
    }

    func retake() {
        task?.cancel()
        items = []
        originalItems = []
        image = nil
        withAnimation(Motion.smooth) { phase = .capture }
    }

    func cancel() { task?.cancel() }

    // Corrections
    func setGrams(_ grams: Double, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].grams = max(grams, 0)
    }

    func replaceFood(_ food: FoodItem, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let previous = items[index].food
        items[index].replaceFood(food)
        items[index].confidence = 1
        items[index].alternatives = [previous] + items[index].alternatives.filter { $0.id != food.id && $0.id != previous.id }
    }

    func setMacros(_ macros: Macros, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].setMacros(macros)
    }

    var correction: ScanCorrection { ScanCorrection.compare(original: originalItems, final: items) }

    func remove(_ id: UUID) {
        withAnimation(Motion.smooth) { items.removeAll { $0.id == id } }
    }

    func add(_ food: FoodItem) {
        withAnimation(Motion.smooth) {
            items.append(RecognizedFood(food: food, grams: food.servingGrams, confidence: 1))
        }
    }
}

struct MealScannerFlow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session: MealScanSession

    init(meal: MealType, recognizer: MealRecognizing) {
        _session = State(initialValue: MealScanSession(meal: meal, recognizer: recognizer))
    }

    var body: some View {
        ScannerContent(session: session, onClose: close)
    }

    private func close() {
        session.cancel()
        dismiss()
    }
}

private struct ScannerContent: View {
    @Bindable var session: MealScanSession
    var onClose: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        switch session.phase {
        case .capture:
            CaptureView(session: session, onClose: onClose)
                .transition(.opacity)
        case .analyzing:
            AnalyzingView(image: session.image, onCancel: { session.retake() })
                .transition(.opacity)
        case .review:
            ScanReviewView(session: session, onClose: onClose)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .failed(let error):
            ScanErrorView(error: error, onRetake: { session.retake() }, onClose: onClose)
                .transition(.opacity)
        }
    }
}

// MARK: - Capture

private struct CaptureView: View {
    var session: MealScanSession
    var onClose: () -> Void
    @Environment(AppModel.self) private var model
    @State private var showsCamera = false
    @State private var pickerItem: PhotosPickerItem?

    private var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: Space.lg) {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(.body, weight: .semibold))
                            .frame(width: Size.minTouch, height: Size.minTouch)
                            .background(.white.opacity(0.15), in: Circle())
                    }
                    .accessibilityLabel("Close")
                    Spacer()
                    if let remaining = model.scansRemaining {
                        Chip(text: "\(remaining) free \(remaining == 1 ? "scan" : "scans") left", tint: .white, fill: .white.opacity(0.15))
                    }
                }
                .foregroundStyle(.white)
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                        .strokeBorder(.white.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                    VStack(spacing: Space.sm) {
                        Image(systemName: "fork.knife.circle")
                            .font(.system(size: 56, weight: .light))
                        Text("Take a photo of your meal")
                            .font(VFont.title3)
                        Text("Shoot from above with the whole plate in frame. You'll review everything before it's logged.")
                            .font(VFont.secondary)
                            .multilineTextAlignment(.center)
                            .opacity(0.75)
                    }
                    .foregroundStyle(.white)
                    .padding(Space.lg)
                }
                .aspectRatio(1, contentMode: .fit)
                Spacer()
                VStack(spacing: Space.sm) {
                    if cameraAvailable {
                        Button {
                            showsCamera = true
                        } label: {
                            Circle()
                                .fill(.white)
                                .frame(width: 76, height: 76)
                                .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 3).padding(5))
                        }
                        .accessibilityLabel("Take photo")
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Choose from Library", systemImage: "photo.on.rectangle")
                            .font(VFont.secondaryEmphasized)
                            .foregroundStyle(.white)
                            .frame(minHeight: Size.minTouch)
                    }
                    if !cameraAvailable, model.recognizer is DemoMealRecognizer {
                        Button("Try a sample meal") {
                            session.analyze(UIImage(systemName: "fork.knife") ?? UIImage()) { model.recordScan() }
                        }
                        .font(VFont.secondaryEmphasized)
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(minHeight: Size.minTouch)
                    }
                }
            }
            .padding(Space.gutter)
        }
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker { image in
                showsCamera = false
                session.analyze(image) { model.recordScan() }
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    session.analyze(image) { model.recordScan() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

// MARK: - Analyzing

/// Animated scanning state: a sweep line over the photo and rotating
/// status text that describes what's actually happening.
private struct AnalyzingView: View {
    var image: UIImage?
    var onCancel: () -> Void
    @State private var sweep = false
    @State private var step = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let steps = ["Identifying foods", "Estimating portions", "Calculating macros"]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: Space.lg) {
                Spacer()
                ZStack(alignment: .top) {
                    Group {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            VColor.surfaceRaised
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .clipped()
                    .overlay(Color.black.opacity(0.25))

                    if !reduceMotion {
                        GeometryReader { proxy in
                            LinearGradient(colors: [VColor.accent.opacity(0), VColor.accent.opacity(0.55)],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: 80)
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(Color.white).frame(height: 2).shadow(color: VColor.accent, radius: 8)
                                }
                                .offset(y: sweep ? proxy.size.height - 80 : -80)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
                .padding(.horizontal, Space.gutter)

                VStack(spacing: Space.xs) {
                    HStack(spacing: Space.xs) {
                        ProgressView().tint(.white)
                        Text("Analyzing meal…").font(VFont.headline)
                    }
                    Text(steps[step])
                        .font(VFont.secondary)
                        .opacity(0.75)
                        .contentTransition(.opacity)
                        .id(step)
                }
                .foregroundStyle(.white)
                .accessibilityElement(children: .combine)

                VStack(spacing: Space.xs) {
                    ForEach(0..<3, id: \.self) { _ in
                        HStack {
                            Text("Placeholder food item").font(VFont.body)
                            Spacer()
                            Text("000 kcal").font(VFont.body)
                        }
                        .padding(Space.md)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    }
                }
                .foregroundStyle(.white)
                .skeleton(true)
                .padding(.horizontal, Space.gutter)
                .accessibilityHidden(true)

                Spacer()
                Button("Cancel", action: onCancel)
                    .font(VFont.bodyEmphasized)
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(minHeight: Size.minTouch)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { sweep = true }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.1))
                withAnimation(Motion.smooth) { step = min(step + 1, steps.count - 1) }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: step)
    }
}

// MARK: - Error

private struct ScanErrorView: View {
    var error: MealRecognitionError
    var onRetake: () -> Void
    var onClose: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            VStack(spacing: Space.lg) {
                Spacer()
                ErrorStateView(title: error.title, message: error.message, retryTitle: "Retake Photo", retry: onRetake)
                VStack(spacing: Space.sm) {
                    Button("Search Food Instead") {
                        onClose()
                        model.sheet = .foodSearch(.suggested(forHour: model.calendar.component(.hour, from: model.now())))
                    }
                    .buttonStyle(.secondary)
                    if error == .quotaExceeded {
                        Button("See Pro") {
                            onClose()
                            model.presentPaywall(.mealScanQuota)
                        }
                        .buttonStyle(.primary)
                    }
                }
                Spacer()
            }
            .padding(Space.gutter)
            .screenBackground()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose) } }
        }
    }
}

extension UIImage {
    func downscaled(maxDimension: CGFloat) -> UIImage {
        let largest = max(size.width, size.height)
        guard largest > maxDimension else { return self }
        let scale = maxDimension / largest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: target).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}

/// Shown instead of the scanner when no meal-scan service is configured, so
/// the app never pretends to analyse a photo.
struct ScanUnavailableView: View {
    var meal: MealType
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: Space.lg) {
                Spacer()
                ErrorStateView(title: "Meal scanning is unavailable",
                               message: "AI meal scanning isn't set up in this build. You can still search, scan barcodes or quick add.",
                               retryTitle: "Search Food Instead") {
                    dismiss()
                    model.sheet = .foodSearch(meal)
                }
                Spacer()
            }
            .padding(Space.gutter)
            .screenBackground()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}
