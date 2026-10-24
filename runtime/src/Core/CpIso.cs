// Lector mínimo de imágenes ISO 9660 con extensión Joliet (solo lectura).
// Permite validar los discos y copiar su contenido sin montarlos.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public sealed class CpIsoEntry {
    public string Path;     // ruta con '\' relativa a la raíz, sin barra inicial
    public bool IsDirectory;
    public long Lba;
    public long Size;
    public DateTime Modified;
}

public sealed class CpIso : IDisposable {
    const int Sector = 2048;
    readonly FileStream fs;
    readonly bool joliet;
    readonly long rootLba;
    readonly long rootSize;
    public string VolumeLabel { get; private set; }
    public string FilePath { get; private set; }

    public CpIso(string path) {
        FilePath = path;
        fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16);
        byte[] pvd = null, svd = null;
        for (int i = 16; i < 64; i++) {
            byte[] d = ReadSectors(i, 1);
            if (d[1] != 'C' || d[2] != 'D' || d[3] != '0' || d[4] != '0' || d[5] != '1')
                throw new InvalidDataException("No es una imagen ISO 9660 válida.");
            if (d[0] == 1 && pvd == null) pvd = d;
            else if (d[0] == 2 && d[88] == 0x25 && d[89] == 0x2F && (d[90] == 0x40 || d[90] == 0x43 || d[90] == 0x45)) svd = d;
            else if (d[0] == 255) break;
        }
        if (pvd == null) throw new InvalidDataException("La imagen no tiene descriptor de volumen primario.");
        byte[] vd = svd ?? pvd;
        joliet = svd != null;
        VolumeLabel = joliet ? Encoding.BigEndianUnicode.GetString(vd, 40, 32).TrimEnd(' ', '\0')
                             : Encoding.ASCII.GetString(vd, 40, 32).TrimEnd(' ', '\0');
        rootLba = BitConverter.ToUInt32(vd, 156 + 2);
        rootSize = BitConverter.ToUInt32(vd, 156 + 10);
    }

    byte[] ReadSectors(long lba, int count) {
        byte[] buf = new byte[count * Sector];
        fs.Seek(lba * Sector, SeekOrigin.Begin);
        int read = 0;
        while (read < buf.Length) {
            int n = fs.Read(buf, read, buf.Length - read);
            if (n <= 0) throw new EndOfStreamException("La imagen ISO está truncada.");
            read += n;
        }
        return buf;
    }

    IEnumerable<CpIsoEntry> ReadDir(long lba, long size, string prefix) {
        byte[] data = ReadSectors(lba, (int)((size + Sector - 1) / Sector));
        int pos = 0;
        while (pos < size) {
            int len = data[pos];
            if (len == 0) { pos = ((pos / Sector) + 1) * Sector; continue; }
            int nameLen = data[pos + 32];
            bool isDir = (data[pos + 25] & 2) != 0;
            string name;
            if (nameLen == 1 && (data[pos + 33] == 0 || data[pos + 33] == 1)) { pos += len; continue; }
            if (joliet) name = Encoding.BigEndianUnicode.GetString(data, pos + 33, nameLen);
            else name = Encoding.ASCII.GetString(data, pos + 33, nameLen);
            int semi = name.IndexOf(';');
            if (semi >= 0) name = name.Substring(0, semi);
            if (!isDir && name.EndsWith(".")) name = name.Substring(0, name.Length - 1);
            DateTime mod;
            try {
                mod = new DateTime(1900 + data[pos + 18], data[pos + 19], data[pos + 20], data[pos + 21], data[pos + 22], data[pos + 23]);
            } catch { mod = DateTime.Now; }
            yield return new CpIsoEntry {
                Path = prefix.Length == 0 ? name : prefix + "\\" + name,
                IsDirectory = isDir,
                Lba = BitConverter.ToUInt32(data, pos + 2),
                Size = BitConverter.ToUInt32(data, pos + 10),
                Modified = mod
            };
            pos += len;
        }
    }

    /// <summary>Recorre todo el árbol (o el subárbol indicado).</summary>
    public List<CpIsoEntry> List(string subdir) {
        var result = new List<CpIsoEntry>();
        var stack = new Stack<CpIsoEntry>();
        if (string.IsNullOrEmpty(subdir)) {
            stack.Push(new CpIsoEntry { Path = "", IsDirectory = true, Lba = rootLba, Size = rootSize });
        } else {
            CpIsoEntry d = Find(subdir);
            if (d == null || !d.IsDirectory) return result;
            stack.Push(d);
        }
        while (stack.Count > 0) {
            CpIsoEntry dir = stack.Pop();
            foreach (CpIsoEntry e in ReadDir(dir.Lba, dir.Size, dir.Path)) {
                result.Add(e);
                if (e.IsDirectory) stack.Push(e);
            }
        }
        return result;
    }

    /// <summary>Busca una ruta (sin distinguir mayúsculas). Devuelve null si no existe.</summary>
    public CpIsoEntry Find(string path) {
        string[] parts = path.Replace('/', '\\').Trim('\\').Split('\\');
        long lba = rootLba, size = rootSize;
        string prefix = "";
        CpIsoEntry found = null;
        foreach (string part in parts) {
            found = null;
            foreach (CpIsoEntry e in ReadDir(lba, size, prefix)) {
                string n = e.Path.Substring(e.Path.LastIndexOf('\\') + 1);
                if (string.Equals(n, part, StringComparison.OrdinalIgnoreCase)) { found = e; break; }
            }
            if (found == null) return null;
            lba = found.Lba; size = found.Size; prefix = found.Path;
        }
        return found;
    }

    /// <summary>Copia un archivo de la imagen a disco. Devuelve los bytes copiados.</summary>
    public long Extract(CpIsoEntry e, string destination) {
        byte[] buf = new byte[1 << 20];
        long remaining = e.Size;
        fs.Seek(e.Lba * Sector, SeekOrigin.Begin);
        using (var outFs = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16)) {
            while (remaining > 0) {
                int n = fs.Read(buf, 0, (int)Math.Min(buf.Length, remaining));
                if (n <= 0) throw new EndOfStreamException("La imagen ISO está truncada (" + e.Path + ").");
                outFs.Write(buf, 0, n);
                remaining -= n;
            }
        }
        File.SetLastWriteTime(destination, e.Modified);
        return e.Size;
    }

    public void Dispose() { fs.Dispose(); }
}
