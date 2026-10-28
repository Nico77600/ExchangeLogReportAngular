# Provenance — experimental Angular Serve pilot

## Status and scope

This is an isolated, experimental local pilot intended for the **public**
`Nico77600/ExchangeLogReportAngular` repository, following the owner's October 26,
2026 visibility decision. Version `0.3.0` is an unreleased
implementation target. These files do not establish a GitHub repository, an
approved public publication, a successful hosted CI run, a signed product or a
release.

The collector sources are under `collector/src/Engine.*.cs`. The pilot reuses
collector functionality and SQLite dependencies; `product.json`'s
`sourceVersion` is a product compatibility label, **not** an independently
verified upstream commit, an import of public Git history or a claim that this
modified pilot inherits a previous audit. The experimental Serve changes need
their own review and regression evidence.

## Build inputs and runtime

The development lockfile retains Angular runtime 21.2.25. Reviewed security
maintenance updates the CLI to 21.2.27 and Vitest to 4.1.12, with parent-scoped
overrides for the CLI's MCP SDK 1.32.1, the builder's Vite 7.3.7 and Undici
7.30.1, jsdom's Undici 8.12.2, Express 5.3.0's body-parser 2.4.0 and AJV
8.18.0's fast-uri 3.1.9. These are compatible stable patch/minor updates, not
a major/prerelease Angular upgrade.

The October 26 follow-up resolves the previous four high and seven moderate
npm entries: the full audit reports zero vulnerabilities. The existing complete
`npm audit --audit-level=high` gate remains unchanged; a production-only audit
is not substituted for it. Only the two corrected package records changed in
the lockfile, following isolated npm resolution of public dependency metadata.
The actual package manifests and parent dependency ranges were checked.

The October 27 publication review found 146 remaining development-mirror
resolution URLs outside those two corrected package records. The existing
`frontend/tools/normalize-lockfile.mjs` helper replaces only those URLs with
official npm archive URLs. All 579 resolved archives now use the public registry;
every package version, integrity digest and other dependency field is unchanged.
This URL cleanup is not another dependency upgrade or proof of network access
from a fresh environment.

An owner-authorized helper host acquired the unchanged official registry
archives because the development network's mirror omitted these versions.
Normal Node HTTPS certificate-chain/hostname validation was retained; this
does not assert a successful Windows Schannel revocation check. Registry
SHA-512 integrity and SHA-1 metadata, transfer SHA-256 and the actual archive
manifests were checked locally before standard npm cache priming and `npm ci`.
This is registry/transport integrity evidence, not independently verified npm
publisher signatures, product signing or release attestation.

The lockfile retains the official archive URLs and SHA-512 integrities; no
vendored dependency, Git-source replacement or invented version is used.
No project code, private project identity or credentials were sent to the helper
host. Temporary acquisition and dependency-resolution files are not package
inputs. No global DNS/registry/TLS setting, power automation or audit threshold
was changed. The development mirror/network availability is not claimed fixed:
a fresh environment still needs approved access to its locked packages.

- `frontend/package.json` and `frontend/package-lock.json` are intended to be
  committed together. A local file is not evidence of a commit; no commit or
  remote write is authorized by this preparation.
- CI requires preinstalled Node 24 and checks its version against both the
  project's `engines.node` and the locked Angular CLI requirement **before**
  invoking npm. It uses npm's already-installed semver library, not another
  downloaded action or version manager. An incompatible runner fails.
- Frontend installation is `npm ci --no-fund`, with no `npm install` fallback.
  `npm audit --audit-level=high` must succeed; audit/network failures and actual
  high or critical findings are not ignored. The Angular build and one-shot
  unit tests are separate required steps within the proposed CI job.
- `dotnet build host/ExchangeLogReportAngular.Host.csproj` compiles the host and
  its linked `collector/src/Engine.*.cs` files. Build-time .NET/Node tooling is
  distinct from the delivered portable runtime; Node/npm are **not** runtime
  prerequisites.
- `tools/Build-Standalone.ps1` remains the packaging entrypoint. Its versioned
  output contains the collector under `collector/` and the compiled Angular
  entrypoint, JavaScript and stylesheets under `web/`. Packaging must use a new
  output directory and must not include development databases, credentials,
  source logs, lab paths or a `node_modules` tree.
- `collector/README.md` is delivered at the same relative path, alongside the
  existing root `README.txt`. Its Requirements, Quick start, Content,
  Documentation and Disclaimer sections describe the Angular portable package,
  not the old collector-only packaging command. Delivered documentation is part
  of the frozen build-input inventory as well as the final file manifests.
  Both HTML guides include the Angular operator/lifecycle chapters. Their two
  synthetic illustrations are delivered under `docs/images/` at the same
  relative paths and frozen as build inputs, not fetched from a remote site.
  The retained static SMTP illustration is likewise delivered under
  `collector/docs/images/`, restored from its unchanged tracked upstream bytes.
  `.github/ci.json` declares `collector` as the runtime root and the existing
  validation/build paths; this local profile does not configure remote policies
  or establish successful required checks.
