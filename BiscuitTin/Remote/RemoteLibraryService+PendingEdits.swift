import Foundation
import GRDB
import Photos

extension RemoteLibraryService {

    // MARK: - Pending edits (D22)
    //
    // Catches up a local edit whose remote leg failed once the server is reachable again — see
    // `PendingEditRecord`'s doc comment for the two reconciliation shapes. Driven from
    // `StartupSequencer` (launch/foreground) and `SyncEngine`'s background task; both already
    // hold a reference here, so nothing new needed registering with the OS to get a retry
    // window (BGTaskScheduler identifiers are a scarce, crash-prone resource — see AGENTS.md).

    /// Queues a rotation to retry, called after the server leg fails regardless of whether the
    /// local facet's own rotation succeeded. Re-enqueuing an asset that already has a pending
    /// edit just resets its retry clock — the partial unique indexes on `pending_edits` make
    /// that an update, not a duplicate row.
    ///
    /// `uploadedID`/`uploadedChecksum` name a replacement that reached the server but whose
    /// old asset was not retired; the retry finishes it before anything else.
    func enqueuePendingRotation(localIdentifier: String?,
                                immichID: String,
                                mediaKind: MediaKind,
                                clockwise: Bool,
                                uploadedID: String? = nil,
                                uploadedChecksum: String? = nil) async throws {
        // Only a remote-only edit needs to remember the operation — a local-backed one is
        // state-based and re-reads PhotoKit fresh at retry time (see PendingEditRecord).
        let payload = localIdentifier == nil ? RotationPayload(clockwise: clockwise).jsonString : nil
        try await upsertPendingEdit(localIdentifier: localIdentifier, immichID: immichID,
                                    editType: .rotation, mediaKind: mediaKind, payload: payload,
                                    uploadedID: uploadedID, uploadedChecksum: uploadedChecksum)
    }

    /// Queues a push of the local rendition for an asset whose upload finished after it was
    /// edited — the server holds the pre-edit bytes, and nothing else would ever correct them.
    func enqueueLocalReconcile(localIdentifier: String, immichID: String, mediaKind: MediaKind) async throws {
        try await upsertPendingEdit(localIdentifier: localIdentifier, immichID: immichID,
                                    editType: .rotation, mediaKind: mediaKind, payload: nil)
    }

    private func upsertPendingEdit(localIdentifier: String?,
                                   immichID: String,
                                   editType: PendingEditRecord.EditType,
                                   mediaKind: MediaKind,
                                   payload: String?,
                                   uploadedID: String? = nil,
                                   uploadedChecksum: String? = nil) async throws {
        let writer = try database.writer()
        let now = Date().timeIntervalSince1970
        try await writer.write { db in
            try PendingEditRecord.upsert(db, localIdentifier: localIdentifier, immichID: immichID,
                                         editType: editType, mediaKind: mediaKind, payload: payload,
                                         uploadedID: uploadedID, uploadedChecksum: uploadedChecksum,
                                         now: now)
        }
    }

    /// Drains the queue, one edit at a time. Safe to call often — each edit either reconciles
    /// and clears, or fails and waits (D22). A failure that is not the edit's fault (no
    /// network, server down, signed out) stops the drain without counting against anything.
    func retryPendingEdits() async {
        guard !isRetryingEdits else { return }
        isRetryingEdits = true
        defer { isRetryingEdits = false }

        guard let writer = try? database.writer() else { return }
        let now = Date().timeIntervalSince1970
        let edits = (try? await writer.read { db in
            try PendingEditRecord
                .filter(sql: "next_attempt_at <= ?", arguments: [now])
                .fetchAll(db)
        }) ?? []
        guard !edits.isEmpty else { return }

        for edit in edits {
            do {
                try Task.checkCancellation()
                try await reconcile(edit)
                try await clearPendingEdit(id: edit.id)
            } catch {
                var underlying = error
                if let incomplete = error as? ReplacementIncomplete {
                    try? await recordUploadedReplacement(id: edit.id, newID: incomplete.newID,
                                                         checksumHex: incomplete.newChecksumHex)
                    underlying = incomplete.underlying
                }
                switch RetryPolicy.kind(of: underlying) {
                case .transient, .authentication:
                    return
                case .item:
                    Log.immich.error("Pending edit retry failed: \(underlying.localizedDescription, privacy: .public)")
                    try? await bumpPendingEditFailure(id: edit.id, error: underlying.localizedDescription)
                }
            }
        }
    }

    private func reconcile(_ edit: PendingEditRecord) async throws {
        switch edit.editType {
        case .rotation:
            try await reconcileRotation(edit)
        }
    }

