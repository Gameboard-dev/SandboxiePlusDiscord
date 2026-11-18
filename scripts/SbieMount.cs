// Mounts an encrypted Sandboxie-Plus box by calling SbieDll_Mount directly.
//
// Why not `Start.exe /key:<password> /mount_protected`: Start.exe only takes the
// password on its command line, and any program running as the same user can
// read other processes' command lines (WMI Win32_Process.CommandLine, no admin
// needed). Command-line auditing or Sysmon would also write it to a log on disk.
// Start.exe itself does nothing more than call this export
// (apps/start/start.cpp: `SbieDll_Mount(BoxName, BoxKey, TRUE)`), declared in
// core/dll/sbiedll.h as
//     BOOLEAN SbieDll_Mount(const WCHAR* BoxName, const WCHAR* BoxKey, BOOLEAN Protect);
//
// The password arrives as UTF-8 bytes and is decoded into a pinned char[]
// rather than a System.String: strings are immutable and can't be wiped, and an
// unpinned array may be copied by the garbage collector before it is cleared.
// The caller still owns, and must clear, the byte[] it passes in.

using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class SbieMount
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);

    // Resolve SbieDll.dll's own dependencies from its folder, not the search path.
    private const uint LOAD_WITH_ALTERED_SEARCH_PATH = 0x8;

    // Bound by module name; Mount() loads it by full path first, so this
    // resolves to that already-loaded copy and never to one found on PATH.
    [DllImport("SbieDll.dll", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.StdCall)]
    [return: MarshalAs(UnmanagedType.U1)]
    private static extern bool SbieDll_Mount(string boxName, IntPtr boxKey, [MarshalAs(UnmanagedType.U1)] bool protect);

    public static bool Mount(string sbieDllPath, string boxName, byte[] keyUtf8, bool protect)
    {
        if (LoadLibraryExW(sbieDllPath, IntPtr.Zero, LOAD_WITH_ALTERED_SEARCH_PATH) == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not load " + sbieDllPath);

        int length = Encoding.UTF8.GetCharCount(keyUtf8);
        char[] key = new char[length + 1];      // + NUL terminator for the WCHAR*
        GCHandle pin = GCHandle.Alloc(key, GCHandleType.Pinned);
        try
        {
            Encoding.UTF8.GetChars(keyUtf8, 0, keyUtf8.Length, key, 0);
            return SbieDll_Mount(boxName, pin.AddrOfPinnedObject(), protect);
        }
        finally
        {
            Array.Clear(key, 0, key.Length);
            pin.Free();
        }
    }
}
