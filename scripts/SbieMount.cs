// Mounts an encrypted Sandboxie-Plus box by calling SbieDll_Mount directly, and
// tells whether it is already mounted (IsMounted).
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

    // Bound by module name; Load() loads it by full path first, so these
    // resolve to that already-loaded copy and never to one found on PATH.
    [DllImport("SbieDll.dll", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.StdCall)]
    [return: MarshalAs(UnmanagedType.U1)]
    private static extern bool SbieDll_Mount(string boxName, IntPtr boxKey, [MarshalAs(UnmanagedType.U1)] bool protect);

    // core/dll/sbieapi.h. Returns the box's file root as an NT path, such as
    // \Device\HarddiskVolume3\Sandbox\<user>\<box>. Lengths are in bytes.
    [DllImport("SbieDll.dll", CharSet = CharSet.Unicode)]
    private static extern int SbieApi_QueryBoxPath(string boxName, StringBuilder filePath, IntPtr keyPath, IntPtr ipcPath,
        ref uint filePathLen, IntPtr keyPathLen, IntPtr ipcPathLen);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFileAttributesW(string path);

    private const uint INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF;
    private const int ERROR_ACCESS_DENIED = 5;

    private static void Load(string sbieDllPath)
    {
        if (LoadLibraryExW(sbieDllPath, IntPtr.Zero, LOAD_WITH_ALTERED_SEARCH_PATH) == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not load " + sbieDllPath);
    }

    // Whether the box's encrypted image is mounted. An image box's file root
    // exists only while it is mounted: Sandboxie creates it as a junction into
    // the image volume and removes it on unmount. With root protection, opening
    // it is refused (ERROR_ACCESS_DENIED), which also means "mounted". Anything
    // else, including a failed query, returns false, so the caller unlocks as
    // before: a wrong answer can cost a Windows Hello prompt, never skip a
    // needed unlock.
    public static bool IsMounted(string sbieDllPath, string boxName)
    {
        Load(sbieDllPath);
        uint length = 0;
        if (SbieApi_QueryBoxPath(boxName, null, IntPtr.Zero, IntPtr.Zero, ref length, IntPtr.Zero, IntPtr.Zero) != 0 || length == 0)
            return false;
        var root = new StringBuilder((int)(length / 2) + 1);
        if (SbieApi_QueryBoxPath(boxName, root, IntPtr.Zero, IntPtr.Zero, ref length, IntPtr.Zero, IntPtr.Zero) != 0)
            return false;

        // \\?\GLOBALROOT lets Win32 file functions take an NT device path.
        if (GetFileAttributesW(@"\\?\GLOBALROOT" + root.ToString()) != INVALID_FILE_ATTRIBUTES)
            return true;
        return Marshal.GetLastWin32Error() == ERROR_ACCESS_DENIED;
    }

    public static bool Mount(string sbieDllPath, string boxName, byte[] keyUtf8, bool protect)
    {
        Load(sbieDllPath);

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
