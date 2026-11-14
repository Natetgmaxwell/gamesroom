//
//  TestsCasinoVisible.swift
//  games-room
//
//  Task CV — "make Casino visible: in the picker and in what members
//  see".
//
//  One rule, three surfaces:
//
//    the host's picker rows        → NightPackPicker.rows
//    the host's tickable set       → NightPackPicker.tickableSet
//    the member-facing pack line   → NightPackOrder.displayNames /
//                                    NightPackOrder.caption
//
//  Foundation only; every case drives the production types in
//  `GamesRoom/Models/NextNight.swift`. The rule is pinned HERE, not
//  copied here: the views ask these types, so the picker and the
//  member's card cannot drift apart.
//

import Foundation

func runCasinoVisibleTests(_ runner: TestRunner) {
    runCasinoVisiblePickerTests(runner)
    runCasinoVisibleMemberTests(runner)
}

// MARK: - The host's picker

private func runCasinoVisiblePickerTests(_ runner: TestRunner) {
    // (label, the picker's catalog, the rows the host sees)
    let rowCases: [(String, [String], [String])] = [
        ("the registry's catalog",
         ["casino", "cards_against_humanity", "monopoly_deal"],
         ["casino", "cards_against_humanity", "monopoly_deal"]),
        ("a catalog that lists another pack first",
         ["monopoly_deal", "cards_against_humanity"],
         ["casino", "monopoly_deal", "cards_against_humanity"]),
        ("a catalog that leaves casino out",
         ["monopoly_deal"],
         ["casino", "monopoly_deal"]),
        ("a catalog that lists casino twice",
         ["casino", "casino", "monopoly_deal"],
         ["casino", "monopoly_deal"]),
        ("an empty catalog",
         [],
         ["casino"]),
    ]
    for (label, catalog, expected) in rowCases {
        runner.run("Picker rows: \(label)") {
            runner.assertEqual(NightPackPicker.rows(catalog: catalog), expected)
        }
    }

    runner.run("Picker rows: the live registry lists casino first, and casino is the only always-on pack") {
        runner.assertEqual(NightPackPicker.rows(),
                           ["casino", "cards_against_humanity", "monopoly_deal"])
        runner.assertTrue(NightPackPicker.isAlwaysOn("casino"))
        runner.assertFalse(NightPackPicker.isAlwaysOn("monopoly_deal"))
        runner.assertFalse(NightPackPicker.isAlwaysOn("cards_against_humanity"))
    }

    // (label, the saved night's packs, the tickable set the picker starts from)
    let seedCases: [(String, [String], [String])] = [
        ("a night saved with casino and a game",
         ["casino", "monopoly_deal"],
         ["monopoly_deal"]),
        ("a night saved with casino only",
         ["casino"],
         []),
        ("a night saved with casino in front of two games",
         ["casino", "cards_against_humanity", "monopoly_deal"],
         ["cards_against_humanity", "monopoly_deal"]),
        ("a night saved with the game before casino",
         ["monopoly_deal", "casino"],
         ["monopoly_deal"]),
        ("a night saved with a pack the registry dropped",
         ["casino", "blackjack"],
         []),
        ("a night saved with nothing",
         [],
         []),
    ]
    for (label, seed, expected) in seedCases {
        runner.run("Picker tickable set: \(label)") {
            runner.assertEqual(NightPackPicker.tickableSet(seed: seed), expected)
        }
    }

    runner.run("Picker tickable set: the always-on pack is never in it, whatever the seed") {
        // The row is readonly, so the slug must never enter the tick
        // state — not from a seed, not from a tap.
        let seeds: [[String]] = [
            ["casino"],
            ["casino", "monopoly_deal"],
            ["monopoly_deal", "casino"],
            ["casino", "casino"],
        ]
        for seed in seeds {
            runner.assertFalse(
                NightPackPicker.tickableSet(seed: seed).contains(NightPackPicker.alwaysOnSlug),
                "seed \(seed) must not tick the always-on pack"
            )
        }
    }

    runner.run("Picker rows and tickable set: the rows show every registered pack, the tick set never shows casino twice") {
        let rows = NightPackPicker.rows()
        let tickable = NightPackPicker.tickableSet(seed: rows)
        // The only difference between the rows and the tick set is the
        // always-on pack: it is listed, but it is never tickable.
        runner.assertEqual(rows.count, tickable.count + 1)
        runner.assertEqual(tickable, ["cards_against_humanity", "monopoly_deal"])
    }
}

// MARK: - What a member reads

private func runCasinoVisibleMemberTests(_ runner: TestRunner) {
    // (label, the night's packs, the names a member reads)
    let nameCases: [(String, [String], [String])] = [
        ("a casino night",
         ["casino"],
         ["Casino"]),
        ("a casino night with a game",
         ["casino", "monopoly_deal"],
         ["Casino", "Monopoly Deal"]),
        ("a night saved with the game before casino",
         ["monopoly_deal", "casino"],
         ["Casino", "Monopoly Deal"]),
        ("a night saved without casino",
         ["monopoly_deal"],
         ["Casino", "Monopoly Deal"]),
        ("a night with every pack",
         ["cards_against_humanity", "monopoly_deal", "casino"],
         ["Casino", "Cards Against Humanity", "Monopoly Deal"]),
        ("a night with a pack the registry dropped",
         ["casino", "blackjack"],
         ["Casino"]),
        ("a night with no packs at all",
         [],
         ["Casino"]),
    ]
    for (label, packSlugs, expected) in nameCases {
        runner.run("Member pack list: \(label)") {
            runner.assertEqual(NightPackOrder.displayNames(for: packSlugs), expected)
            runner.assertEqual(NightPackOrder.caption(for: packSlugs), expected.joined(separator: " · "))
        }
    }

    runner.run("Member pack list: casino leads, and it appears once") {
        runner.assertEqual(NightPackOrder.displayNames(for: ["casino", "monopoly_deal", "casino"]),
                           ["Casino", "Monopoly Deal"])
        runner.assertEqual(NightPackOrder.displayNames(for: ["monopoly_deal"]),
                           ["Casino", "Monopoly Deal"])
    }

    runner.run("Member pack line: the line reads 'Casino · Monopoly Deal'") {
        // The exact line under the venue on the member's card.
        runner.assertEqual(NightPackOrder.caption(for: ["casino", "monopoly_deal"]),
                           "Casino · Monopoly Deal")
        runner.assertEqual(NightPackOrder.caption(for: ["casino"]), "Casino")
        runner.assertEqual(NightPackOrder.caption(for: ["monopoly_deal", "cards_against_humanity"]),
                           "Casino · Monopoly Deal · Cards Against Humanity")
    }

    runner.run("Member pack line: it is never empty — every night is a casino night") {
        runner.assertFalse(NightPackOrder.caption(for: []).isEmpty)
        runner.assertFalse(NightPackOrder.caption(for: ["blackjack"]).isEmpty)
    }
}
