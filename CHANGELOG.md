# Changelog

## 4.9.0-public

Public/generalized release based on the validated V4.8.2 smart bootstrap.

- removed hard-coded private user names;
- added `--users root,alice,bob`;
- added `CLAUDE_BOOTSTRAP_USERS`;
- added `--show-targets` and `--help`;
- defaults to root + `SUDO_USER` when an explicit list is omitted;
- validates usernames and fails on nonexistent requested accounts;
- preserved offline-first SMART-REPAIR behavior;
- preserved deep `--verify-only` and intentional `--update`;
- added public architecture and behavioral-test documentation;
- added vector charts and machine-readable measured results.
