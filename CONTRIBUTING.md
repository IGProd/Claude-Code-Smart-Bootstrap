# Contributing

Pull requests are welcome.

Before opening a PR:

1. run `bash tests/static-check.sh`;
2. avoid hard-coded local usernames/paths;
3. keep normal SMART-REPAIR offline-first for healthy components;
4. keep `--update` explicit;
5. keep `--verify-only` read-only;
6. add/update behavioral evidence when changing persistence, visual-cache or performance behavior.

When reporting benchmark changes, include methodology and avoid presenting a single-machine number as a universal guarantee.
