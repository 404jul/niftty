import Testing
@testable import Ghostty

struct SettingsFileEditorTests {
    @Test func managedSettingsReplaceWithoutTouchingManualConfig() {
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

        let updated = SettingsFileEditor.replacingManagedBlock(
            in: original,
            overrides: ["font-size": "18", "theme": "dark"],
            orderedNames: ["font-size", "theme"])

        #expect(updated.contains("# Hand-written setting\nfont-size = 14"))
        #expect(updated.contains("font-size =\nfont-size = 18"))
        #expect(updated.contains("theme =\ntheme = dark"))
        #expect(!updated.contains("font-family = Menlo"))
        #expect(SettingsFileEditor.overrides(in: updated) == [
            "font-size": "18",
            "theme": "dark",
        ])
    }

    @Test func repeatedValuesRoundTrip() {
        let updated = SettingsFileEditor.replacingManagedBlock(
            in: "font-size = 13\n",
            overrides: ["font-family": "Menlo\nMonaco"],
            orderedNames: ["font-family"])

        #expect(SettingsFileEditor.overrides(in: updated)["font-family"] == "Menlo\nMonaco")
        #expect(updated.contains("font-family =\nfont-family = Menlo\nfont-family = Monaco"))
    }

    @Test func categoryFallbackIsNeverEmptyOrAll() {
        #expect(SettingsModel.category(for: "theme") == "Appearance")
        #expect(SettingsModel.category(for: "language") == "Terminal")
        #expect(SettingsModel.category(for: "unrecognized-future-key") == "Terminal")
        #expect(SettingsModel.category(for: "unrecognized-future-key") != "All")
    }
}
