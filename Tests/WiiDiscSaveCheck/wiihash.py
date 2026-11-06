#!/usr/bin/env python3
# Independent Wii data-partition integrity check, from the documented disc format (not the app's
# code): H0 (per 0x400 block), H1 (per subgroup of 8 clusters), H2 (per group of 64), H3 table,
# TMD content hash (H4), and that every FST file lies inside the partition's declared data size.
#   wiihash.py disc.iso common-key [file-name ...]   (checks the groups holding those files + the
#                                                   FST; with no names, every group)
import hashlib, struct, sys
from Crypto.Cipher import AES

iso, keyfile = sys.argv[1], sys.argv[2]
want = set(sys.argv[3:])
f = open(iso, "rb")
ck = open(keyfile, "rb").read()[:16]
def rd(o, n): f.seek(o); return f.read(n)
def be32(b, o): return struct.unpack_from(">I", b, o)[0]

nparts, toff = struct.unpack(">II", rd(0x40000, 8))
parts = [struct.unpack(">II", rd((toff << 2) + 8 * i, 8)) for i in range(nparts)]
poff = next(o << 2 for o, t in parts if t == 0)
tik = rd(poff, 0x2A4)
iv = tik[0x1DC:0x1E4] + b"\0" * 8
tkey = AES.new(ck, AES.MODE_CBC, iv).decrypt(tik[0x1BF:0x1CF])
hdr = rd(poff + 0x2A4, 0x1C)
tmd_size, tmd_off, _, _, h3_off, data_off, data_size = struct.unpack(">IIIIIII", hdr)
tmd_off, h3_off, data_off, data_size = [x << 2 for x in (tmd_off, h3_off, data_off, data_size)]
tmd = rd(poff + tmd_off, tmd_size)
h3 = rd(poff + h3_off, 0x18000)
nclusters = data_size // 0x8000
problems = []

def cluster(c):
    raw = rd(poff + data_off + c * 0x8000, 0x8000)
    if len(raw) < 0x8000: return None, None
    hb = AES.new(tkey, AES.MODE_CBC, b"\0" * 16).decrypt(raw[:0x400])
    data = AES.new(tkey, AES.MODE_CBC, raw[0x3D0:0x3E0]).decrypt(raw[0x400:])
    return hb, data

def read_stream(off, n):
    out = b""
    while n > 0:
        c, i = divmod(off, 0x7C00)
        _, d = cluster(c)
        t = min(n, 0x7C00 - i); out += d[i:i + t]; off += t; n -= t
    return out

def check_group(g):
    bad = 0
    hbs = []
    for k in range(64):
        c = g * 64 + k
        if c >= nclusters: break
        hb, data = cluster(c)
        if hb is None: problems.append(f"cluster {c} missing from file"); bad += 1; continue
        hbs.append(hb)
        for b in range(31):
            if hashlib.sha1(data[b * 0x400:(b + 1) * 0x400]).digest() != hb[b * 20:(b + 1) * 20]:
                problems.append(f"H0 mismatch: cluster {c} block {b}"); bad += 1; break
        if hashlib.sha1(hb[:0x26C]).digest() != hb[0x280 + (k % 8) * 20:0x280 + (k % 8 + 1) * 20]:
            problems.append(f"H1 mismatch: cluster {c}"); bad += 1
        if hashlib.sha1(hb[0x280:0x320]).digest() != hb[0x340 + (k // 8) * 20:0x340 + (k // 8 + 1) * 20]:
            problems.append(f"H2 mismatch: cluster {c}"); bad += 1
    if hbs and hashlib.sha1(hbs[0][0x340:0x3E0]).digest() != h3[g * 20:(g + 1) * 20]:
        problems.append(f"H3 mismatch: group {g}"); bad += 1
    return bad

# FST
boot = read_stream(0, 0x440)
fst_off, fst_size = be32(boot, 0x424) << 2, be32(boot, 0x428) << 2
fst = read_stream(fst_off, fst_size)
n = be32(fst, 8)
strtab = 12 * n
files = {}
for i in range(1, n):
    e = fst[12 * i:12 * i + 12]
    if e[0] == 0:
        name = fst[strtab + (be32(e, 0) & 0xFFFFFF):].split(b"\0")[0].decode()
        files.setdefault(name, []).append((be32(e, 4) << 2, be32(e, 8)))
capacity = nclusters * 0x7C00
outside = [(nm, o, s) for nm, l in files.items() for o, s in l if o + s > capacity]
for nm, o, s in outside[:5]:
    problems.append(f"{nm} ends at stream 0x{o + s:x}, past the partition's data (0x{capacity:x})")

groups = set()
groups.add(0); groups.add(fst_off // 0x7C00 // 64)
for nm in want:
    for o, s in files.get(nm, []):
        for c in range(o // 0x7C00, (o + s - 1) // 0x7C00 + 1): groups.add(c // 64)
    if nm not in files: problems.append(f"{nm} not in FST")
if not want: groups = set(range((nclusters + 63) // 64))
for g in sorted(groups): check_group(g)

h4 = tmd[0x1E4 + 0x10:0x1E4 + 0x24]
if hashlib.sha1(h3).digest() != h4: problems.append("H4 (TMD content hash of the H3 table) mismatch")
print(f"checked {len(groups)} group(s); data size 0x{data_size:x} ({nclusters} clusters)")
print("\n".join(problems[:20]) if problems else "OK: hash tree, H3, H4 and FST extents all valid")
sys.exit(1 if problems else 0)
