# Security

This script runs with root privileges and can install or repair software.

Review it before execution and test it in a disposable VM/WSL environment before rolling it out broadly.

Trust boundaries include external installers, npm/Python packages, Claude plugin marketplaces and Git repositories used as vendor sources.

Normal SMART-REPAIR deliberately avoids contacting update sources when the corresponding component is already healthy. `--update` explicitly opts into refresh behavior.

Do not publish secrets, tokens, private repository paths, or private Claude transcripts with bug reports.
