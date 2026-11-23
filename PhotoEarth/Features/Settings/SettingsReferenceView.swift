import SwiftUI

enum SettingsReference: String, Identifiable {
    case privacy, credits
    var id: Self { self }

    private var policyLanguage: String {
        AppLocalization.localeIdentifier.hasPrefix("zh") ? "zh" : "en"
    }

    var title: String {
        switch self {
        case .privacy: String(localized: "settings.policy")
        case .credits: String(localized: "settings.music.credits")
        }
    }

    var passages: [String] {
        let file = self == .credits ? "OnlineMusicCredits"
            : "PhotoEarthPrivacy-" + (policyLanguage == "zh" ? "zh-Hans" : "en-US")
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        if self == .privacy {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n\n")
        }
        return text.components(separatedBy: .newlines).compactMap { line in
            let fields = line.components(separatedBy: " — ")
            guard fields.count == 3, let host = URL(string: fields[2])?.host else { return nil }
            return "\(fields[0]) — \(fields[1])\n\(host)"
        }
    }
}

struct SettingsReferenceView: View {
    let reference: SettingsReference
    private let passages: [String]
    @Environment(\.dismiss) private var dismiss

    init(reference: SettingsReference) {
        self.reference = reference
        passages = reference.passages
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text(reference.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(String(localized: "common.done")) { dismiss() }.buttonStyle(.glass)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(passages.indices, id: \.self) { index in
                        Text(verbatim: passages[index])
                            .font(.system(size: 28))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .focusable()
                            .accessibilityIdentifier("settings-reference-passage-\(index)")
                    }
                }
                .padding(.horizontal, 18)
            }
            .focusSection()
        }
        .padding(60)
        .frame(width: 1360, height: 850, alignment: .topLeading)
    }
}
