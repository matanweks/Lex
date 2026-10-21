import LexCore
import SwiftUI

/// Every emoji, like Gboard's: your recent ones, then each category (the bar at the bottom
/// jumps to one), skin tones on a long press, and a search in English or Hebrew typed on the
/// keys under the search field.
struct EmojiPanel: View {
    @ObservedObject var model: KeyboardModel
    @ObservedObject var typist: Typist
    @ObservedObject var settings: KeyboardSettings
    let ownClicks: Bool
    @State private var group: Int?

    private static let catalog = KeyboardModel.emoji
    private static let byGroup = catalog.groups.indices.map { catalog.entries(in: $0) }
    private static let symbols = ["face.smiling", "hand.wave", "pawprint", "fork.knife", "car", "soccerball", "lightbulb", "heart", "flag"]
    private static let recentID = -1

    var body: some View {
        if let query = model.emojiQuery {
            search(query)
        } else {
            browse
        }
    }

    // MARK: Browsing

    private var browse: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 4) {
                Group {
                    if let entry = model.tonesFor {
                        tones(of: entry)
                    } else {
                        Button { model.emojiQuery = "" } label: {
                            Label("Search emoji", systemImage: "magnifyingglass")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("kb-emoji-search")
                    }
                }
                .padding(.horizontal, 6)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 8), alignment: .leading, spacing: 2) {
                        if !model.recentEmoji.isEmpty {
                            Section {
                                // Their own IDs: the grid would take one for the same emoji in its category.
                                ForEach(model.recentEmoji.map { "recent " + $0 }, id: \.self) { id in
                                    let e = String(id.dropFirst(7))
                                    cell(e) { type(e) }
                                }
                            } header: {
                                header("Recent").id(Self.recentID)
                            }
                        }
                        ForEach(Self.byGroup.indices, id: \.self) { g in
                            Section {
                                ForEach(Self.byGroup[g]) { entry in
                                    let shown = model.tones[entry.emoji] ?? entry.emoji
                                    cell(shown, tones: entry.tones.isEmpty ? nil : { model.tonesFor = entry }) { type(shown) }
                                }
                            } header: {
                                header(Self.catalog.groups[g]).id(g)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .scrollIndicators(.hidden)
                .scrollEdgeEffectHidden()
                bottomBar(proxy)
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .padding(.leading, 4)
    }

    /// `tones` opens the skin tones on a long press, which goes before the tap.
    private func cell(_ emoji: String, tones: (() -> Void)? = nil, action: @escaping () -> Void) -> some View {
        Text(emoji)
            .font(.system(size: 30))
            .frame(maxWidth: .infinity, minHeight: 42)
            .overlay(alignment: .bottomTrailing) {
                // Like the system keyboard: a mark on emoji that come in skin tones.
                if tones != nil { Image(systemName: "arrowtriangle.down.fill").font(.system(size: 4)).foregroundStyle(.tertiary).padding(3) }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .highPriorityGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in tones?() }, including: tones == nil ? .subviews : .all)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(emoji)
    }

    private func tones(of entry: EmojiCatalog.Entry) -> some View {
        HStack(spacing: 2) {
            ForEach([entry.emoji] + entry.tones, id: \.self) { toned in
                Button {
                    type(toned)
                    model.pickTone(toned, of: entry)
                } label: {
                    Text(toned).font(.system(size: 26)).frame(maxWidth: .infinity, minHeight: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button { model.tonesFor = nil } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 30, height: 32).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Close skin tones")
        }
        .frame(height: 32)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    private func bottomBar(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 4) {
            Button { model.panel = nil } label: {
                Text(typist.language == .english ? "ABC" : "אבג").font(.callout).frame(width: 52, height: 38).background(KeyBackground(dim: true))
            }
            .buttonStyle(.plain)
            HStack(spacing: 0) {
                category("clock", id: Self.recentID, proxy)
                ForEach(Self.symbols.indices.filter { $0 < Self.byGroup.count }, id: \.self) { g in category(Self.symbols[g], id: g, proxy) }
            }
            .frame(maxWidth: .infinity)
            Button { typist.press(.delete) } label: {
                Image(systemName: "delete.left").frame(width: 52, height: 38).background(KeyBackground(dim: true))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete")
        }
        .padding(.horizontal, 6)
    }

    private func category(_ symbol: String, id: Int, _ proxy: ScrollViewProxy) -> some View {
        Button {
            group = id
            proxy.scrollTo(id, anchor: .top)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(group == id ? Brand.indigo : .secondary)
                .frame(maxWidth: .infinity, minHeight: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(id == Self.recentID ? "Recent" : Self.catalog.groups[id])
    }

    private func type(_ emoji: String) {
        typist.type(emoji)
        model.usedEmoji(emoji)
    }

    // MARK: Search

    private func search(_ query: String) -> some View {
        let found = query.trimmingCharacters(in: .whitespaces).isEmpty ? model.recentEmoji : Self.catalog.search(query).map { model.tones[$0.emoji] ?? $0.emoji }
        return VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                // The keys below type here; the bar is a cursor.
                HStack(spacing: 1) {
                    Text(query.isEmpty ? "" : query).foregroundStyle(.primary)
                    Rectangle().fill(Brand.indigo).frame(width: 2, height: 18)
                    if query.isEmpty { Text("Search emoji").foregroundStyle(.secondary) }
                }
                .lineLimit(1)
                .accessibilityIdentifier("kb-emoji-query")
                Spacer(minLength: 0)
                Button { model.emojiQuery = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 34, height: 34).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop searching")
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .padding(.horizontal, 6)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(found, id: \.self) { e in
                        cell(e) { type(e) }.frame(width: 44)
                    }
                    if found.isEmpty {
                        Text(query.isEmpty ? "Type to search, in English or Hebrew" : "No emoji for “\(query)”")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.hidden)
            .frame(height: 44)
            .accessibilityIdentifier("kb-emoji-results")
            KeyGrid(look: KeyGridView.Look(rows: KeyboardLayout.rows(.letters, typist.language), returnLabel: "done", returnProminent: true, language: typist.language),
                    typist: typist, settings: settings, ownClicks: ownClicks, route: { model.searchKey($0, typist: typist) })
        }
    }
}
