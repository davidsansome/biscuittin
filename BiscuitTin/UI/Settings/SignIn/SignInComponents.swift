import SwiftUI

/// The frame every sign-in page shares: a header, scrolling content, and actions pinned above
/// the keyboard so the primary button is never hidden while typing.
struct SignInPageLayout<Content: View, Actions: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    /// Keeps pages readable on iPad and in landscape rather than stretching edge to edge.
    private let maxWidth: CGFloat = 520

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    Image(systemName: symbol)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 72, height: 72)
                        .background(.tint.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 16)

                content
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) { actions }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
    }
}

/// A full-width button that shows a spinner in place of its title while work is in flight, so
/// the layout does not jump.
struct SignInPrimaryButton: View {
    let title: String
    var isLoading = false
    var prominent = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(isLoading ? 0 : 1)
                if isLoading { ProgressView() }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .controlSize(.large)
        .modifier(ProminenceStyle(prominent: prominent))
    }

    private struct ProminenceStyle: ViewModifier {
        let prominent: Bool
        func body(content: Content) -> some View {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }
}

/// A text field in a filled rounded rectangle, with a leading glyph naming what goes in it.
struct SignInField<Field: View>: View {
    let symbol: String
    @ViewBuilder var field: Field

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            field
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// One line of status under a field: what was found, or what went wrong.
struct SignInStatusLine: View {
    enum Tone { case neutral, success, warning, failure }

    let text: String
    var symbol: String?
    var tone: Tone = .neutral
    var showsProgress = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if showsProgress {
                ProgressView().controlSize(.small)
            } else if let symbol {
                Image(systemName: symbol).foregroundStyle(color)
            }
            Text(text)
                .foregroundStyle(tone == .neutral ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch tone {
        case .neutral: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }
}

/// A selectable option presented as a card, for choices that each need a sentence to explain.
struct SignInChoiceCard: View {
    let symbol: String
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .multilineTextAlignment(.leading)
            .padding(16)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                                  lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
