"""Locate lua_load / lua_pcall (statically linked Lua 5.1) in SGW3.exe without symbols.

Lua's base library registers {name, C function} pairs (luaL_Reg) in .rdata. "pcall" -> luaB_pcall, whose call
with r8d = -1 (LUA_MULTRET) and r9d = 0 is lua_pcall. "loadstring" -> luaB_loadstring, which calls
luaL_loadbuffer (or lua_load directly if inlined); luaL_loadbuffer's single call is lua_load.
Prints RVAs plus the first bytes of each function (used as a signature check by the mod loader).
"""
import struct
import sys

import capstone

if len(sys.argv) < 2:
    sys.exit("usage: python tools/find_lua_api.py <path to SGW3.exe>")
EXE = sys.argv[1]
b = open(EXE, "rb").read()
pe = struct.unpack_from("<I", b, 0x3C)[0]
nsec = struct.unpack_from("<H", b, pe + 6)[0]
optsz = struct.unpack_from("<H", b, pe + 20)[0]
base = struct.unpack_from("<Q", b, pe + 24 + 24)[0]
secs = []
for i in range(nsec):
    name, vs, va, rs, ro = struct.unpack_from("<8sIIII", b, pe + 24 + optsz + 40 * i)
    secs.append((name.rstrip(b"\0").decode(), va, vs, ro, rs))


def rva2off(rva):
    for _, va, vs, ro, rs in secs:
        if va <= rva < va + max(vs, rs):
            return rva - va + ro


def off2rva(off):
    for _, va, vs, ro, rs in secs:
        if ro <= off < ro + rs:
            return off - ro + va


def sec(name):
    return next(s for s in secs if s[0] == name)


# function ranges from .pdata (RUNTIME_FUNCTION: begin, end, unwind)
_, pva, pvs, pro, prs = sec(".pdata")
funcs = {}
for i in range(0, pvs, 12):
    s0, e0, _u = struct.unpack_from("<III", b, pro + i)
    if s0:
        funcs[s0] = e0


def func_bytes(rva):
    end = funcs.get(rva)
    if not end:
        raise SystemExit("no .pdata entry for %x" % rva)
    o = rva2off(rva)
    return b[o:o + (end - rva)]


def string_va(s):
    o = b.find(s.encode() + b"\0")
    while o != -1:
        # make sure it's a standalone string (preceded by a NUL)
        if b[o - 1] == 0:
            return base + off2rva(o)
        o = b.find(s.encode() + b"\0", o + 1)
    raise SystemExit("string not found: " + s)


def luareg(name):
    """find the luaL_Reg {char *name; lua_CFunction func;} entry for name -> function RVA"""
    sva = string_va(name)
    _, rva_, vs, ro, rs = sec(".rdata")
    blob = b[ro:ro + rs]
    needle = struct.pack("<Q", sva)
    hits = []
    i = blob.find(needle)
    while i != -1:
        if i % 8 == 0:
            fva = struct.unpack_from("<Q", blob, i + 8)[0]
            if fva and (fva - base) in funcs:
                hits.append(fva - base)
        i = blob.find(needle, i + 1)
    if not hits:
        raise SystemExit("no luaL_Reg entry for " + name)
    return hits[0]


md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
md.detail = True


def calls(rva):
    """list of (call target rva, preceding instructions) for direct calls in a function"""
    code = func_bytes(rva)
    out, window = [], []
    for ins in md.disasm(code, base + rva):
        if ins.mnemonic in ("call", "jmp") and ins.operands and ins.operands[0].type == capstone.x86.X86_OP_IMM:
            out.append((ins.operands[0].imm - base, list(window), ins.mnemonic))
        window = (window + ["%s %s" % (ins.mnemonic, ins.op_str)])[-6:]
    return out


def sig(rva, n=16):
    o = rva2off(rva)
    return b[o:o + n].hex()


pcall_b = luareg("pcall")
loadstring_b = luareg("loadstring")
print("luaB_pcall      rva=%#x" % pcall_b)
print("luaB_loadstring rva=%#x" % loadstring_b)

lua_pcall = None
for tgt, prev, kind in calls(pcall_b):
    txt = " | ".join(prev)
    if ("r8d, 0xffffffff" in txt or "r8d, -1" in txt) and ("xor r9d, r9d" in txt or "r9d, 0" in txt):
        lua_pcall = tgt
print("lua_pcall       rva=%s" % (hex(lua_pcall) if lua_pcall else None))

# luaB_loadstring: call(s) are luaL_checklstring, luaL_optlstring, luaL_loadbuffer, load_aux(maybe inlined)
lua_load = None
for tgt, prev, kind in calls(loadstring_b):
    size = funcs.get(tgt, 0) - tgt
    inner = [t for t, _, _ in calls(tgt)] if tgt in funcs else []
    print("  loadstring calls %#x size=%d inner_calls=%s prev=%s" % (tgt, size, [hex(x) for x in inner], " | ".join(prev[-3:])))
    if size and size < 64 and len(inner) == 1:
        # luaL_loadbuffer: tiny wrapper whose only call is lua_load
        lua_load = inner[0]
        print("  -> luaL_loadbuffer rva=%#x" % tgt)
print("lua_load        rva=%s" % (hex(lua_load) if lua_load else None))
for name, r in (("lua_pcall", lua_pcall), ("lua_load", lua_load)):
    if r:
        print("%s sig %s size %d" % (name, sig(r, 24), funcs[r] - r))
        for ins in list(md.disasm(func_bytes(r), base + r))[:14]:
            print("    %x  %s %s" % (ins.address - base, ins.mnemonic, ins.op_str))
