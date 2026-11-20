import Testing
@testable import MacTV

/// The Movies app's focus: the posters, and the Settings button above them that opens the Folders sheet.
@Suite(.timeLimit(.minutes(1))) @MainActor struct MoviesBrowserTests {
    @Test func upFromTheTopRowReachesSettingsAndDownComesBack() {
        var browser = MoviesBrowser()
        let lengths = [3, 7, 2]
        browser.move(.right, lengths: lengths)
        browser.move(.up, lengths: lengths)
        #expect(browser.settingsFocused)
        // Left and Right stay on the button; Down returns to the poster it came from.
        browser.move(.left, lengths: lengths)
        browser.move(.right, lengths: lengths)
        #expect(browser.settingsFocused)
        browser.move(.down, lengths: lengths)
        #expect(!browser.settingsFocused && browser.row == 0 && browser.column == 1)

        // Lower rows step up one row at a time; only the top row leads to the button.
        browser.move(.down, lengths: lengths)
        browser.move(.down, lengths: lengths)
        #expect(browser.row == 2 && browser.column == 1)
        browser.move(.up, lengths: lengths)
        #expect(!browser.settingsFocused && browser.row == 1)
        browser.move(.up, lengths: lengths)
        browser.move(.up, lengths: lengths)
        #expect(browser.settingsFocused)
    }

    @Test func withNoMoviesSettingsIsAllThereIs() {
        var browser = MoviesBrowser()
        for direction in [RemoteCommand.Direction.down, .left, .right, .up] {
            browser.move(direction, lengths: [])
        }
        #expect(browser == MoviesBrowser())   // nothing to move to; the screen shows the button focused
    }

    @Test func addFolderComesFirstOnTheFoldersSheet() {
        #expect(TVController.FolderAdder.allCases == [.folder, .networkShare, .jellyfin])
    }
}
