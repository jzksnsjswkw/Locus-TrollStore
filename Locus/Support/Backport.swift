import SwiftUI
import UIKit

/// NavigationStack on iOS 16+, stack-style NavigationView on iOS 15.
struct LocusNavStack<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { content }
        } else {
            NavigationView { content }
                .navigationViewStyle(.stack)
        }
    }
}

/// LabeledContent on iOS 16+, HStack replica on iOS 15.
struct LocusLabeledRow<Value: View>: View {
    private let title: String
    private let value: Value

    init(_ title: String, value text: String) where Value == Text {
        self.title = title
        self.value = Text(text)
    }

    init(_ title: String, @ViewBuilder value: () -> Value) {
        self.title = title
        self.value = value()
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            LabeledContent(title) { value }
        } else {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 12)
                value
                    .multilineTextAlignment(.trailing)
                    .foregroundColor(.secondary)
            }
        }
    }
}

extension View {
    @ViewBuilder
    func locusMediumLargeDetents() -> some View {
        if #available(iOS 16.0, *) {
            presentationDetents([.medium, .large])
        } else {
            self
        }
    }

    @ViewBuilder
    func locusScrollIndicatorsHidden() -> some View {
        if #available(iOS 16.0, *) {
            scrollIndicators(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func locusScrollContentBackgroundHidden() -> some View {
        if #available(iOS 16.0, *) {
            scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}

enum LegacyCompatibility {
    // iOS 15 has no per-list background API; the appearance proxy is the only
    // way to keep List rows transparent over the map backdrop.
    static func applyListAppearance() {
        if #unavailable(iOS 16.0) {
            UITableView.appearance().backgroundColor = .clear
        }
    }

    // iOS 14 has no listRowSeparator(.hidden); clear separators globally.
    static func applyHiddenSeparators() {
        if #unavailable(iOS 15.0) {
            UITableView.appearance().separatorColor = .clear
        }
    }
}

/// TimelineView on iOS 15+; Timer-driven backport on iOS 14.
/// Only the closure's `date` is consumed by call sites, so a plain ticking
/// date reproduces the same output at either interval granularity.
struct LocusTimelineView<Content: View>: View {
    private let interval: TimeInterval
    private let content: (Date) -> Content

    @State private var now: Date = Date()

    init(
        _ interval: TimeInterval,
        @ViewBuilder content: @escaping (Date) -> Content
    ) {
        self.interval = interval
        self.content = content
    }

    var body: some View {
        if #available(iOS 15.0, *) {
            TimelineView(.periodic(from: .now, by: max(interval, 0.001))) { context in
                content(context.date)
            }
        } else {
            content(now)
                .onReceive(
                    Timer.publish(every: max(interval, 0.001), on: .main, in: .common).autoconnect()
                ) { date in
                    now = date
                }
        }
    }
}

/// FocusState is iOS 15+; bind a plain Binding<Bool> to real keyboard focus
/// there and degrade to a no-op on iOS 14 (the search UI still toggles via
/// the binding).
@available(iOS 15.0, *)
private struct LocusFocused15: ViewModifier {
    @Binding var isFocused: Bool
    @FocusState private var focus: Bool

    func body(content: Content) -> some View {
        content
            .focused($focus)
            .onChange(of: isFocused) { newValue in
                if newValue && !focus { focus = true }
            }
            .onChange(of: focus) { focused in
                if focused != isFocused { isFocused = focused }
            }
    }
}

