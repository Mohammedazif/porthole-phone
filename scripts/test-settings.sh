#!/usr/bin/env bash
set -euo pipefail

task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v swiftc >/dev/null 2>&1; then
    echo "Swift compiler unavailable. Run this check on a Mac or a system with Swift installed." >&2
    exit 1
fi
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 5 \
    "$task_root/PortholePull/ClipboardSyncPreference.swift" \
    "$task_root/Tests/ClipboardSync/main.swift" \
    -o "$test_dir/clipboard-sync-tests"
"$test_dir/clipboard-sync-tests"

swiftc -swift-version 5 \
    "$task_root/PortholePull/InputControlPreference.swift" \
    "$task_root/PortholePull/InputVerification.swift" \
    "$task_root/Tests/InputControls/main.swift" \
    -o "$test_dir/input-control-tests"
"$test_dir/input-control-tests"

swiftc -swift-version 5 \
    "$task_root/PortholePull/ReceivedFileStorage.swift" \
    "$task_root/PortholePull/ActivityHistory.swift" \
    "$task_root/PortholePull/TransferFileName.swift" \
    "$task_root/PortholePull/TransferStaging.swift" \
    "$task_root/PortholePull/ShareReceiptJournal.swift" \
    "$task_root/Tests/DesignSupport/main.swift" \
    -o "$test_dir/design-support-tests"
"$test_dir/design-support-tests"

swiftc -swift-version 5 \
    "$task_root/Shared/PortholeAppGroup.swift" \
    "$task_root/Shared/TrustedPeer.swift" \
    "$task_root/Shared/OutboundTransferJournal.swift" \
    "$task_root/PortholePull/ShareReceiptJournal.swift" \
    "$task_root/PortholePull/ReceivedFileStorage.swift" \
    "$task_root/PortholePull/TransferStaging.swift" \
    "$task_root/PortholePull/IncomingTransfer.swift" \
    "$task_root/Tests/TrustedTransport/main.swift" \
    -o "$test_dir/trusted-transport-tests"
"$test_dir/trusted-transport-tests"

swiftc -swift-version 5 \
    "$task_root/Shared/PortholeAppGroup.swift" \
    "$task_root/Shared/WidgetInbox.swift" \
    "$task_root/PortholePull/WidgetInboxPublisher.swift" \
    "$task_root/Tests/Widgets/main.swift" \
    -o "$test_dir/widget-tests"
"$test_dir/widget-tests"
