#!/usr/bin/env bash
# Runs playbooks/validate_topology.yml against every fixture listed in
# tests/cases.txt and compares exit code and message with the expectation.
# The playbook targets localhost only, so no SSH or managed hosts are needed.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

failed=0
while IFS='|' read -r fixture expected_rc expected_msg; do
    [[ -z "${fixture// }" || "${fixture}" == \#* ]] && continue
    output=$(ansible-playbook -i "tests/fixtures/${fixture}.yml" \
        playbooks/validate_topology.yml 2>&1)
    rc=$?
    if [[ "${rc}" -ne "${expected_rc}" ]]; then
        echo "FAIL ${fixture}: rc=${rc}, expected ${expected_rc}"
        echo "${output}" | tail -20
        failed=1
        continue
    fi
    if [[ -n "${expected_msg// }" ]] && ! grep -qF "${expected_msg}" <<<"${output}"; then
        echo "FAIL ${fixture}: output does not contain '${expected_msg}'"
        echo "${output}" | tail -20
        failed=1
        continue
    fi
    echo "ok   ${fixture}"
done < tests/cases.txt

exit "${failed}"