- `Start-ExchangeLogReportAngular.cmd` verifies the selected package, then
  launches its portable `powershell/pwsh.exe` with
  `collector/Invoke-ExchangeLogReport.ps1 -Mode Serve`. The browser application
  is served by the collector's loopback listener, not by Kestrel. The retained
  self-contained host is for the storage CLI only.
- Source-tree Serve runs without a package manifest require the explicit
  `-DevelopmentMode` switch. This is not a package-verification bypass: a
  present `PackageIntegrity.json` must always pass its package-owned verifier.
  `Initialize-ExlEngine` verifies a present manifest before loading SQLite and
  compiles the collector Engine sources in memory; it does not load a cached
  `collector/bin` engine DLL as trusted product code.
- `product.json` records the selected portable PowerShell and SQLite tools
  versions, original download locations and SHA-256 pins. The packaging tool
  verifies those downloaded dependency bytes; it also checks the portable
  PowerShell executable's Microsoft signature. Third-party dependency
  signatures do **not** sign this pilot's own PowerShell, C#, Angular bundle or
  package. Preserve the collector's third-party notices and SQLite dependency
  provenance when reviewing a delivery.

## Package integrity is not product signing

The `0.3.0` package contract is `PackageIntegrity.json`, schema version `1`, with
a `files` array of canonical relative Windows-backslash `path`, `bytes` and
`sha256` records. Forward-slash, absolute, traversal and duplicate paths are
not valid manifest entries. The inventory
covers delivered immutable files, including `web/index.html` and each emitted
JavaScript/CSS file. It excludes itself, `FILES.sha256.json` and the deliberately
mutable `collector/config/ExchangeLogReport.config.psd1`. Invoke the verifier
**from the selected package**:
`<packageRoot>\tools\Test-PackageIntegrity.ps1 -Root <packageRoot>`.
It refuses to verify another package using a development-copy verifier.
`FILES.sha256.json` additionally inventories the immutable manifest and the
initial mutable configuration bytes, excluding only itself. The release ZIP
verifier checks both inventories and rejects unlisted, missing,
size-mismatched, hash-mismatched and unsafe entries.

These are **unsigned local integrity records**, not a trusted signature.
Someone who can replace both files and manifest can generate matching hashes.
The release ZIP digest, immutable release controls and a successfully verified
attestation provide different evidence and must be checked separately.
The full build-time inventory covers the initial configuration bytes, while
the runtime immutable manifest deliberately does not. Mutable configuration
and generated `data/`, `logs/`, `reports/`, `collector/bin/`, `collector/data/`,
`collector/logs/` and `collector/reports/` are not authenticated by the runtime
integrity check. These runtime exclusions do not authorize private state in a
release ZIP: the release verifier separately rejects those generated-state/cache
directories and requires complete build-time coverage of permitted files.

The five shipped PowerShell files carry Nicolas Fabert Authenticode signatures
and RFC3161 timestamps: `collector/ExchangeLogReport.psd1`,
`collector/ExchangeLogReport.psm1`, `collector/Invoke-ExchangeLogReport.ps1`,
`collector/src/Get-ExlExchangeSettings.ps1` and `tools/Test-PackageIntegrity.ps1`.
The expected owner certificate thumbprint is
`0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6`.
This coverage authenticates only those script bytes, not C# sources, the compiled
Angular bundle, native dependencies, the unsigned package manifest or mutable
operator configuration. Raw signed Git blobs must match the frozen,
native-verified signed inventory before publication. Do not substitute an old
upstream signature, a dependency's signature, CI success or an archive hash for
that evidence.

## Proposed CI and CodeQL

`.github/workflows/ci.yml` proposes a disposable `windows-2022` job with
`contents: read`, checkout credential persistence disabled, and an exact
owner/repository/public-visibility guard. It builds and verifies the standalone
package, then runs the collector Pester tests, new
`collector/tests/Serve*.Tests.ps1` tests and workflow contract tests under the
**freshly packaged PowerShell runtime**. It checks that executable's location,
exact configured `product.json` PowerShell version and x64 architecture;
test-launched child `pwsh` processes resolve to that same runtime.
`tests/PackageIntegrity.Tests.ps1` additionally
checks synthetic tampering/mutability fixtures; CI separately invokes the
package-owned verifier against the **newly built real package**.
It does not connect to the development lab,
read an original database, publish a package or use publication secrets.
Legacy host/package tests that require explicit package/database parameters
remain separate procedures; this workflow does not pretend to have run them.

