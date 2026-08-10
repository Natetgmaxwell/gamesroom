//
//  PhotoHash.swift
//  GamesRoom
//
//  Track B model layer. Pure data type. Foundation + CryptoKit.
//
//  F-CAS-03: photos stay on-device. The captured frame is hashed
//  (SHA-256) and the bytes are discarded immediately; the hash is
//  what travels in `VisionSnapshot.photoHash` so a disputed scan can
//  be matched to its capture without persisting the image.
//

import Foundation
import CryptoKit

enum PhotoHash {
    /// SHA-256 hex digest of the captured photo bytes. Deterministic
    /// and collision-resistant enough to fingerprint a scan frame.
    static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
