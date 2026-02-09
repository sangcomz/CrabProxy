import AppKit
import SwiftUI

private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

struct CodeBlock: View {
    let text: String?
    let placeholder: String
    var showCopyButton = true
    var copyButtonLabel = "Copy All"
    var copyPayload: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    private var renderedText: String {
        guard let text, !text.isEmpty else { return placeholder }
        return text
    }

    private var hasContent: Bool {
        guard let text else { return false }
        return !text.isEmpty
    }

    private var effectiveCopyPayload: String? {
        if let copyPayload {
            return copyPayload
        }
        return hasContent ? renderedText : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showCopyButton {
                HStack {
                    Spacer()
                    Button(copyButtonLabel) {
                        guard let payload = effectiveCopyPayload else { return }
                        copyToPasteboard(payload)
                    }
                    .buttonStyle(.borderless)
                    .font(.custom("Avenir Next Demi Bold", size: 11))
                    .foregroundStyle(CrabTheme.primaryTint(for: colorScheme))
                    .disabled(effectiveCopyPayload == nil)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }

            TextEditor(text: .constant(renderedText))
                .textSelection(.enabled)
                .font(.custom("Menlo", size: 11))
                .foregroundStyle(
                    hasContent
                        ? CrabTheme.primaryText(for: colorScheme).opacity(0.92)
                        : CrabTheme.secondaryText(for: colorScheme)
                )
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
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

private struct HeaderFieldItem: Identifiable {
    let id = UUID()
    let name: String
    let value: String

    var line: String {
        if value.isEmpty {
            return "\(name):"
        }
        return "\(name): \(value)"
    }
}

private struct HeaderFieldRow: View {
    let field: HeaderFieldItem
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(field.name):")
                .font(.custom("Avenir Next Demi Bold", size: 11))
                .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                .frame(width: 168, alignment: .leading)

            Text(field.value.isEmpty ? "<empty>" : field.value)
                .font(.custom("Menlo", size: 11))
                .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Copy") {
                copyToPasteboard(field.line)
            }
            .buttonStyle(.borderless)
            .font(.custom("Avenir Next Demi Bold", size: 11))
            .foregroundStyle(CrabTheme.primaryTint(for: colorScheme))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(CrabTheme.softFill(for: colorScheme))
        )
        .contextMenu {
            Button("Copy Header") {
                copyToPasteboard(field.line)
            }
            Button("Copy Value") {
                copyToPasteboard(field.value)
            }
        }
    }
}

struct HeaderBlock: View {
    let text: String?
    let placeholder: String
    @Environment(\.colorScheme) private var colorScheme

    private var fields: [HeaderFieldItem] {
        Self.parseHeaderFields(from: text)
    }

    private var copyPayload: String? {
        guard !fields.isEmpty else { return nil }
        return fields.map(\.line).joined(separator: "\n")
    }

    var body: some View {
        if fields.isEmpty {
            CodeBlock(text: nil, placeholder: placeholder, showCopyButton: false)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer()
                    Button("Copy All") {
                        guard let copyPayload else { return }
                        copyToPasteboard(copyPayload)
                    }
                    .buttonStyle(.borderless)
                    .font(.custom("Avenir Next Demi Bold", size: 11))
                    .foregroundStyle(CrabTheme.primaryTint(for: colorScheme))
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(fields) { field in
                            HeaderFieldRow(field: field)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .frame(minHeight: 120)
            }
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

    private static func parseHeaderFields(from raw: String?) -> [HeaderFieldItem] {
        guard let raw else { return [] }
        return raw
            .split(whereSeparator: \.isNewline)
            .compactMap { segment -> HeaderFieldItem? in
                let line = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return nil }
                guard let separator = line.firstIndex(of: ":") else {
                    return HeaderFieldItem(name: line, value: "")
                }
                let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                let valueStart = line.index(after: separator)
                let value = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
                return HeaderFieldItem(name: name, value: value)
            }
    }
}

private struct JSONFieldItem: Identifiable {
    let id = UUID()
    let path: String
    let value: String

    var line: String {
        "\(path): \(value)"
    }
}

private struct JSONFieldRow: View {
    let field: JSONFieldItem
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(field.path)
                .font(.custom("Avenir Next Demi Bold", size: 11))
                .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                .frame(width: 190, alignment: .leading)

