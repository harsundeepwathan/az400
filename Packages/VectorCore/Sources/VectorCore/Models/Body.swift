import Foundation

/// A body site measured with a tape. Values are always stored in centimetres.
public enum BodySite: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case waist, hips, chest, arm, thigh, neck

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .waist: "Waist"
        case .hips: "Hips"
        case .chest: "Chest"
        case .arm: "Arm"
        case .thigh: "Thigh"
        case .neck: "Neck"
        }
    }

    /// Where to put the tape, so repeated measurements are comparable.
    public var guidance: String {
        switch self {
        case .waist: "At the navel, relaxed, after breathing out."
        case .hips: "Around the widest part of the glutes."
        case .chest: "Across the nipples, arms relaxed."
        case .arm: "Around the biceps at its widest, relaxed."
        case .thigh: "Midway between hip and knee."
        case .neck: "Just below the larynx."
        }
    }
}

/// Length unit for display, following the user's weight unit
/// (kilograms → centimetres, pounds → inches).
public enum LengthUnit: String, Hashable, Sendable {
    case centimeters, inches

    public static let centimetersPerInch = 2.54

    public init(_ weightUnit: WeightUnit) {
        self = weightUnit == .kilograms ? .centimeters : .inches
    }

    public var symbol: String { self == .centimeters ? "cm" : "in" }

    public func fromCentimeters(_ cm: Double) -> Double { self == .centimeters ? cm : cm / Self.centimetersPerInch }
    public func toCentimeters(_ value: Double) -> Double { self == .centimeters ? value : value * Self.centimetersPerInch }
}

/// One measuring session. Every site is optional: people rarely measure
/// everything, and a missing value is "not measured", never zero.
public struct BodyMeasurementEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var waistCm: Double?
    public var hipsCm: Double?
    public var chestCm: Double?
    public var armCm: Double?
    public var thighCm: Double?
    public var neckCm: Double?

    public init(id: UUID = UUID(), date: Date, waistCm: Double? = nil, hipsCm: Double? = nil, chestCm: Double? = nil,
                armCm: Double? = nil, thighCm: Double? = nil, neckCm: Double? = nil) {
        self.id = id
        self.date = date
        self.waistCm = waistCm
        self.hipsCm = hipsCm
        self.chestCm = chestCm
        self.armCm = armCm
        self.thighCm = thighCm
        self.neckCm = neckCm
    }

    /// The value for a site in centimetres, nil when it wasn't measured.
    /// Setting zero, a negative or a non-finite number clears it.
    public subscript(site: BodySite) -> Double? {
        get {
            switch site {
            case .waist: waistCm
            case .hips: hipsCm
            case .chest: chestCm
            case .arm: armCm
            case .thigh: thighCm
            case .neck: neckCm
            }
        }
        set {
            let value = newValue.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            switch site {
            case .waist: waistCm = value
            case .hips: hipsCm = value
            case .chest: chestCm = value
            case .arm: armCm = value
            case .thigh: thighCm = value
            case .neck: neckCm = value
            }
        }
    }

    public var measuredSites: [BodySite] { BodySite.allCases.filter { self[$0] != nil } }
    public var isEmpty: Bool { measuredSites.isEmpty }
}

/// Which way the athlete faces in a progress photo.
public enum PhotoPose: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case front, side, back

    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

/// Metadata for a progress photo. The image itself lives only in the app's
/// local container (see the app's `ProgressPhotoStore`); it is never
/// uploaded and the metadata never leaves this device (see `SyncMerge`).
public struct ProgressPhoto: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var pose: PhotoPose
    /// File name inside the local photo directory, no path components.
    public var fileName: String

    public init(id: UUID = UUID(), date: Date, pose: PhotoPose, fileName: String? = nil) {
        self.id = id
        self.date = date
        self.pose = pose
        self.fileName = fileName ?? "\(id.uuidString).jpg"
    }

    /// True when `fileName` is a bare file name, so it can't point outside
    /// the photo directory.
    public var hasSafeFileName: Bool {
        !fileName.isEmpty && !fileName.contains("/") && !fileName.contains("\\") && fileName != "." && fileName != ".."
            && !fileName.hasPrefix(".")
    }
}
