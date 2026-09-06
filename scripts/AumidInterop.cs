using System;
using System.Runtime.InteropServices;
using System.Text;

// Interop shared by get-window-aumid.ps1 and set-shortcut-aumid.ps1.
//
// The Windows taskbar groups buttons by AppUserModelID (AUMID), not by
// executable path. Reading the AUMID a window presents, and writing the AUMID a
// shortcut claims, both go through IPropertyStore and the same property key:
//
//     PKEY_AppUserModel_ID = {9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}, 5
//
// Loaded with Add-Type -Path so it stays ordinary C# that an editor can parse.
namespace Aum
{
    [StructLayout(LayoutKind.Sequential)]
    public struct PropertyKey
    {
        public Guid fmtid;
        public uint pid;
    }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore
    {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, IntPtr pv);
        void SetValue(ref PropertyKey key, IntPtr pv);
        void Commit();
    }

    [ComImport, Guid("0000010b-0000-0000-C000-000000000046"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPersistFile
    {
        void GetClassID(out Guid classId);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string fileName, uint mode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string fileName,
                  [MarshalAs(UnmanagedType.Bool)] bool remember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string fileName);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string fileName);
    }

    /// <summary>CLSID_ShellLink. A .lnk exposes IPropertyStore beside IPersistFile.</summary>
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    public class ShellLink
    {
    }

    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lparam);

    /// <summary>Top-level window enumeration.</summary>
    public static class Native
    {
        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lparam);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hwnd);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowTextW(IntPtr hwnd, StringBuilder buffer, int capacity);

        public static string GetWindowTitle(IntPtr hwnd)
        {
            StringBuilder buffer = new StringBuilder(512);
            GetWindowTextW(hwnd, buffer, buffer.Capacity);
            return buffer.ToString();
        }
    }

    /// <summary>PROPVARIANT handling, kept in one place for both directions.</summary>
    internal static class PropVariant
    {
        // PROPVARIANT: vt at offset 0, union at offset 8 on x86 and x64 alike.
        // 32 bytes is comfortably larger than either layout.
        internal const int Size = 32;
        const ushort VT_LPWSTR = 31;

        [DllImport("ole32.dll")]
        internal static extern void PropVariantClear(IntPtr pv);

        [DllImport("propsys.dll", CharSet = CharSet.Unicode)]
        static extern int PropVariantToStringAlloc(IntPtr pv, out IntPtr ppsz);

        internal static IntPtr Alloc()
        {
            IntPtr pv = Marshal.AllocCoTaskMem(Size);
            for (int i = 0; i < Size; i++) Marshal.WriteByte(pv, i, 0);
            return pv;
        }

        /// <summary>
        /// InitPropVariantFromString is an inline in propvarutil.h rather than an
        /// export, so the string variant is laid out by hand. The buffer must come
        /// from the COM task allocator: PropVariantClear frees it with CoTaskMemFree.
        /// </summary>
        internal static void SetString(IntPtr pv, string value)
        {
            Marshal.WriteInt16(pv, 0, unchecked((short) VT_LPWSTR));
            Marshal.WriteIntPtr(pv, 8, Marshal.StringToCoTaskMemUni(value));
        }

        /// <summary>Null when the variant is empty or holds no string.</summary>
        internal static string GetString(IntPtr pv)
        {
            IntPtr str;
            if (PropVariantToStringAlloc(pv, out str) != 0) return null;

            string value = Marshal.PtrToStringUni(str);
            Marshal.FreeCoTaskMem(str);
            return value;
        }
    }

    /// <summary>Reads the AUMID a live window presents to the shell.</summary>
    public static class WindowAumid
    {
        [DllImport("shell32.dll")]
        static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid,
            [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);

        public static PropertyKey Key
        {
            get
            {
                PropertyKey key = new PropertyKey();
                key.fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
                key.pid = 5;
                return key;
            }
        }

        /// <summary>Null when the window inherits the shell default.</summary>
        public static string Read(IntPtr hwnd)
        {
            Guid iid = new Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99");
            IPropertyStore store;
            if (SHGetPropertyStoreForWindow(hwnd, ref iid, out store) != 0 || store == null)
                return null;

            PropertyKey key = Key;
            IntPtr pv = PropVariant.Alloc();
            try
            {
                store.GetValue(ref key, pv);
                return PropVariant.GetString(pv);
            }
            finally
            {
                PropVariant.PropVariantClear(pv);
                Marshal.FreeCoTaskMem(pv);
                Marshal.ReleaseComObject(store);
            }
        }
    }

    /// <summary>Reads and writes the AUMID a .lnk claims.</summary>
    public static class ShortcutAumid
    {
        const uint STGM_READ = 0x00000000;
        const uint STGM_READWRITE = 0x00000002;

        /// <summary>Null when the shortcut carries no AUMID.</summary>
        public static string Read(string lnkPath)
        {
            object link = new ShellLink();
            try
            {
                ((IPersistFile) link).Load(lnkPath, STGM_READ);

                IPropertyStore store = (IPropertyStore) link;
                PropertyKey key = WindowAumid.Key;

                IntPtr pv = PropVariant.Alloc();
                try
                {
                    store.GetValue(ref key, pv);
                    return PropVariant.GetString(pv);
                }
                finally
                {
                    PropVariant.PropVariantClear(pv);
                    Marshal.FreeCoTaskMem(pv);
                }
            }
            finally
            {
                Marshal.ReleaseComObject(link);
            }
        }

        /// <summary>Stamps the AUMID, leaving every other link property intact.</summary>
        public static void Write(string lnkPath, string aumid)
        {
            object link = new ShellLink();
            try
            {
                IPersistFile file = (IPersistFile) link;
                file.Load(lnkPath, STGM_READWRITE);

                IPropertyStore store = (IPropertyStore) link;
                PropertyKey key = WindowAumid.Key;

                IntPtr pv = PropVariant.Alloc();
                try
                {
                    PropVariant.SetString(pv, aumid);
                    store.SetValue(ref key, pv);
                    store.Commit();
                }
                finally
                {
                    PropVariant.PropVariantClear(pv);
                    Marshal.FreeCoTaskMem(pv);
                }

                file.Save(lnkPath, true);
            }
            finally
            {
                Marshal.ReleaseComObject(link);
            }
        }
    }
}