            Text(field.value)
                .font(.custom("Menlo", size: 11))
                .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Copy") {
                copyToPasteboard(field.value)
            }
            .buttonStyle(.borderless)
            .font(.custom("Avenir Next Demi Bold", size: 11))
            .foregroundStyle(CrabTheme.primaryTint(for: colorScheme))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(CrabTheme.softFill(for: colorScheme))
        )
        .contextMenu {
            Button("Copy Value") {
                copyToPasteboard(field.value)
            }
            Button("Copy Path") {
                copyToPasteboard(field.path)
            }
            Button("Copy Field") {
                copyToPasteboard(field.line)
            }
        }
    }
}

private struct ParsedJSONBody {
    let prettyText: String
    let fields: [JSONFieldItem]
}

private struct JSONFieldsBlock: View {
    let fields: [JSONFieldItem]
    @Environment(\.colorScheme) private var colorScheme

    private var copyPayload: String {
        fields.map(\.line).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("JSON Fields")
                    .font(.custom("Avenir Next Demi Bold", size: 11))
                    .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                Spacer()
                Button("Copy All Fields") {
                    copyToPasteboard(copyPayload)
                }
                .buttonStyle(.borderless)
                .font(.custom("Avenir Next Demi Bold", size: 11))
                .foregroundStyle(CrabTheme.primaryTint(for: colorScheme))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(fields) { field in
                        JSONFieldRow(field: field)
                    }
                }
            }
            .frame(minHeight: 90, maxHeight: 220)
        }
        .padding(10)
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

struct BodyBlock: View {
    let text: String?
    let placeholder: String
    @State private var mode: BodyViewMode = .json

    private enum BodyViewMode: String, CaseIterable, Identifiable {
        case json = "JSON"
        case fields = "Fields"

        var id: String { rawValue }
    }

    private var parsedJSON: ParsedJSONBody? {
        guard let text, !text.isEmpty else { return nil }
        guard let data = text.data(using: .utf8) else { return nil }
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }
        guard JSONSerialization.isValidJSONObject(jsonObject) else { return nil }
        guard
            let prettyData = try? JSONSerialization.data(
                withJSONObject: jsonObject,
                options: [.prettyPrinted, .sortedKeys]
            ),
            let prettyText = String(data: prettyData, encoding: .utf8)
        else {
            return nil
        }

        var fields: [JSONFieldItem] = []
        flattenJSON(value: jsonObject, path: "$", output: &fields)
        return ParsedJSONBody(prettyText: prettyText, fields: fields)
    }

    var body: some View {
        if let parsedJSON {
            VStack(alignment: .leading, spacing: 10) {
                if parsedJSON.fields.isEmpty {
                    CodeBlock(
                        text: parsedJSON.prettyText,
                        placeholder: placeholder,
                        copyButtonLabel: "Copy JSON",
                        copyPayload: parsedJSON.prettyText
                    )
                } else {
                    Picker("", selection: $mode) {
                        ForEach(BodyViewMode.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if mode == .fields {
                        JSONFieldsBlock(fields: parsedJSON.fields)
                    } else {
                        CodeBlock(
                            text: parsedJSON.prettyText,
                            placeholder: placeholder,
                            copyButtonLabel: "Copy JSON",
                            copyPayload: parsedJSON.prettyText
                        )
                    }
                }
            }
        } else {
            CodeBlock(text: text, placeholder: placeholder)
        }
    }

    private func flattenJSON(value: Any, path: String, output: inout [JSONFieldItem]) {
        if let dictionary = value as? [String: Any] {
            if dictionary.isEmpty {
                output.append(JSONFieldItem(path: path, value: "{}"))
                return
            }
            for key in dictionary.keys.sorted() {
                guard let nested = dictionary[key] else { continue }
                let nextPath = path == "$" ? "$.\(key)" : "\(path).\(key)"
                flattenJSON(value: nested, path: nextPath, output: &output)
            }
            return
        }

        if let array = value as? [Any] {
            if array.isEmpty {
                output.append(JSONFieldItem(path: path, value: "[]"))
                return
            }
            for (index, nested) in array.enumerated() {
                flattenJSON(value: nested, path: "\(path)[\(index)]", output: &output)
            }
            return
        }

        output.append(JSONFieldItem(path: path, value: stringifyLeaf(value)))
    }

    private func stringifyLeaf(_ value: Any) -> String {
        if let string = value as? String {
            return string
        }
        if value is NSNull {
            return "null"
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        return String(describing: value)
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
                copyToPasteboard(value)
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
