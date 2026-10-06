"""CryXmlB (binary XML) -> text XML. Layout verified against SGW3 3.8.6.53 files."""
import struct, sys, os
from xml.sax.saxutils import escape, quoteattr

def decode(b):
    if not b.startswith(b"CryXmlB\0"):
        return None
    (size, nPos, nCnt, aPos, aCnt, cPos, cCnt, sPos, sSize) = struct.unpack_from("<9I", b, 8)
    strs = b[sPos:sPos + sSize]
    def S(o):
        e = strs.index(b"\0", o)
        return strs[o:e].decode("utf-8", "replace")
    nodes = [struct.unpack_from("<IIHHiIII", b, nPos + 28 * i) for i in range(nCnt)]
    attrs = [struct.unpack_from("<II", b, aPos + 8 * i) for i in range(aCnt)]
    kids = struct.unpack_from("<%dI" % cCnt, b, cPos)
    out = []
    def emit(i, d):
        tag, content, na, nc, parent, fa, fc, _ = nodes[i]
        ind = "  " * d
        at = "".join(" %s=%s" % (S(attrs[fa + k][0]), quoteattr(S(attrs[fa + k][1]))) for k in range(na))
        txt = S(content)
        if nc == 0 and not txt:
            out.append("%s<%s%s/>" % (ind, S(tag), at)); return
        out.append("%s<%s%s>%s" % (ind, S(tag), at, escape(txt)))
        for k in range(nc):
            emit(kids[fc + k], d + 1)
        out.append("%s</%s>" % (ind if nc else "", S(tag)) if nc else "")
        if not nc:
            out[-2] += "</%s>" % S(tag); out.pop()
    emit(0, 0)
    return "\n".join(out) + "\n"

if __name__ == "__main__":
    root = sys.argv[1]; conv = fail = 0
    for dp, _, fs in os.walk(root):
        for f in fs:
            p = os.path.join(dp, f)
            with open(p, "rb") as fh:
                if fh.read(8) != b"CryXmlB\0": continue
                b = b"CryXmlB\0" + fh.read()
            try:
                t = decode(b)
                open(p, "w", encoding="utf-8").write(t); conv += 1
            except Exception as e:
                fail += 1; print("FAIL", p, e)
    print("converted", conv, "failed", fail)
