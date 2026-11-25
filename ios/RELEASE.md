# iPhone build and release checks

`Intake.xcodeproj` is the checked-in project; opening it does not require XcodeGen. `project.yml` is its source for target changes. The `IntakeKit` package pins GRDB. CI runs the Swift tests against a disposable FastAPI backend and builds the Release target for iPhone without a distribution identity.

## Device recovery acceptance

Before distribution, use two dedicated test devices with synthetic records and the same signed build. A simulator, a reopened SQLite file, or a successful archive does not prove an iCloud restore.

1. On the first device, log an item and note before configuring a server. Link a synthetic account, then create a pending edit while offline and an unresolved edit from a second client. Record the visible quantities, notes, account and pending counts.
2. Include Intake in an ordinary iCloud device backup. Restore that backup onto a dedicated replacement test device. Open Intake offline before signing in to the server. Compare the journal, timestamps, notes, counts and outstanding work. The server session should not transfer.
3. Sign in to the same account and reconcile. Check that previously acknowledged operations have not added a second entry, and the unresolved edit still requires a choice. Exercise a wrong account separately and confirm it does not receive the original queue.

Record the build, iOS versions, backup and restore result before claiming device recovery is verified. Confirm [Guideline 5.1.3(ii)](https://developer.apple.com/app-store/review/guidelines/#health-and-health-research) for system backups of a medicine journal before App Store distribution. Neither CI nor local verification covers App Review acceptance.
