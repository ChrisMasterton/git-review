import Foundation
import GitReviewCore
import Testing

@Test func parsesBranchAndWorkingTreeCounts() {
    let output = """
    # branch.oid 123456
    # branch.head feature/review
    # branch.upstream origin/feature/review
    # branch.ab +2 -1
    1 M. N... 100644 100644 100644 abc abc Sources/App.swift
    1 .M N... 100644 100644 100644 abc abc README.md
    ? notes.txt
    """

    let status = GitStatusParser.parse(output)

    #expect(status.branch == "feature/review")
    #expect(status.upstream == "origin/feature/review")
    #expect(status.ahead == 2)
    #expect(status.behind == 1)
    #expect(status.stagedCount == 1)
    #expect(status.modifiedCount == 1)
    #expect(status.untrackedCount == 1)
}

@Test func parsesTrackedAndLocalOnlyBranches() {
    let branches = BranchTrackingParser.parse("""
    main\torigin/main\t[behind 1]
    feature/local\t\t
    feature/push\torigin/feature/push\t[ahead 3, behind 2]
    feature/gone\torigin/feature/gone\t[gone]\t1720000000
    """)

    #expect(branches.count == 4)
    #expect(branches[0].behind == 1)
    #expect(branches[1].needsPush)
    #expect(branches[2].ahead == 3)
    #expect(branches[3].upstreamGone)
    #expect(branches[3].needsPush)
    #expect(branches[3].lastCommitDate == Date(timeIntervalSince1970: 1_720_000_000))
}

@Test func parsesLocalBranchActivityFromReflogs() {
    let output = """
    HEAD@{1730000000}\tcheckout: moving from main to feature/gone
    HEAD@{1720000000}\tcommit: unrelated
    HEAD@{1710000000}\tcheckout: moving from feature/older to main
    """
    let dates = BranchActivityParser.lastCheckoutDates(
        output,
        branchNames: ["main", "feature/gone", "feature/older"]
    )

    #expect(dates["feature/gone"] == Date(timeIntervalSince1970: 1_730_000_000))
    #expect(dates["main"] == Date(timeIntervalSince1970: 1_730_000_000))
    #expect(dates["feature/older"] == Date(timeIntervalSince1970: 1_710_000_000))

    let created = BranchActivityParser.approximateCreationDate("""
    refs/heads/feature/gone@{1730000000}\tcommit: latest
    refs/heads/feature/gone@{1700000000}\tbranch: Created from HEAD
    """)
    #expect(created == Date(timeIntervalSince1970: 1_700_000_000))
}
