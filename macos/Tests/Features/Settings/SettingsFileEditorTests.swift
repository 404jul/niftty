import Testing
@testable import Ghostty

struct SettingsFileEditorTests {
    @Test func settingsReplaceGloballyAndRemoveLegacyBlock() {
        let original = """
        # Hand-written setting
        font-size = 14

        \(SettingsFileEditor.beginMarker)
        # This block is maintained by Niftty Settings.
        font-size =
        font-size = 16
        font-family =
        font-family = Menlo
        font-family = Monaco
        \(SettingsFileEditor.endMarker)
        """

        let updated = SettingsFileEditor.replacingSettings(
            in: original,
            values: [
                "font-size": "18",
                "font-family": "Menlo\nMonaco",
                "theme": "dark",
            ],
            orderedNames: ["font-size", "font-family", "theme"],
            repeatableNames: ["font-family"])

        #expect(updated.contains("# Hand-written setting\nfont-size = 18"))
        #expect(updated.contains("font-family =\nfont-family = Menlo\nfont-family = Monaco"))
        #expect(updated.contains("theme = dark"))
        #expect(!updated.contains(SettingsFileEditor.beginMarker))
        #expect(!updated.contains("This block is maintained"))
        #expect(updated.components(separatedBy: "\n").filter { $0 == "font-size = 18" }.count == 1)
    }

    @Test func duplicateScalarSettingsCollapseAtTheirOriginalPosition() {
        let original = """
        # Appearance
        theme = old
        background-opacity = 0.5
        theme = duplicate

        # Input
        mouse-hide-while-typing = true
        """

        let updated = SettingsFileEditor.replacingSettings(
            in: original,
            values: ["theme": "0x96f", "background-opacity": "0.95"],
            orderedNames: ["theme", "background-opacity"],
            repeatableNames: [])

        #expect(updated == """
        # Appearance
        theme = 0x96f
        background-opacity = 0.95

        # Input
        mouse-hide-while-typing = true
        """)
    }

    @Test func legacyOverridesRemainReadableForMigration() {
        let text = """
        \(SettingsFileEditor.beginMarker)
        theme =
        theme = 0x96f
        font-family =
        font-family = Menlo
        font-family = Monaco
        \(SettingsFileEditor.endMarker)
        """

        #expect(SettingsFileEditor.legacyOverrides(in: text) == [
            "theme": "0x96f",
            "font-family": "Menlo\nMonaco",
        ])
    }

    @Test func emptyDefaultsDescribeTheirEffectiveBehavior() {
        func setting(_ name: String, defaultValue: String = "") -> Ghostty.ConfigEditorSetting {
            Ghostty.ConfigEditorSetting(
                name: name,
                description: "",
                value: defaultValue,
                defaultValue: defaultValue,
                kind: .text,
                options: [],
                repeatable: false)
        }

        let theme = setting("theme")
        let language = setting("language")
        let fontSize = setting("font-size", defaultValue: "13")
        let settings = [
            theme,
            language,
            fontSize,
            setting("background", defaultValue: "#282c34"),
            setting("foreground", defaultValue: "#ffffff"),
        ]

        #expect(SettingsModel.defaultDisplayValue(for: theme, in: settings) ==
            "Built-in (#282c34 / #ffffff)")
        #expect(SettingsModel.defaultDisplayValue(for: language, in: settings) == "Unset")
        #expect(SettingsModel.defaultDisplayValue(for: fontSize, in: settings) == "13")
    }

    @Test func categoryFallbackIsNeverEmptyOrAll() {
        #expect(SettingsModel.category(for: "theme") == "Appearance")
        #expect(SettingsModel.category(for: "language") == "Terminal")
        #expect(SettingsModel.category(for: "unrecognized-future-key") == "Terminal")
        #expect(SettingsModel.category(for: "unrecognized-future-key") != "All")
    }
}
