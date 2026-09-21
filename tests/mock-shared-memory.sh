#!/bin/bash
# Sentinel for nightly tests: even a context lookup is unexpected, and nothing
# here touches Mnemopi. Manual promotion has its own fixture in tests/promote.sh.
printf '%s\n' "$*" >> "${MOCK_SM_LOG:?set MOCK_SM_LOG to the sandbox call log}"
echo 'mock-shared-memory: the nightly must not call shared-memory' >&2
exit 1
