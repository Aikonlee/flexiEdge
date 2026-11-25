"""Patch legacy DNS discovery without making DNS a prerequisite for NIC listing."""
import sys
from pathlib import Path

OLD = '''        command = "systemd-resolve --status " + interface_name
        res = subprocess.check_output(command, shell=True).decode("utf-8")
        print("DNS configuration for interface %s" % (interface_name))
        print(res)
        dns = _get_interface_dns(res, interface_name)
        interface["dnsServers"] = dns.get("DNS Servers", [])
        interface["dnsDomains"] = dns.get("DNS Domain", [])'''
NEW = '''        interface["dnsServers"] = _read_link_dns("dns", interface_name)
        interface["dnsDomains"] = _read_link_dns("domain", interface_name)'''
HELPER = '''def _read_link_dns(field, interface_name):
    try:
        output = subprocess.check_output(
            ["resolvectl", field, "--", interface_name],
            text=True, stderr=subprocess.PIPE, timeout=3,
            env=dict(os.environ, LC_ALL="C"),
        )
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"Could not read {field} for {interface_name}: {exc}", file=sys.stderr)
        return []
    header, separator, values = output.partition(":")
    return values.split() if separator and header.endswith(f"({interface_name})") else []


'''


def patch(path):
    source = path.read_text(encoding="utf-8")
    if source.count(HELPER) == source.count(NEW) == 1 and OLD not in source:
        return
    anchor = "def _get_interfaces():"
    if source.count(OLD) != 1 or source.count(anchor) != 1 or NEW in source or "def _read_link_dns(" in source:
        raise ValueError("Unexpected Edge UI interface reader; no changes applied")
    updated = source.replace(OLD, NEW, 1).replace(anchor, HELPER + anchor, 1)
    compile(updated, str(path), "exec")
    path.write_text(updated, encoding="utf-8")


if __name__ == "__main__":
    patch(Path(sys.argv[1]))
