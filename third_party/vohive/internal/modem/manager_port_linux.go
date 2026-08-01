//go:build linux

package modem

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/1239t/vohive/pkg/logger"
)

// prepareSerialPortForOpen preserves the existing Linux takeover behavior.
// Darwin intentionally has a different fail-closed implementation and never
// invokes fuser or signals another process.
func (m *Manager) prepareSerialPortForOpen(portPath string) error {
	if _, err := os.Stat(portPath); err != nil {
		return nil
	}

	out, _ := exec.Command("fuser", portPath).CombinedOutput()
	if len(out) == 0 {
		return nil
	}
	occupiedPIDs := parseFuserPIDs(string(out))
	if len(occupiedPIDs) == 0 {
		return nil
	}

	selfTaskPIDs := currentProcessTaskPIDSet()
	released := make([]int, 0, len(occupiedPIDs))
	skipped := make([]int, 0, len(occupiedPIDs))
	for _, pid := range occupiedPIDs {
		if pid <= 2 {
			skipped = append(skipped, pid)
			continue
		}
		if _, isSelf := selfTaskPIDs[pid]; isSelf {
			skipped = append(skipped, pid)
			continue
		}
		if err := syscall.Kill(pid, syscall.SIGTERM); err == nil {
			released = append(released, pid)
		}
	}

	if len(skipped) > 0 {
		logger.Warn(fmt.Sprintf("[%s] 端口被当前进程占用，跳过自杀式释放", m.cfg.ID), "port", portPath, "self_pids", skipped)
	}
	if len(released) > 0 {
		logger.Warn(fmt.Sprintf("[%s] 检测到端口被外部进程占用，正在强制释放", m.cfg.ID), "port", portPath, "pids", released)
		time.Sleep(200 * time.Millisecond)
	}
	return nil
}

func parseFuserPIDs(raw string) []int {
	if idx := strings.Index(raw, ":"); idx >= 0 && idx+1 < len(raw) {
		raw = raw[idx+1:]
	}
	seen := make(map[int]struct{})
	out := make([]int, 0)
	fields := strings.FieldsFunc(raw, func(r rune) bool {
		return r < '0' || r > '9'
	})
	for _, field := range fields {
		pid, err := strconv.Atoi(strings.TrimSpace(field))
		if err != nil || pid <= 0 {
			continue
		}
		if _, ok := seen[pid]; ok {
			continue
		}
		seen[pid] = struct{}{}
		out = append(out, pid)
	}
	return out
}

func currentProcessTaskPIDSet() map[int]struct{} {
	out := map[int]struct{}{os.Getpid(): {}}
	entries, err := os.ReadDir("/proc/self/task")
	if err != nil {
		return out
	}
	for _, entry := range entries {
		pid, err := strconv.Atoi(strings.TrimSpace(entry.Name()))
		if err == nil && pid > 0 {
			out[pid] = struct{}{}
		}
	}
	return out
}
