import Foundation
import Darwin

// Pure kernel queries (proc_pidinfo) with no shared state — runs off the main
// actor from the terminal's CWD-polling background queue.
nonisolated class CWDDetector {
    static func getCWD(for pid: pid_t) -> String? {
        // Ask the kernel directly for the process's current directory.
        // Unlike spawning lsof, this costs microseconds and no subprocess.
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard result == size else { return nil }

        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        return path.isEmpty ? nil : path
    }
}
