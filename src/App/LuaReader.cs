// Reads a SavedVariables file (the Lua data file the game writes for an add-on) into .NET values, without running any
// Lua. Tables whose keys are exactly 1..n become object[]; other tables become Hashtable with string keys. Strings are
// decoded from their bytes as UTF-8 (the game writes \ddd escapes as raw bytes). Integral numbers become long, others
// double. Written for C# 5, the compiler Windows PowerShell 5.1's Add-Type uses.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

public static class JourneyMasterLua
{
    public static Hashtable Parse(byte[] bytes)
    {
        Reader r = new Reader(bytes);
        return r.Globals();
    }

    private class Reader
    {
        private readonly byte[] b;
        private int i;
        private static readonly Encoding Utf8 = new UTF8Encoding(false, false);

        public Reader(byte[] bytes)
        {
            b = bytes;
            i = (b.Length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) ? 3 : 0;
        }

        private Exception Fail(string what)
        {
            return new FormatException(what + " at byte " + i);
        }

        public Hashtable Globals()
        {
            Hashtable g = new Hashtable();
            while (true)
            {
                Skip();
                if (i >= b.Length) break;
                string name = Ident();
                Skip();
                Expect((byte)'=');
                object gv = Value();
                if (gv != null) g[name] = gv;
            }
            return g;
        }

        private void Skip()
        {
            while (i < b.Length)
            {
                byte c = b[i];
                if (c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == ';') { i++; continue; }
                if (c == '-' && i + 1 < b.Length && b[i + 1] == '-')
                {
                    i += 2;
                    if (i + 1 < b.Length && b[i] == '[' && (b[i + 1] == '[' || b[i + 1] == '='))
                    {
                        LongString();
                    }
                    else
                    {
                        while (i < b.Length && b[i] != '\n') i++;
                    }
                    continue;
                }
                break;
            }
        }

        private void Expect(byte c)
        {
            if (i >= b.Length || b[i] != c) throw Fail("expected '" + (char)c + "'");
            i++;
        }

