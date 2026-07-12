#!/usr/bin/env python3
"""
X1 Pro MAC fix patch for 02_network.
Injects a case block that re-reads WAN/LAN MAC from bdinfo mtd partition,
because the kernel DSA driver fails to read MAC via nvmem (returns all-FFs).
This script is called from diy-part1.sh — kept separate to avoid shell
heredoc tab/backslash escaping that would corrupt the patch.
"""
import sys

def patch_file(filepath: str) -> None:
    with open(filepath) as fh:
        content = fh.read()

    marker = "X1 Pro MAC fix"
    if marker in content:
        return  # idempotent: already patched

    old_tail = "exit 0"
    # Use real tab characters (\t) — no escaping needed since this is a plain
    # Python source file, not a shell heredoc.
    new_tail = """\
# X1 Pro MAC fix: kernel DSA driver fails to read MAC via nvmem for eth0/eth1,
# resulting in all-Fs. Re-read from bdinfo (wan_mac/lan_mac are local vars
# inside mediatek_setup_macs, not visible here).
case $board in
oray,x1pro-v1|oray,x1pro-v1-ubootmod)
	_x1_wan=$(mtd_get_mac_binary bdinfo 0xde00)
	if [ -n "$_x1_wan" ]; then
		ip link set eth0 address "$_x1_wan" 2>/dev/null
		ip link set eth1 address "$(macaddr_add "$_x1_wan" 1)" 2>/dev/null
	fi
	;;
esac

exit 0"""

    if old_tail not in content:
        raise RuntimeError(f"Anchor 'exit 0' not found in {filepath}")

    content = content.replace(old_tail, new_tail, 1)

    with open(filepath, "w") as fh:
        fh.write(content)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path-to-02_network>")
        sys.exit(1)
    patch_file(sys.argv[1])
