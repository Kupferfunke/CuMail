# GRDB 7.12.0 · SQLCipher integration

Upstream: https://github.com/groue/GRDB.swift/tree/v7.12.0
Revision: 92a554cd0d5e8d67cb18993c6054e73fe42c066c
License: MIT, see LICENSE.

GRDB/ and Sources/GRDBSQLCipher/ are copied without source changes. Per-file SHA-256 values are recorded in docs/evidence/phase-1-grdb-vendor.json. The upstream Package.swift instructions for SQLCipher are applied: SQLITE_HAS_CODEC, GRDBSQLCipher and the official SQLCipher.swift product are enabled; system GRDBSQLite is removed. SQLCipher.swift is pinned exactly to 4.20.0. Upstream test targets and test-only resources are not vendored. Runtime resources including PrivacyInfo.xcprivacy remain included.

No GRDB or SQLite code is forked or edited. Future upgrades must replace the upstream source set, update provenance and pins, and rerun encryption, migration, deletion and native build tests. The optional upstream documentation dependency is inactive in normal builds.
