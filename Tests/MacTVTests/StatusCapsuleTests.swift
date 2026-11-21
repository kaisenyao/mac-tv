import Testing
@testable import MacTV

/// Home's status row as tvOS 26's: the avatar drops the profiles down under it, in a grid of two columns.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct StatusCapsuleTests {
    @Test func theAvatarDropsTheProfilesDown() async throws {
        try await InteractionTests.withTV { tv in
            _ = tv.profiles.add(named: "Elton")
            _ = tv.profiles.add(named: "Nisha")
            tv.setFocus(.status(.profile))
            tv.activateStatus(.profile)
            #expect(tv.profilePicker?.dropdown == true && tv.profilePicker?.index == 0)   // on the one watching
            // Kaisen  Elton
            // Nisha   Add Profile
            tv.handle(.move(.right), from: .remote)
            #expect(tv.profilePicker?.index == 1)
            tv.handle(.move(.right), from: .remote)
            #expect(tv.profilePicker?.index == 1, "the end of the row")
            tv.handle(.move(.down), from: .remote)
            #expect(tv.profilePicker?.index == 3)
            tv.handle(.move(.left), from: .remote)
            #expect(tv.profilePicker?.index == 2)
            tv.handle(.move(.up), from: .remote)
            tv.handle(.move(.up), from: .remote)
            #expect(tv.profilePicker == nil && tv.focus == .status(.profile), "up from the top row: back in the row")
        }
    }

    @Test func addProfileGoesOnToNamingIt() async throws {
        try await InteractionTests.withTV { tv in
            tv.openProfiles(dropdown: true)
            tv.handle(.move(.right), from: .remote)   // Add Profile, beside the only profile
            tv.handle(.select, from: .remote)
            #expect(tv.profilePicker?.naming == "" && tv.profilePicker?.dropdown == false)
        }
    }

    @Test func choosingAProfileSwitchesToIt() async throws {
        try await InteractionTests.withTV { tv in
            let elton = tv.profiles.add(named: "Elton")
            tv.openProfiles(dropdown: true)
            tv.handle(.move(.right), from: .remote)
            tv.handle(.select, from: .remote)
            #expect(tv.profilePicker == nil && tv.profile.id == elton.id)
        }
    }
}