extension View {
    @ViewBuilder
    func locusFocused(_ isFocused: Binding<Bool>) -> some View {
        if #available(iOS 15.0, *) {
            modifier(LocusFocused15(isFocused: isFocused))
        } else {
            self
        }
    }

    @ViewBuilder
    func locusAutocapitalizationNever() -> some View {
        if #available(iOS 15.0, *) {
            textInputAutocapitalization(.never)
        } else {
            autocapitalization(.none)
        }
    }

    @ViewBuilder
    func locusAutocapitalizationWords() -> some View {
        if #available(iOS 15.0, *) {
            textInputAutocapitalization(.words)
        } else {
            autocapitalization(.words)
        }
    }

    @ViewBuilder
    func locusAutocorrectionDisabled() -> some View {
        if #available(iOS 15.0, *) {
            autocorrectionDisabled()
        } else {
            disableAutocorrection(true)
        }
    }

    @ViewBuilder
    func locusSubmitLabelSearch() -> some View {
        if #available(iOS 15.0, *) {
            submitLabel(.search)
        } else {
            self
        }
    }

    /// Alert with a single OK button (the modern `alert(_:isPresented:actions:message:)`
    /// is iOS 15+; fall back to `Alert` on iOS 14).
    @ViewBuilder
    func locusAlert(
        _ title: String,
        isPresented: Binding<Bool>,
        okTitle: String,
        onOK: @escaping () -> Void,
        message: String
    ) -> some View {
        if #available(iOS 15.0, *) {
            alert(title, isPresented: isPresented) {
                Button(okTitle, role: .cancel) { onOK() }
            } message: {
                Text(message)
            }
        } else {
            alert(isPresented: isPresented) {
                Alert(
                    title: Text(title),
                    message: Text(message),
                    dismissButton: .default(Text(okTitle)) { onOK() }
                )
            }
        }
    }

    /// Alert with a destructive confirm + cancel.
    @ViewBuilder
    func locusConfirmAlert(
        _ title: String,
        isPresented: Binding<Bool>,
        confirmTitle: String,
        onConfirm: @escaping () -> Void,
        message: String
    ) -> some View {
        if #available(iOS 15.0, *) {
            alert(title, isPresented: isPresented) {
                Button(confirmTitle, role: .destructive) { onConfirm() }
                Button(L("取消"), role: .cancel) {}
            } message: {
                Text(message)
            }
        } else {
            alert(isPresented: isPresented) {
                Alert(
                    title: Text(title),
                    message: Text(message),
                    primaryButton: .destructive(Text(confirmTitle)) { onConfirm() },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    /// confirmationDialog on iOS 15+; actionSheet on iOS 14.
    @ViewBuilder
    func locusConfirmationDialog(
        _ title: String,
        isPresented: Binding<Bool>,
        confirmTitle: String,
        onConfirm: @escaping () -> Void,
        cancelTitle: String = L("取消"),
        message: String
    ) -> some View {
        if #available(iOS 15.0, *) {
            confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
                Button(confirmTitle) { onConfirm() }
                Button(cancelTitle, role: .cancel) {}
            } message: {
                Text(message)
            }
        } else {
            actionSheet(isPresented: isPresented) {
                ActionSheet(
                    title: Text(title),
                    message: Text(message),
                    buttons: [
                        .default(Text(confirmTitle)) { onConfirm() },
                        .cancel()
                    ]
                )
            }
        }
    }

    /// monospacedDigit() is iOS 15+; no-op on iOS 14.
    @ViewBuilder
    func locusMonospacedDigit() -> some View {
        if #available(iOS 15.0, *) {
            monospacedDigit()
        } else {
            self
        }
    }

    /// tint() is iOS 16+; fall back to accentColor on older.
    @ViewBuilder
    func locusTint(_ color: Color) -> some View {
        if #available(iOS 16.0, *) {
            tint(color)
        } else {
            accentColor(color)
        }
    }

    /// listRowSeparator(.hidden) is iOS 15+; clear separators globally on iOS 14.
    func locusListRowSeparatorHidden() -> some View {
        LegacyCompatibility.applyHiddenSeparators()
        return Group {
            if #available(iOS 15.0, *) {
                listRowSeparator(.hidden)
            } else {
                self
            }
        }
    }

    /// onSubmit is iOS 15+; no-op on iOS 14 (keyboard return just dismisses).
    @ViewBuilder
    func locusOnSubmit(_ action: @escaping () -> Void) -> some View {
        if #available(iOS 15.0, *) {
            onSubmit(action)
        } else {
            self
        }
    }

    /// Menu pickers render the selected value in the system accent blue on
    /// iOS 14 and iOS 16+; keep that platform-default look on iOS 14, but
    /// neutralize it to the secondary gray on iOS 15+ where the platform
    /// default is gray.
    @ViewBuilder
    func locusPickerStyleMenu() -> some View {
        if #available(iOS 15.0, *) {
            pickerStyle(.menu)
                .accentColor(.secondary)
        } else {
            pickerStyle(.menu)
        }
    }

    /// Row actions where deletion needs confirmation.
    ///
    /// `swipeActions` with a destructive role animates the row out as soon as the
    /// button is tapped, before any confirmation: the row slides away, comes
    /// back when the alert appears, and slides away again on confirm. A plain
    /// (non-destructive) swipe action and a plain context-menu button avoid that
    /// animation entirely; the confirmation closes it and the list animates once.
    @ViewBuilder
    func locusConfirmingRowActions(
        deleteTitle: String,
        onDelete: @escaping () -> Void,
        onRename: @escaping () -> Void
    ) -> some View {
        if #available(iOS 15.0, *) {
            swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button { onDelete() } label: {
                    Label(deleteTitle, systemImage: "trash.fill")
                }
                .tint(LocusTheme.danger)
                Button { onRename() } label: {
                    Label(L("重命名"), systemImage: "pencil")
                }
            }
        } else {
            contextMenu {
                Button(action: onDelete) {
                    Label(deleteTitle, systemImage: "trash.fill")
                }
                Button(action: onRename) {
                    Label(L("重命名"), systemImage: "pencil")
                }
            }
        }
    }

    /// Favorite row actions: swipe actions on iOS 15+, context-menu fallback on iOS 14.
    @ViewBuilder
    func locusFavoriteRowActions(
        onDelete: @escaping () -> Void,
        onRename: @escaping () -> Void
    ) -> some View {
        if #available(iOS 15.0, *) {
            swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { onDelete() } label: {
                    Label(L("删除"), systemImage: "trash.fill")
                }
                Button { onRename() } label: {
                    Label(L("重命名"), systemImage: "pencil")
                }
            }
        } else {
            contextMenu {
                Button(action: { onDelete() }) {
                    Label(L("删除"), systemImage: "trash.fill")
                }
                Button(action: { onRename() }) {
                    Label(L("重命名"), systemImage: "pencil")
                }
            }
        }
    }
}

