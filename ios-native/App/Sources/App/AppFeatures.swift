import Foundation

// ================================================================
//  APP FEATURES — static switches of features that wait for another
//  package (v1.1 spec §4.6).
// ================================================================
enum AppFeatures {
    /// «Новая станция» / the «↻» title chip / `-station N`: off until WP6 renders generated stations (spec §4.7).
    /// While off every mission and the title play «Кельвин-9», the saved `seed` is neither read into play nor written.
    static let generatedStations = false
}