    private func reconcileRotation(_ edit: PendingEditRecord) async throws {
        if let newID = edit.uploadedID, let checksum = edit.uploadedChecksum {
            let client = try makeClient()
            let record = try await remoteRecord(for: edit.immichID, client: client)
            let old = try await client.assetInfo(id: edit.immichID)
            let capture = ReplacementPlan.captureTime(fileCreatedAt: old.fileCreatedAt,
                                                      localDateTime: old.localDateTime,
                                                      fallback: Date(timeIntervalSince1970: record.captureAt))
            // No local identifier: these bytes may no longer be the local photo's, so
            // backup_state is left for the push below to settle.
            try await finishReplacement(oldID: edit.immichID, newID: newID, newChecksumHex: checksum,
                                        isDuplicate: true, capture: capture, record: record,
                                        localIdentifier: nil, localModifiedAt: nil,
                                        width: nil, height: nil)
            try await clearUploadedReplacement(id: edit.id)
            guard edit.localIdentifier != nil else { return }   // the remote-only rotation is complete
        }

        if let localIdentifier = edit.localIdentifier {
            try await pushLocalRendition(localIdentifier: localIdentifier)
        } else {
            guard let payloadString = edit.payload, let payload = RotationPayload(jsonString: payloadString) else {
                throw RotationError.assetUnavailable
            }
            guard payload.quarterTurns != 0 else { return }
            guard let rotator = registry.rotator(for: edit.mediaKind) else {
                throw RotationError.unsupportedMediaKind(edit.mediaKind)
            }
            try await rotateRemote(immichID: edit.immichID, quarterTurns: payload.quarterTurns, rotator: rotator)
        }
    }

    /// State-based reconciliation: replaces the server copy with whatever PhotoKit currently
    /// has, rather than replaying whichever rotation(s) were attempted. However many edits
    /// landed locally, in whatever order, the current rendition already *is* the answer.
    ///
    /// This always overwrites a concurrent remote-side change — a deliberate, last-writer-wins
    /// choice, not an attempt at conflict resolution. It matches D10's existing posture: a
    /// rotation already produces a new asset id and drops server-side album membership in
    /// favour of staying simple.
    func pushLocalRendition(localIdentifier: String) async throws {
        // Fetched fresh: the resolver's cached object can predate the edit.
        resolver.invalidate([localIdentifier])
        guard let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            return   // Local asset is gone; nothing left to push. Not an error — just moot.
        }
        guard let immichID = try immichID(forLocalIdentifier: localIdentifier) else {
            return   // No remote facet either (any more); same as above.
        }
        let record = try await remoteRecord(for: immichID, client: try makeClient())

        // Read before the bytes, so an edit landing during the read is newer than what is stored.
        let modifiedAt = phAsset.modificationDate
        let sha = try await exporter.checksum(asset: phAsset)
        guard sha != record.checksumHex else {
            // Already in step. PhotoKit moves the modification date for changes that leave the
            // bytes alone; replacing anyway would cost a new asset id for nothing.
            let writer = try database.writer()
            try await writer.write { db in
                try db.execute(sql: "UPDATE backup_state SET checksum_hex = ?, modified_at = ? WHERE local_identifier = ?",
                               arguments: [sha, modifiedAt?.timeIntervalSince1970, localIdentifier])
            }
            return
        }

        let export = try await exporter.export(asset: phAsset)
        defer { try? FileManager.default.removeItem(at: export.fileURL) }
        // The photo changed between the two reads; the retry will see the settled state.
        guard export.sha1Hex == sha else { throw RotationError.assetUnavailable }

        try await replaceRemoteFile(oldID: immichID, fileURL: export.fileURL,
                                    exportedFilename: export.filename, record: record,
                                    localIdentifier: localIdentifier, localModifiedAt: modifiedAt,
                                    width: phAsset.pixelWidth, height: phAsset.pixelHeight)
    }

    private func clearPendingEdit(id: Int64?) async throws {
        guard let id else { return }
        let writer = try database.writer()
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM pending_edits WHERE id = ?", arguments: [id])
        }
    }

    private func recordUploadedReplacement(id: Int64?, newID: String, checksumHex: String) async throws {
        guard let id else { return }
        let writer = try database.writer()
        try await writer.write { db in
            try db.execute(sql: "UPDATE pending_edits SET uploaded_id = ?, uploaded_checksum = ? WHERE id = ?",
                           arguments: [newID, checksumHex, id])
        }
    }

    private func clearUploadedReplacement(id: Int64?) async throws {
        guard let id else { return }
        let writer = try database.writer()
        try await writer.write { db in
            try db.execute(sql: "UPDATE pending_edits SET uploaded_id = NULL, uploaded_checksum = NULL WHERE id = ?",
                           arguments: [id])
        }
    }

    private func bumpPendingEditFailure(id: Int64?, error: String) async throws {
        guard let id else { return }
        let writer = try database.writer()
        let now = Date().timeIntervalSince1970
        try await writer.write { db in
            let failures = (try Int.fetchOne(db, sql: "SELECT retry_count FROM pending_edits WHERE id = ?",
                                             arguments: [id]) ?? 0) + 1
            try db.execute(sql: """
                UPDATE pending_edits SET retry_count = ?, last_error = ?, updated_at = ?, next_attempt_at = ?
                WHERE id = ?
                """, arguments: [failures, error, now, now + RetryPolicy.delay(afterFailures: failures), id])
        }
    }
}
