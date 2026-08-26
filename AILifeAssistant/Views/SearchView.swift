import SwiftData
import SwiftUI

/// Поиск по всем записям.
///
/// Отдельный экран, а не фильтр ленты. Задача у них разная: лента
/// показывает поток по времени, поиск отвечает на вопрос. Смешивать их
/// значит заставлять человека сначала вспомнить, когда он это сказал.
struct SearchView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(SearchService.self) private var search
    @Environment(ProcessingQueue.self) private var processingQueue

    @Query private var captures: [CaptureItem]

    @State private var query = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField

                if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    hints
                } else if search.results.isEmpty && !search.isSearching {
                    EmptyStateView(
                        symbol: "magnifyingglass",
                        title: "Ничего не найдено",
                        message: "Попробуйте другое слово из записи или её часть."
                    )
                    .frame(maxHeight: .infinity, alignment: .center)
                } else {
                    results
                }
            }
            .background(DS.Palette.background)
            .navigationTitle("Поиск")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear { isFieldFocused = true }
            .onDisappear { search.clear() }
        }
    }

    // MARK: Поле ввода

    private var searchField: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DS.Palette.textTertiary)

            TextField("Что ищем?", text: $query)
                .font(DS.Font.body)
                .focused($isFieldFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onChange(of: query) { _, newValue in
                    search.search(newValue)
                }

            if !query.isEmpty {
                Button {
                    query = ""
                    search.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                .accessibilityLabel("Очистить")
            }
        }
        .padding(DS.Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(DS.Palette.surfaceElevated)
        }
        .padding(DS.Spacing.md)
    }

    /// Пустой поиск показывает не пустоту, а примеры: человек чаще всего
    /// не знает, что здесь вообще можно искать.
    private var hints: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionLabel(text: "Например")

            ForEach(["кофе", "напомнить", "витамины"], id: \.self) { example in
                Button {
                    query = example
                    search.search(example)
                } label: {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.Palette.textTertiary)
                        Text(example)
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Palette.textPrimary)
                        Spacer()
                    }
                    .padding(.vertical, DS.Spacing.xs)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, DS.Spacing.md)
    }

    // MARK: Результаты

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Spacing.xs) {
                if search.isSearching {
                    HStack(spacing: DS.Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Ищу по смыслу")
                            .font(DS.Font.micro)
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                    .padding(.horizontal, DS.Spacing.xxs)
                }

                ForEach(search.results) { result in
                    resultRow(result)
                }

                if search.usedSemanticSearch {
                    Text("Часть результатов найдена по смыслу, а не по точному совпадению.")
                        .font(DS.Font.micro)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .padding(.top, DS.Spacing.xs)
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.lg)
        }
    }

    /// Захват открывается целиком: у него есть экран с разбором. Остальные
    /// типы показываются карточкой без перехода, отдельных экранов у них нет.
    @ViewBuilder
    private func resultRow(_ result: SearchResult) -> some View {
        if result.kind == .capture, let capture = captures.first(where: { $0.id == result.id }) {
            NavigationLink {
                CaptureDetailView(capture: capture, processingQueue: processingQueue)
            } label: {
                resultCard(result)
            }
            .buttonStyle(.plain)
        } else {
            resultCard(result)
        }
    }

    private func resultCard(_ result: SearchResult) -> some View {
        SurfaceCard(padding: DS.Spacing.sm + 2) {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: symbolName(for: result.kind))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint(for: result.kind))

                    Text(result.title)
                        .font(DS.Font.entityTitle)
                        .foregroundStyle(DS.Palette.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(result.occurredAt.formatted(date: .abbreviated, time: .omitted))
                        .font(DS.Font.micro)
                        .foregroundStyle(DS.Palette.textTertiary)
                }

                if !result.snippet.isEmpty, result.snippet != result.title {
                    Text(result.snippet)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func symbolName(for kind: SearchResult.Kind) -> String {
        switch kind {
        case .capture: return "waveform"
        case .note: return "text.alignleft"
        case .task: return "checkmark.circle.fill"
        case .reminder: return "bell.fill"
        case .expense: return "creditcard.fill"
        }
    }

    private func tint(for kind: SearchResult.Kind) -> Color {
        switch kind {
        case .capture: return DS.Palette.accent
        case .note: return DS.EntityColor.note
        case .task: return DS.EntityColor.task
        case .reminder: return DS.EntityColor.reminder
        case .expense: return DS.EntityColor.expense
        }
    }
}
