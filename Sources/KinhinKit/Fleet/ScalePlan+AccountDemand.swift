extension ScalePlan {
    /// Select the image after binding the account: another repository's ready runner cannot cover this job.
    static func imageForAccount(
        _ account: String, queuedTart: Int, records: [VMRecord], input: Input
    ) -> String? {
        let accountImages = input.imageDemandByAccount[account]
        var served: [String: Int] = [:]
        for record in records
        where Self.pool(of: record, input: input) == .tart && servesImageDemand(record, input: input)
            && (accountImages == nil || record.platform == account)
        {
            served[record.image ?? "", default: 0] += 1
        }
        return chooseImage(
            queuedTart: accountImages == nil ? queuedTart : input.demand[account]?[.tart] ?? 0,
            byImage: accountImages ?? input.imageDemand, active: served)
    }
}