Pester is pinned to `6.1.0`, following the inspected reference CI helper.
The helper refuses to register a missing gallery automatically and records
SHA-256 hashes of the saved module files. The reference has **no independently
reviewed download checksum**: the observed hash inventory is traceability, not
an additional trusted supply-chain pin. No analyzer or lint tool is added.
Uploaded evidence is limited to module hashes, synthetic-test counts and the
package's file inventory; raw logs, launch tokens, databases and test working
directories are not uploaded.

`.github/workflows/codeql.yml` is manual, default-branch-only and advisory. It
proposes C# compilation-based extraction of the linked collector/host sources,
JavaScript/TypeScript analysis of the Angular sources, and workflow analysis.
It is not a PowerShell analyzer. A missing, failed, unsupported or skipped scan
is not successful coverage. Public-repository CodeQL enablement and result
upload permissions remain **pending verification**; no required-check policy
has been established or changed.

All proposed actions use only the four existing reviewed full commit IDs from
the inspected reference workflows: checkout, upload-artifact, CodeQL and
attest. This does **not** add this pilot to any repository registry or authorize
these actions on its server. Repository-specific allow-list review and owner
approval remain necessary before uploading or enabling the workflows. No
global action allow-list is changed.

## Attesting the actual distributed Angular bundle

`.github/workflows/attest-release.yml` is a local proposal adapted from the
existing release ZIP verification workflow. It supports a published release
event or a manual run from the default branch with an explicit existing tag,
only for the exact intended public repository.

It does not check out source, build, execute a package, accept arbitrary CI
artifacts, create a release or fall back to a source archive. It:

1. Verifies the public repository, exact tag, published release ID and complete
   paginated ZIP asset inventory.
2. Downloads those actual uploaded release ZIPs using numeric local filenames,
   checks their size and computes SHA-256, comparing GitHub's asset digest when
   that metadata is available.
3. Opens each ZIP without extracting it, verifies both package inventories
   against the shipped files and the package version against the exact release
   tag, and requires `web/index.html` plus compiled
   JavaScript/CSS. The Angular entrypoint must reference its packaged script.
4. Rechecks the tag and release asset inventory for changes before requesting
   an attestation whose subject is the actual ZIP digest. Registry pushing is
   disabled.

The ZIP digest cryptographically covers its compiled Angular bundle and
manifest. This binds the distributed bytes to the attesting repository/workflow
identity; it **does not prove their original build**, original source revision,
reproducibility or absence of vulnerabilities. Verify the resulting attestation
against separately downloaded distributed ZIP bytes and the expected identity.
Public-repository attestation enablement and verifier access remain **pending**.
Unsupported service capabilities must fail visibly, not be bypassed through a
registry push, another repository or substitute artifacts.

## Evidence and publication gates

Local workflow tests can establish offline contract/parser behavior only.
They do not establish a bundled-runtime backend/performance test result,
hosted CI success, current remote protections, a clean
dependency audit, CodeQL completion, a genuine release or a distributed-asset
attestation. No production-scale/24 GB performance result is claimed.

Before any separately authorized remote operation, record fresh evidence for
the exact revision, owner consent, project validation, repository controls and
reviewed action permissions. Preserve the parent publication/documentation
gates, exact README/SECURITY presentation review, package privacy inventory,
tag/merged-source checks, downloaded-asset hashes, actual-ZIP attestation and
versioned local **and off-machine** recovery copies. None are waived by a
local manifest or this document.

| Evidence | Publication requirement |
| --- | --- |
| Exact owner-approved remote change/repository inclusion | Approve the exact source, destination and operation; local preparation is not public-write consent |
| Owner-only commit and reviewed merged/tagged source | Verify owner-only authorship and the exact reviewed commit, merge and release tag |
| Full `0.3.0` validation, npm audit and hosted CI | Run the existing validation and audit; local results do not establish hosted CI success |
| Live repository controls, reviewed per-repository action permissions | Obtain fresh authenticated observations for the exact publication phase |
| Product signed-source verification | Preserve the five owner signatures/timestamps and verify the actual raw Git blobs against the frozen inventory |
| Sanitized final package and complete uploaded/downloaded asset hashes | Build from reviewed merged source and verify the complete separately approved asset inventory |
| Documentation/content/visual publication review | Review exact README/SECURITY bytes and rendered light, dark and narrow layouts |
| Public CodeQL and actual distributed-ZIP attestation | Confirm configured runs and verify the actual distributed ZIP; no source-only substitute |
| Versioned history/assets/settings backups and off-machine copy | Verify recovery evidence separately; a local copy is not off-machine coverage |
