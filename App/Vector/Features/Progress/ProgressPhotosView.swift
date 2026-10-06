import PhotosUI
import SwiftUI
import VectorCore

/// Progress photos, kept only on this iPhone. Grid by date, add from the
/// camera or library with a pose, open one to delete it, and compare two
/// dates side by side.
struct ProgressPhotosView: View {
    @Environment(AppModel.self) private var model
    @State private var pickerItem: PhotosPickerItem?
    @State private var showsCamera = false
    @State private var pending: PendingPhoto?
    /// A camera capture held until the camera cover has finished dismissing;
    /// presenting the save sheet while the cover is still animating out drops it.
    @State private var captured: PendingPhoto?
    @State private var viewing: ProgressPhoto?
    @State private var loadFailed = false

    private let columns = [GridItem(.flexible(), spacing: Space.xs), GridItem(.flexible(), spacing: Space.xs),
                           GridItem(.flexible(), spacing: Space.xs)]

    var body: some View {
        let photos = model.progressPhotos
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                privacyNote
                if photos.isEmpty {
                    EmptyStateView(symbol: "person.crop.rectangle", title: "See the change for yourself",
                                   message: "Take front, side and back photos every few weeks in the same light and spot. They stay on this iPhone.")
                } else {
                    if model.measurementsEngine.photoDays(photos, pose: .front).count >= 2
                        || model.measurementsEngine.photoDays(photos, pose: .side).count >= 2
                        || model.measurementsEngine.photoDays(photos, pose: .back).count >= 2 {
                        NavigationLink {
                            ProgressPhotoCompareView()
                        } label: {
                            Label("Compare Two Dates", systemImage: "rectangle.split.2x1")
                        }
                        .buttonStyle(.secondary)
                    }
                    grid(photos)
                }
                addButtons
            }
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, Space.xl)
        }
        .screenBackground()
        .navigationTitle("Progress Photos")
        .navigationBarTitleDisplayMode(.inline)
        // No orphan cleanup here: if AppData failed to load, its photo list is
        // empty and a cleanup would delete every photo. `resetAll()` does it.
        .fullScreenCover(isPresented: $showsCamera, onDismiss: {
            if let captured {
                self.captured = nil
                pending = captured
            }
        }) {
            CameraPicker { image in
                captured = PendingPhoto(image: image, date: model.now())
                showsCamera = false
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    pending = PendingPhoto(image: image, date: model.now())
                } else {
                    loadFailed = true
                }
            }
        }
        .sheet(item: $pending) { PhotoSaveView(pending: $0) }
        .sheet(item: $viewing) { PhotoDetailView(photo: $0) }
        .alert("Couldn't load that photo", isPresented: $loadFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: Space.xs) {
            Image(systemName: "lock.iphone")
                .foregroundStyle(VColor.textSecondary)
                .accessibilityHidden(true)
            Text("Photos are stored only on this iPhone. They're never uploaded, not synced to iCloud and not included in backups, so they won't move to a new phone.")
                .font(VFont.caption)
                .foregroundStyle(VColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.xxs)
        .accessibilityElement(children: .combine)
    }

    private var addButtons: some View {
        VStack(spacing: Space.xs) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                PrimaryButton("Take Photo", symbol: "camera") { showsCamera = true }
            }
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Choose from Library", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.secondary)
        }
    }

    private func grid(_ photos: [ProgressPhoto]) -> some View {
        let days = Dictionary(grouping: photos) { model.calendar.startOfDay(for: $0.date) }
        return VStack(alignment: .leading, spacing: Space.lg) {
            ForEach(days.keys.sorted(by: >), id: \.self) { day in
                VStack(alignment: .leading, spacing: Space.xs) {
                    SectionHeader(Format.shortDate(day, calendar: model.calendar))
                    LazyVGrid(columns: columns, spacing: Space.xs) {
                        ForEach((days[day] ?? []).sorted { $0.pose.sortIndex < $1.pose.sortIndex }) { photo in
                            Button { viewing = photo } label: {
                                PhotoThumbnail(photo: photo, maxPixelSize: 400)
                                    .aspectRatio(3 / 4, contentMode: .fit)
                                    .overlay(alignment: .bottomLeading) {
                                        Text(photo.pose.displayName)
                                            .font(VFont.captionEmphasized)
                                            .foregroundStyle(VColor.textPrimary)
                                            .padding(.horizontal, Space.xs)
                                            .padding(.vertical, Space.xxs)
                                            .background(VColor.surfaceRaised, in: Capsule())
                                            .padding(Space.xs)
                                    }
                            }
                            .buttonStyle(.pressable)
                            .accessibilityLabel("\(photo.pose.displayName) photo, \(Format.shortDate(photo.date, calendar: model.calendar))")
                        }
                    }
                }
            }
        }
    }
}

private extension PhotoPose {
    var sortIndex: Int { PhotoPose.allCases.firstIndex(of: self) ?? 0 }
}

/// A captured or picked image waiting for a pose before it's saved.
struct PendingPhoto: Identifiable {
    let id = UUID()
    var image: UIImage
    var date: Date
}

/// Loads a stored photo off the main thread. A missing or locked file shows
/// a placeholder instead of failing.
struct PhotoThumbnail: View {
    @Environment(AppModel.self) private var model
    var photo: ProgressPhoto
    var maxPixelSize: CGFloat?
    @State private var image: UIImage?
    @State private var missing = false