        private static bool IdStart(byte c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
        private static bool IdPart(byte c) { return IdStart(c) || (c >= '0' && c <= '9'); }

        private string Ident()
        {
            int start = i;
            if (i >= b.Length || !IdStart(b[i])) throw Fail("expected a name");
            while (i < b.Length && IdPart(b[i])) i++;
            return Encoding.ASCII.GetString(b, start, i - start);
        }

        private object Value()
        {
            Skip();
            if (i >= b.Length) throw Fail("unexpected end");
            byte c = b[i];
            if (c == '{') return Table();
            if (c == '"' || c == '\'') return QuotedString();
            if (c == '[' && i + 1 < b.Length && (b[i + 1] == '[' || b[i + 1] == '=')) return LongString();
            if (c == '-' || c == '.' || (c >= '0' && c <= '9')) return Number();
            string id = Ident();
            if (id == "true") return true;
            if (id == "false") return false;
            if (id == "nil") return null;
            throw Fail("unexpected name " + id);
        }

        private object Number()
        {
            int start = i;
            if (b[i] == '-') i++;
            if (i + 1 < b.Length && b[i] == '0' && (b[i + 1] == 'x' || b[i + 1] == 'X'))
            {
                i += 2;
                int hs = i;
                while (i < b.Length && Uri.IsHexDigit((char)b[i])) i++;
                long hv = long.Parse(Encoding.ASCII.GetString(b, hs, i - hs), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
                return b[start] == '-' ? -hv : hv;
            }
            while (i < b.Length)
            {
                byte c = b[i];
                if ((c >= '0' && c <= '9') || c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') { i++; continue; }
                if ((c == 'i' || c == 'n' || c == 'a' || c == 'f') && i > start) { i++; continue; } // inf, nan
                break;
            }
            string s = Encoding.ASCII.GetString(b, start, i - start);
            double d;
            if (!double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out d))
            {
                if (s.Contains("inf")) return s.StartsWith("-") ? double.NegativeInfinity : double.PositiveInfinity;
                return double.NaN;
            }
            if (d == Math.Floor(d) && Math.Abs(d) < 9.0e15) return (long)d;
            return d;
        }

        private string QuotedString()
        {
            byte q = b[i++];
            List<byte> outb = new List<byte>();
            while (true)
            {
                if (i >= b.Length) throw Fail("unfinished string");
                byte c = b[i++];
                if (c == q) break;
                if (c != '\\') { outb.Add(c); continue; }
                if (i >= b.Length) throw Fail("unfinished escape");
                byte e = b[i++];
                switch ((char)e)
                {
                    case 'n': outb.Add((byte)'\n'); break;
                    case 't': outb.Add((byte)'\t'); break;
                    case 'r': outb.Add((byte)'\r'); break;
                    case 'a': outb.Add(7); break;
                    case 'b': outb.Add(8); break;
                    case 'f': outb.Add(12); break;
                    case 'v': outb.Add(11); break;
                    case '\n': outb.Add((byte)'\n'); if (i < b.Length && b[i] == '\r') i++; break;
                    case '\r': outb.Add((byte)'\n'); if (i < b.Length && b[i] == '\n') i++; break;
                    default:
                        if (e >= '0' && e <= '9')
                        {
                            int v = e - '0';
                            for (int k = 0; k < 2 && i < b.Length && b[i] >= '0' && b[i] <= '9'; k++) v = v * 10 + (b[i++] - '0');
                            outb.Add((byte)v);
                        }
                        else outb.Add(e); // \\ \" \' and anything else: the character itself
                        break;
                }
            }
            return Utf8.GetString(outb.ToArray());
        }

        private string LongString()
        {
            Expect((byte)'[');
            int level = 0;
            while (i < b.Length && b[i] == '=') { level++; i++; }
            Expect((byte)'[');
            if (i < b.Length && b[i] == '\r') i++;
            if (i < b.Length && b[i] == '\n') i++;
            int start = i;
            while (i < b.Length)
            {
                if (b[i] == ']')
                {
                    int j = i + 1, n = 0;
                    while (j < b.Length && b[j] == '=') { n++; j++; }
                    if (n == level && j < b.Length && b[j] == ']')
                    {
                        string s = Utf8.GetString(b, start, i - start);
                        i = j + 1;
                        return s;
                    }
                }
                i++;
            }
            throw Fail("unfinished long string");
        }

        private static string KeyText(object key)
        {
            if (key is long) return ((long)key).ToString(CultureInfo.InvariantCulture);
            if (key is double) return ((double)key).ToString("R", CultureInfo.InvariantCulture);
            if (key is bool) return ((bool)key) ? "true" : "false";
            return Convert.ToString(key, CultureInfo.InvariantCulture);
        }

        private object Table()
        {
            Expect((byte)'{');
            Hashtable h = new Hashtable();
            long next = 1;
            bool sequence = true;
            while (true)
            {
                Skip();
                if (i >= b.Length) throw Fail("unfinished table");
                if (b[i] == '}') { i++; break; }
                object key = null;
                if (b[i] == '[' && !(i + 1 < b.Length && (b[i + 1] == '[' || b[i + 1] == '=')))
                {
                    i++;
                    key = Value();
                    Skip();
                    Expect((byte)']');
                    Skip();
                    Expect((byte)'=');
                }
                else if (IdStart(b[i]))
                {
                    int save = i;
                    string id = Ident();
                    Skip();
                    if (i < b.Length && b[i] == '=' && !(i + 1 < b.Length && b[i + 1] == '=')) { i++; key = id; }
                    else i = save;
                }
                object v = Value();
                if (key == null) key = next++;
                if (v != null)
                {
                    string k = KeyText(key);
                    h[k] = v;
                    if (!(key is long)) sequence = false;
                }
                Skip();
                if (i < b.Length && (b[i] == ',' || b[i] == ';')) i++;
            }
            if (sequence && h.Count > 0)
            {
                object[] arr = new object[h.Count];
                for (int n = 1; n <= h.Count; n++)
                {
                    string k = n.ToString(CultureInfo.InvariantCulture);
                    if (!h.ContainsKey(k)) return h;
                    arr[n - 1] = h[k];
                }
                return arr;
            }
            return h;
        }
    }
}
