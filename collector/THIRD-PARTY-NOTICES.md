# Third-party components

The folder `lib\sqlite` contains unmodified binaries from nuget.org (the same files as Purview DLP Report,
checked by SHA-256).

| Component | Version | Files | License |
|---|---|---|---|
| Microsoft.Data.Sqlite.Core (Microsoft) | 10.0.12 | `Microsoft.Data.Sqlite.dll` (lib/net8.0) | MIT — https://github.com/dotnet/efcore/blob/main/LICENSE.txt |
| SQLitePCLRaw.core (Eric Sink) | 2.1.12 | `SQLitePCLRaw.core.dll` | Apache-2.0 — https://github.com/ericsink/SQLitePCL.raw/blob/master/LICENSE.TXT |
| SQLitePCLRaw.provider.e_sqlite3 | 2.1.12 | `SQLitePCLRaw.provider.e_sqlite3.dll` (lib/netstandard2.0) | Apache-2.0 |
| SQLitePCLRaw.bundle_e_sqlite3 | 2.1.12 | `SQLitePCLRaw.batteries_v2.dll` (lib/netstandard2.0) | Apache-2.0 |
| SQLitePCLRaw.lib.e_sqlite3 (SQLite 3.53.3) | 2.1.12 | `runtimes\win-x64\e_sqlite3.dll`, `runtimes\win-arm64\e_sqlite3.dll` | Apache-2.0 (packaging); SQLite itself is in the public domain — https://sqlite.org/copyright.html |
