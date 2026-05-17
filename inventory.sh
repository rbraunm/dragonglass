#!/bin/bash
# =============================================================================
# Proxmox Cluster Inventory
# Run on any node in the cluster as root. Outputs JSON + human-readable summary.
# =============================================================================

set -euo pipefail

OUTPUT_FILE="./proxmox-inventory-$(date +%Y%m%d-%H%M%S).json"

echo "Gathering cluster inventory..."
echo ""

# ─────────────────────────────────────────────────
# Node-level info
# ─────────────────────────────────────────────────
echo "=== NODES ==="
pvesh get /nodes --output-format json 2>/dev/null | python3 -c "
import json, sys
nodes = json.load(sys.stdin)
for n in sorted(nodes, key=lambda x: x['node']):
    status = n.get('status', 'unknown')
    cpu = n.get('maxcpu', '?')
    mem_gb = round(n.get('maxmem', 0) / 1073741824, 1)
    mem_used_gb = round(n.get('mem', 0) / 1073741824, 1)
    print(f\"  {n['node']:20s}  status={status}  cpus={cpu}  ram={mem_used_gb}/{mem_gb}GB\")
"
echo ""

# ─────────────────────────────────────────────────
# Storage per node
# ─────────────────────────────────────────────────
echo "=== STORAGE ==="
for NODE in $(pvesh get /nodes --output-format json 2>/dev/null | python3 -c "
import json, sys
for n in json.load(sys.stdin):
    print(n['node'])
"); do
    echo "  [$NODE]"
    pvesh get "/nodes/$NODE/storage" --output-format json 2>/dev/null | python3 -c "
import json, sys
stores = json.load(sys.stdin)
for s in sorted(stores, key=lambda x: x.get('storage','')):
    if s.get('active', 0) != 1:
        continue
    name = s.get('storage', '?')
    stype = s.get('type', '?')
    total_gb = round(s.get('total', 0) / 1073741824, 1)
    used_gb = round(s.get('used', 0) / 1073741824, 1)
    avail_gb = round(s.get('avail', 0) / 1073741824, 1)
    content = s.get('content', '?')
    print(f'    {name:20s}  type={stype:10s}  total={total_gb:>10.1f}GB  used={used_gb:>10.1f}GB  avail={avail_gb:>10.1f}GB  content={content}')
" 2>/dev/null || echo "    (could not query storage)"
done
echo ""

# ─────────────────────────────────────────────────
# CPU + Memory detail per node
# ─────────────────────────────────────────────────
echo "=== CPU + MEMORY DETAIL ==="
for NODE in $(pvesh get /nodes --output-format json 2>/dev/null | python3 -c "
import json, sys
for n in json.load(sys.stdin):
    print(n['node'])
"); do
    echo "  [$NODE]"
    # Try to get CPU model via node status
    pvesh get "/nodes/$NODE/status" --output-format json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
ci = d.get('cpuinfo', {})
model = ci.get('model', '?')
sockets = ci.get('sockets', '?')
cores = ci.get('cores', '?')
threads = ci.get('cpus', '?')
print(f'    CPU: {model}')
print(f'    Sockets: {sockets}  Cores/socket: {cores}  Threads: {threads}')
mem = d.get('memory', {})
total_gb = round(mem.get('total', 0) / 1073741824, 1)
used_gb = round(mem.get('used', 0) / 1073741824, 1)
free_gb = round(mem.get('free', 0) / 1073741824, 1)
print(f'    RAM: {used_gb}/{total_gb}GB used, {free_gb}GB free')
" 2>/dev/null || echo "    (could not query status)"
    echo ""
done

# ─────────────────────────────────────────────────
# All VMs (QEMU)
# ─────────────────────────────────────────────────
echo "=== VIRTUAL MACHINES (QEMU) ==="
printf "  %-6s %-25s %-15s %-8s %6s %8s %10s  %-20s\n" "VMID" "NAME" "NODE" "STATUS" "CORES" "RAM(GB)" "DISK(GB)" "TAGS"
echo "  $(printf '%.0s-' {1..110})"

pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | python3 -c "
import json, sys
vms = json.load(sys.stdin)
for vm in sorted(vms, key=lambda x: (x.get('node',''), x.get('vmid',0))):
    if vm.get('type') != 'qemu':
        continue
    vmid = vm.get('vmid', '?')
    name = vm.get('name', '?')[:25]
    node = vm.get('node', '?')
    status = vm.get('status', '?')
    cores = vm.get('maxcpu', '?')
    ram_gb = round(vm.get('maxmem', 0) / 1073741824, 1)
    disk_gb = round(vm.get('maxdisk', 0) / 1073741824, 1)
    tags = vm.get('tags', '') or ''
    print(f'  {vmid:<6} {name:<25s} {node:<15s} {status:<8s} {cores:>6} {ram_gb:>8.1f} {disk_gb:>10.1f}  {tags}')
" 2>/dev/null || echo "  (no VMs found or API error)"
echo ""

# ─────────────────────────────────────────────────
# All LXC Containers
# ─────────────────────────────────────────────────
echo "=== LXC CONTAINERS ==="
printf "  %-6s %-25s %-15s %-8s %6s %8s %10s  %-20s\n" "CTID" "NAME" "NODE" "STATUS" "CORES" "RAM(GB)" "DISK(GB)" "TAGS"
echo "  $(printf '%.0s-' {1..110})"

pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | python3 -c "
import json, sys
cts = json.load(sys.stdin)
for ct in sorted(cts, key=lambda x: (x.get('node',''), x.get('vmid',0))):
    if ct.get('type') != 'lxc':
        continue
    ctid = ct.get('vmid', '?')
    name = ct.get('name', '?')[:25]
    node = ct.get('node', '?')
    status = ct.get('status', '?')
    cores = ct.get('maxcpu', '?')
    ram_gb = round(ct.get('maxmem', 0) / 1073741824, 1)
    disk_gb = round(ct.get('maxdisk', 0) / 1073741824, 1)
    tags = ct.get('tags', '') or ''
    print(f'  {ctid:<6} {name:<25s} {node:<15s} {status:<8s} {cores:>6} {ram_gb:>8.1f} {disk_gb:>10.1f}  {tags}')
" 2>/dev/null || echo "  (no containers found or API error)"
echo ""

# ─────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────
echo "=== SUMMARY ==="
pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | python3 -c "
import json, sys
resources = json.load(sys.stdin)

by_node = {}
for r in resources:
    node = r.get('node', 'unknown')
    if node not in by_node:
        by_node[node] = {'vms': 0, 'cts': 0, 'cores': 0, 'ram_gb': 0}
    if r['type'] == 'qemu':
        by_node[node]['vms'] += 1
    elif r['type'] == 'lxc':
        by_node[node]['cts'] += 1
    by_node[node]['cores'] += r.get('maxcpu', 0)
    by_node[node]['ram_gb'] += r.get('maxmem', 0) / 1073741824

for node in sorted(by_node):
    d = by_node[node]
    print(f\"  {node}: {d['vms']} VMs + {d['cts']} CTs — {d['cores']} vCPUs, {d['ram_gb']:.1f}GB RAM allocated\")
"
echo ""
echo "Done. Paste this output into our chat and we'll map everything out."
