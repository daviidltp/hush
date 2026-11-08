//
// Copyright (c) 2025, Denis Dzyubenko <denis@ddenis.info>
//
// SPDX-License-Identifier: BSD-2-Clause
//

import Foundation

extension Date {
    /// The .NET DateTime epoch: `0001-01-01 00:00:00 UTC`.
    ///
    /// Used as the reference point for date encoding in KDBX files, which follow the
    /// .NET serialization format for date values.
    // Parche de Bóveda: Foundation usa el calendario juliano antes de 1582, así que
    // "1 de enero del año 1" salía 2 días desplazado respecto a .NET (gregoriano proléptico).
    // KeePassXC y KeePassium leían nuestras fechas con 2 días de diferencia. Usamos la constante exacta.
    private static let dotNetEpoch = Date(timeIntervalSince1970: -62_135_596_800)

    /// The number of seconds between this date and the .NET epoch (`0001-01-01T00:00:00Z`),
    /// rounded to the nearest second.
    ///
    /// This value matches how dates are encoded in KDBX files.
    var secondsSinceDotNetEpoch: Int64 {
        Int64(timeIntervalSince(Self.dotNetEpoch).rounded())
    }

    /// Creates a `Date` from the number of seconds since the .NET epoch (`0001-01-01T00:00:00Z`).
    ///
    /// This is used to decode timestamp values found in KeePass KDBX documents.
    ///
    /// - Parameter seconds: The number of seconds since the .NET epoch.
    init(secondsSinceDotNetEpoch seconds: Int64) {
        self = Self.dotNetEpoch.addingTimeInterval(TimeInterval(seconds))
    }
}
