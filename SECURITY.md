# Security

## Reporting a vulnerability

Use this repository's Security tab and Report a vulnerability to contact the maintainer privately. Do not publish credentials, personal data, customer configuration, or sensitive exploit details in a public issue.

Include the affected version, expected and observed behavior, and minimal reproduction steps with sensitive values removed. If a credential has been exposed, revoke or rotate it immediately; deleting a commit or file is not sufficient.

## Release integrity

Obtain releases from the official Nico77600 repository. Verify available artifact attestations against the expected repository and verify any code signature against the expected publisher.

A checksum alone does not authenticate a file if the checksum and the file can both be replaced. A valid signature or attestation proves integrity or provenance, not the absence of vulnerabilities.

New immutable releases preserve their published assets and associated tag. Existing releases are not made immutable retroactively. Corrections are published as a new version rather than replacing a released file.
