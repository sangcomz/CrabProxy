import AppKit
import SwiftUI

struct CodeBlock: View {
    let text: String?
    let placeholder: String
    @Environment(\.colorScheme) private var colorScheme

    private var renderedText: String {
        guard let text, !text.isEmpty else { return placeholder }
        return text
    }

    private var hasContent: Bool {
        guard let text else { return false }
        return !text.isEmpty
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(renderedText)
                .textSelection(.enabled)
                .font(.custom("Menlo", size: 11))
                .foregroundStyle(
                    hasContent
                        ? CrabTheme.primaryText(for: colorScheme).opacity(0.92)
                        : CrabTheme.secondaryText(for: colorScheme)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(minHeight: 120)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(CrabTheme.inputFill(for: colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(CrabTheme.inputStroke(for: colorScheme), lineWidth: 1)
                )
        )
    }
}

struct CopyValueRow: View {
    let title: String
    let value: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 11))
                .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                .frame(width: 120, alignment: .leading)

            Text(value)
                .font(.custom("Menlo", size: 11))
                .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                .lineLimit(1)
                .textSelection(.enabled)

            Spacer()

            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            .buttonStyle(.borderless)
            .font(.custom("Avenir Next Demi Bold", size: 11))
            .foregroundStyle(CrabTheme.primaryTint(for: colorScheme))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(CrabTheme.inputFill(for: colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(CrabTheme.inputStroke(for: colorScheme), lineWidth: 1)
                )
        )
    }
}

struct MethodBadge: View {
    let method: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(method)
            .font(.custom("Avenir Next Demi Bold", size: 10))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(methodTint)
            )
    }

    private var methodTint: Color {
        switch method {
        case "GET":
            return CrabTheme.secondaryTint(for: colorScheme)
        case "POST":
            return CrabTheme.primaryTint(for: colorScheme)
        case "PUT", "PATCH":
            return CrabTheme.warningTint(for: colorScheme)
        case "DELETE":
            return CrabTheme.destructiveTint(for: colorScheme)
        default:
            return CrabTheme.neutralTint(for: colorScheme)
        }
    }
}

struct ValuePill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.custom("Avenir Next Demi Bold", size: 11))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous).fill(tint.opacity(0.85))
            )
    }
}

struct DetailLine: View {
    let title: String
    let value: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.custom("Menlo", size: 11))
                .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                .textSelection(.enabled)
        }
    }
}

struct EmptyRuleHint: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(.custom("Avenir Next Medium", size: 13))
            .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }
}

struct ProxyBackground: View {
    let animateBackground: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: CrabTheme.backgroundGradient(for: colorScheme),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(CrabTheme.primaryTint(for: colorScheme).opacity(colorScheme == .light ? 0.24 : 0.23))
                .frame(width: 420, height: 420)
                .blur(radius: 40)
                .offset(x: animateBackground ? 220 : 130, y: -180)

            Circle()
                .fill(CrabTheme.secondaryTint(for: colorScheme).opacity(colorScheme == .light ? 0.2 : 0.18))
                .frame(width: 500, height: 500)
                .blur(radius: 48)
                .offset(x: animateBackground ? -280 : -120, y: 250)
        }
    }
}

struct LabeledField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                .frame(width: 52, alignment: .leading)

            TextField(placeholder, text: $text)
                .font(.custom("Avenir Next Medium", size: 12))
                .textFieldStyle(.plain)
                .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(CrabTheme.inputFill(for: colorScheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(CrabTheme.inputStroke(for: colorScheme), lineWidth: 1)
                        )
                )
        }
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let tint: Color
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                    .font(.custom("Avenir Next Demi Bold", size: 12))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint, tint.opacity(0.72)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

struct StatusBadge: View {
    let isRunning: Bool
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isRunning ? Color.green : Color.gray.opacity(0.6))
                .frame(width: 8, height: 8)
                .shadow(color: isRunning ? Color.green.opacity(0.7) : .clear, radius: 8)
            Text(text)
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .lineLimit(1)
        }
        .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule(style: .continuous).fill(CrabTheme.softFill(for: colorScheme)))
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}

struct GlassCard: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(CrabTheme.glassFill(for: colorScheme))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(CrabTheme.panelStroke(for: colorScheme), lineWidth: 1)
            )
    }
}