extension Font {
    /// monospacedDigit() on Font is iOS 15+; plain on iOS 14.
    func locusMonospacedDigit() -> Font {
        if #available(iOS 15.0, *) { return monospacedDigit() }
        return self
    }
}

enum SFSymbolCompat {    // SF Symbols 4 glyphs render blank on iOS 15; fall back to the closest
    // SF Symbols 3 equivalents there. On iOS 14, SF Symbols 3 glyphs are also
    // missing, so fall back to SF Symbols 1/2 names.
    static func resolved(_ name: String) -> String {
        if #available(iOS 16.0, *) { return name }
        if #available(iOS 15.0, *) {
            switch name {
            case "figure.run": return "hare.fill"
            case "square.3.layers.3d": return "square.stack.3d.up.fill"
            case "road.lanes": return "point.topleft.down.curvedto.point.bottomright.up"
            default: return name
            }
        }
        switch name {
        case "figure.run": return "hare.fill"
        case "figure.walk": return "figure.walk"
        case "square.3.layers.3d": return "square.stack.3d.up.fill"
        case "road.lanes": return "arrow.up.right"
        case "speedometer": return "dial"
        default: return name
        }
    }
}

/// Native text-field alert on iOS 16+; UIAlertController on iOS 15, whose
/// SwiftUI alert cannot host text fields.
struct LocusRenameAlertModifier: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let message: String
    let placeholder: String
    @Binding var text: String
    var onSave: () -> Void

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.alert(title, isPresented: $isPresented) {
                TextField(placeholder, text: $text)
                Button(L("取消"), role: .cancel) {}
                Button(L("保存")) { onSave() }
                    .disabled(!canSave)
            } message: {
                Text(message)
            }
        } else {
            content.onChange(of: isPresented) { shown in
                guard shown else { return }
                DispatchQueue.main.async {
                    Self.presentUIKitAlert(
                        title: title,
                        message: message,
                        placeholder: placeholder,
                        initialText: text,
                        canSave: canSave
                    ) { newText in
                        text = newText
                        onSave()
                        isPresented = false
                    } onCancel: {
                        isPresented = false
                    }
                }
            }
        }
    }

    private static func presentUIKitAlert(
        title: String,
        message: String,
        placeholder: String,
        initialText: String,
        canSave: Bool,
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }),
            var base = window.rootViewController else {
            onCancel()
            return
        }
        while let presented = base.presentedViewController {
            base = presented
        }

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let emptyGuard = TextFieldEmptyGuard()

        alert.addTextField { field in
            field.placeholder = placeholder
            field.text = initialText
            field.addTarget(emptyGuard, action: #selector(TextFieldEmptyGuard.textChanged(_:)), for: .editingChanged)
        }

        let save = UIAlertAction(title: L("保存"), style: .default) { [weak alert] _ in
            onSave(alert?.textFields?.first?.text ?? "")
        }
        save.isEnabled = canSave || !initialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        alert.addAction(save)

        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel) { _ in
            onCancel()
        })

        emptyGuard.alert = alert
        base.present(alert, animated: true)
    }
}

/// Keeps the save action of a rename alert disabled until the field has
/// non-whitespace content. Retained by the text field's target/action.
private final class TextFieldEmptyGuard: NSObject {
    weak var alert: UIAlertController?

    @objc func textChanged(_ sender: UITextField) {
        guard let save = alert?.actions.last else { return }
        save.isEnabled = !(sender.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }
}

extension View {
    func locusRenameAlert(
        isPresented: Binding<Bool>,
        title: String,
        message: String,
        placeholder: String = L("名称"),
        text: Binding<String>,
        onSave: @escaping () -> Void
    ) -> some View {
        modifier(
            LocusRenameAlertModifier(
                isPresented: isPresented,
                title: title,
                message: message,
                placeholder: placeholder,
                text: text,
                onSave: onSave
            )
        )
    }
}