    var body: some View {
        Rectangle()
            .fill(VColor.surfaceSunken)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if missing {
                    VStack(spacing: Space.xxs) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(.title3))
                        Text("Not on this iPhone")
                            .font(VFont.caption)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(VColor.textTertiary)
                    .padding(Space.xs)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .task(id: photo.id) {
                let store = model.photoStore
                let photo = photo
                let maxPixelSize = maxPixelSize
                let loaded = await Task.detached(priority: .userInitiated) {
                    store?.image(for: photo, maxPixelSize: maxPixelSize)
                }.value
                image = loaded
                missing = loaded == nil
            }
    }
}

/// Choose the pose (and date, for older library photos) before saving.
struct PhotoSaveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var pending: PendingPhoto
    @State private var pose: PhotoPose = .front
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            VStack(spacing: Space.lg) {
                Image(uiImage: pending.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .accessibilityLabel("Photo to save")
                Picker("Pose", selection: $pose) {
                    ForEach(PhotoPose.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                DatePicker("Date", selection: $date, in: ...model.now(), displayedComponents: .date)
                    .font(VFont.body)
                Spacer(minLength: 0)
                PrimaryButton("Save to This iPhone", symbol: "lock") {
                    if model.addProgressPhoto(pending.image, pose: pose, date: date) { dismiss() }
                }
            }
            .padding(Space.gutter)
            .screenBackground()
            .navigationTitle("New Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { date = pending.date }
            .sensoryFeedback(.selection, trigger: pose)
        }
    }
}

/// One photo, full size, with delete.
struct PhotoDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var photo: ProgressPhoto
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            PhotoThumbnail(photo: photo)
                .aspectRatio(3 / 4, contentMode: .fit)
                .padding(Space.gutter)
                .frame(maxHeight: .infinity)
                .screenBackground()
                .navigationTitle("\(photo.pose.displayName) · \(Format.shortDate(photo.date, calendar: model.calendar))")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .destructiveAction) {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Delete Photo", systemImage: "trash")
                        }
                    }
                }
                .confirmationDialog("Delete this photo?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete Photo", role: .destructive) {
                        model.deleteProgressPhoto(photo)
                        dismiss()
                    }
                } message: {
                    Text("It's removed from this iPhone. There's no other copy.")
                }
        }
    }
}

/// Two dates side by side for one pose.
struct ProgressPhotoCompareView: View {
    @Environment(AppModel.self) private var model
    @State private var pose: PhotoPose = .front
    @State private var before: Date?
    @State private var after: Date?

    var body: some View {
        let photos = model.progressPhotos
        let engine = model.measurementsEngine
        let days = engine.photoDays(photos, pose: pose)
        VStack(spacing: Space.md) {
            Picker("Pose", selection: $pose) {
                ForEach(PhotoPose.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            if days.count < 2 {
                EmptyStateView(symbol: "rectangle.split.2x1", title: "Need two dates",
                               message: "Add a \(pose.displayName.lowercased()) photo on another day to compare.")
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .top, spacing: Space.xs) {
                    column(title: "Before", selection: $before, days: days, photos: photos)
                    column(title: "After", selection: $after, days: days, photos: photos)
                }
                if let before, let after {
                    let gap = model.calendar.dateComponents([.day], from: before, to: after).day ?? 0
                    Text(gap == 0 ? "Same day" : "\(abs(gap)) days apart")
                        .font(VFont.caption.monospacedDigit())
                        .foregroundStyle(VColor.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(Space.gutter)
        .screenBackground()
        .navigationTitle("Compare")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: resetSelection)
        .onChange(of: pose) { _, _ in resetSelection() }
        .sensoryFeedback(.selection, trigger: pose)
    }

    private func resetSelection() {
        let pair = model.measurementsEngine.defaultComparison(model.progressPhotos, pose: pose)
        before = pair?.before
        after = pair?.after
    }

    private func column(title: String, selection: Binding<Date?>, days: [Date], photos: [ProgressPhoto]) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Menu {
                Picker(title, selection: selection) {
                    ForEach(days, id: \.self) { day in
                        Text(Format.shortDate(day, calendar: model.calendar)).tag(Optional(day))
                    }
                }
            } label: {
                HStack(spacing: Space.xxs) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title.uppercased())
                            .font(VFont.sectionHeading)
                            .tracking(0.6)
                            .foregroundStyle(VColor.textSecondary)
                        Text(selection.wrappedValue.map { Format.shortDate($0, calendar: model.calendar) } ?? "Choose")
                            .font(VFont.bodyEmphasized)
                            .foregroundStyle(VColor.textPrimary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(VColor.textSecondary)
                }
                .frame(minHeight: Size.minTouch)
            }
            .accessibilityLabel("\(title) date")
            .accessibilityValue(selection.wrappedValue.map { Format.shortDate($0, calendar: model.calendar) } ?? "None")

            if let day = selection.wrappedValue,
               let photo = model.measurementsEngine.photo(photos, pose: pose, on: day) {
                PhotoThumbnail(photo: photo, maxPixelSize: 1200)
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .accessibilityLabel("\(title): \(pose.displayName) photo, \(Format.shortDate(day, calendar: model.calendar))")
            } else {
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(VColor.surfaceSunken)
                    .aspectRatio(3 / 4, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    NavigationStack { ProgressPhotosView() }.environment(AppModel.preview(pro: true))
}
