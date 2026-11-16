import Foundation

/// Combined admission limit for on-demand borrowing. Runtime count caps still
/// apply; this additionally accounts for every live or not-yet-deleted instance.
struct ScaleResourceBudget: Sendable, Equatable {
    var capacity: VMResourceReservation
    var shapes: [RuntimeID: VMResourceReservation]
}
