import SwiftUI
import VisionKit
import VectorCore

/// Live barcode scanning via VisionKit, with manual entry as a fallback
/// for devices (and the simulator) without scanner support.
struct BarcodeScanView: View {
    var meal: MealType
    var date: Date
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var found: FoodItem?
    @State private var notFound: String?

    private var scannerAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Space.md) {
                if scannerAvailable {
                    BarcodeScanner { lookup($0) }
                        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                                .frame(width: 240, height: 140)
                                .accessibilityHidden(true)
                        }
                        .frame(maxHeight: 360)
                    Text("Point the camera at a barcode")
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)
                } else {
                    EmptyStateView(symbol: Icon.barcode, title: "Scanner unavailable",
                                   message: "This device can't scan barcodes. Enter the number printed under the barcode instead.")
                }

                HStack(spacing: Space.xs) {
                    TextField("Enter barcode number", text: $code)
                        .keyboardType(.numberPad)
                        .padding(.horizontal, Space.md)
                        .frame(minHeight: Size.minTouch)
                        .background(VColor.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    Button("Look up") { lookup(code) }
                        .buttonStyle(.secondary(compact: true))
                        .disabled(code.count < 6)
                }

                if let notFound {
                    VStack(spacing: Space.xs) {
                        Text("We don't have \(notFound) yet").font(VFont.bodyEmphasized)
                        Text("Search by name or quick add the numbers from the label.")
                            .font(VFont.secondary)
                            .foregroundStyle(VColor.textSecondary)
                        HStack {
                            Button("Search") { model.sheet = .foodSearch(meal) }.buttonStyle(.secondary(compact: true))
                            Button("Quick Add") { model.sheet = .quickAdd(meal) }.buttonStyle(.secondary(compact: true))
                        }
                    }
                    .card()
                }
                Spacer()
            }
            .padding(Space.gutter)
            .screenBackground()
            .navigationTitle("Scan Barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(item: $found) { food in
                PortionEditor(food: food, meal: meal, date: date) { dismiss() }
                    .presentationDetents([.medium, .large])
            }
            .sensoryFeedback(.success, trigger: found?.id)
        }
    }

    private func lookup(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard found == nil else { return }
        if let food = model.foods.food(barcode: trimmed) {
            notFound = nil
            found = food
        } else {
            notFound = trimmed
        }
    }
}

private struct BarcodeScanner: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    onScan(payload)
                    return
                }
            }
        }
    }
}
