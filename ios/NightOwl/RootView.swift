import SwiftUI

struct RootView: View {
    @Environment(Store.self) private var store
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            TonightTab().tag(0).tabItem { Label("Last night", systemImage: "moon.stars.fill") }
            TrendsView().tag(1).tabItem { Label("Trends", systemImage: "chart.bar.fill") }
            HistoryView().tag(2).tabItem { Label("History", systemImage: "calendar") }
        }
        .onChange(of: store.openNight) { _, n in if n != nil { tab = 0 } }
        .task { await store.refresh() }
    }
}

struct TonightTab: View {
    @Environment(Store.self) private var store
    @State private var settings = false

    var body: some View {
        NavigationStack {
            Group {
                if let n = store.latest {
                    NightView(night: n).refreshable { await store.refresh() }
                } else {
                    Welcome()
                }
            }
            .navigationTitle("Night Owl")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if store.loading { ProgressView() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let e = store.error, store.hasFolder {
                    Text(e).font(.caption).padding(10).frame(maxWidth: .infinity)
                        .background(.red.opacity(0.25))
                }
            }
            .sheet(isPresented: $settings) { SettingsView() }
        }
    }
}

struct HistoryView: View {
    @Environment(Store.self) private var store

    var body: some View {
        NavigationStack {
            List(store.nights.reversed()) { n in
                NavigationLink(value: n) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n.date.dayLabel).font(.body.weight(.medium))
                            Text("\(duration(ms: n.snoreMs)) snoring · \(n.percentOfNight)% of \(duration(ms: n.recordedMs))")
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        ScorePill(score: n.score, band: n.band)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.card)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.sky.ignoresSafeArea())
            .navigationTitle("History")
            .navigationDestination(for: Night.self) { n in
                NightView(night: n).navigationTitle(n.date.dayLabel).navigationBarTitleDisplayMode(.inline)
            }
            .refreshable { await store.refresh() }
            .overlay { if store.nights.isEmpty { ContentUnavailableView("No nights yet", systemImage: "moon.zzz") } }
        }
    }
}

struct FolderButton: View {
    @Environment(Store.self) private var store
    @State private var picking = false
    var title = "Choose NightOwl folder"
    var body: some View {
        Button(title) { picking = true }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { store.setFolder(url) }
            }
    }
}

struct Welcome: View {
    @Environment(Store.self) private var store
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "moon.stars.fill").font(.system(size: 56)).foregroundStyle(Theme.amber)
            Text("Night Owl").font(.largeTitle.weight(.bold))
            if store.hasFolder {
                Text(store.error ?? "Waiting for the first night from your Mac.")
                    .multilineTextAlignment(.center).foregroundStyle(Theme.muted)
                Button("Try again") { Task { await store.refresh() } }
            } else {
                Text("Your Mac puts each night in iCloud Drive › NightOwl. Pick that folder once and the app keeps up from there.")
                    .multilineTextAlignment(.center).foregroundStyle(Theme.muted)
                FolderButton().buttonStyle(.borderedProminent).foregroundStyle(.black)
            }
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .background(Theme.sky.ignoresSafeArea())
    }
}

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Data") {
                    FolderButton(title: "Change NightOwl folder")
                    Button("Refresh now") { Task { await store.refresh() } }
                    LabeledContent("Nights", value: "\(store.nights.count)")
                }
                Section("Snore Score") {
                    Text("5 × minutes of snoring per hour recorded, plus 1 per possible gasp, capped at 100. Lower is quieter.")
                        .font(.callout).foregroundStyle(Theme.muted)
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
