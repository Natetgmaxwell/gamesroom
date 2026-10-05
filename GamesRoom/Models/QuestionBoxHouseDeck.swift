//
//  QuestionBoxHouseDeck.swift
//  GamesRoom
//
//  V0.106 — the 40-question house deck, bundled (spec §1.2). Generated
//  from docs/V0.106_house_deck.json; migration 097 seeds the same list
//  server-side. main.swift asserts this copy matches the JSON.
//

import Foundation

enum QuestionTag: String, Codable, CaseIterable, Hashable {
    case deep
    case unhinged
}

enum QuestionBoxHouseDeck {
    struct Entry: Hashable {
        let text: String
        let tag: QuestionTag
    }

    static let entries: [Entry] = [
        Entry(text: "Which decade would you live in if you had to, and what would you miss most about now?", tag: .deep),
        Entry(text: "If you were a Transformer, what vehicle would you turn into?", tag: .unhinged),
        Entry(text: "Is it kinder to tell a mate the hard truth or let them find out?", tag: .deep),
        Entry(text: "Which person at this table would last longest in a zombie apocalypse, and who goes first?", tag: .unhinged),
        Entry(text: "What's one job everyone thinks is respectable that you think is mostly a scam?", tag: .deep),
        Entry(text: "What's the most ridiculous thing you'd do for a million dollars, as long as nobody filmed it?", tag: .unhinged),
        Entry(text: "Would you rather know the date you die or the way you die?", tag: .deep),
        Entry(text: "Rank everyone at the table by who'd be the worst to share a caravan with for a month?", tag: .unhinged),
        Entry(text: "What's one belief you held at 18 that you're embarrassed by now?", tag: .deep),
        Entry(text: "Which character from a kids' show is secretly the most unhinged?", tag: .unhinged),
        Entry(text: "Does keeping score in a relationship ever work?", tag: .deep),
        Entry(text: "If your life had a theme song that played whenever you walked in, what is it?", tag: .unhinged),
        Entry(text: "Which of your opinions would lose you a friend if you said it at a dinner party?", tag: .deep),
        Entry(text: "What's a completely normal thing that you find deeply suspicious?", tag: .unhinged),
        Entry(text: "Is being funny or being good-looking worth more in the long run?", tag: .deep),
        Entry(text: "What's a smell you secretly love that everyone else hates?", tag: .unhinged),
        Entry(text: "If you could abolish one law tomorrow, which one goes?", tag: .deep),
        Entry(text: "What's the most unhinged thing you've ever done to avoid a phone call?", tag: .unhinged),
        Entry(text: "Should you stay friends with someone whose politics you can't stand?", tag: .deep),
        Entry(text: "Which sitcom would your friend group fit into, and who plays who?", tag: .unhinged),
        Entry(text: "What's something everyone pretends to enjoy but secretly doesn't?", tag: .deep),
        Entry(text: "What's the most useless superpower you'd secretly love to have?", tag: .unhinged),
        Entry(text: "Who's a person you admire that most people have never heard of?", tag: .deep),
        Entry(text: "If you could ban one word from the English language forever, what goes?", tag: .unhinged),
        Entry(text: "What's the best piece of advice you ignored and later wish you hadn't?", tag: .deep),
        Entry(text: "What's the weirdest thing you believed as a kid for far too long?", tag: .unhinged),
        Entry(text: "What's one thing every 16-year-old should be taught that school skips?", tag: .deep),
        Entry(text: "Which table member would be the best at running a dodgy cult?", tag: .unhinged),
        Entry(text: "Would you take a pill that made you happy forever if it meant you'd never achieve anything again?", tag: .deep),
        Entry(text: "What would your last meal be if it also had to be your most embarrassing order?", tag: .unhinged),
        Entry(text: "Is it better to be respected or liked?", tag: .deep),
        Entry(text: "If animals could talk, which one would turn out to be the biggest jerk?", tag: .unhinged),
        Entry(text: "What's the most overrated milestone in life?", tag: .deep),
        Entry(text: "What's a perfectly good food you refuse to eat and can't defend?", tag: .unhinged),
        Entry(text: "Which job would you do for free, and which would you never take for any pay?", tag: .deep),
        Entry(text: "Which celebrity would you pick as your annoying flatmate for a year?", tag: .unhinged),
        Entry(text: "Which person, alive or dead, would you want to argue with for an hour, and about what?", tag: .deep),
        Entry(text: "What's the dumbest thing you'd name a dog?", tag: .unhinged),
        Entry(text: "Is ambition a virtue, or just insecurity that dresses better?", tag: .deep),
        Entry(text: "What's the funniest thing you've ever gotten in trouble for?", tag: .unhinged),
    ]

    /// Rotating RSVP placeholder ("e.g. …"), stable per event so it
    /// doesn't flicker on re-render.
    static func placeholder(seed: UUID) -> String {
        let index = Int(seed.uuid.0) % entries.count
        return "e.g. " + entries[index].text
    }
}
