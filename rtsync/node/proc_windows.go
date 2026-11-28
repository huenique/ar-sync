//go:build windows

package node

import (
	"regexp"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

func eachProcess(f func(name string, pid uint32) bool) {
	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return
	}
	defer windows.CloseHandle(snap)
	var e windows.ProcessEntry32
	e.Size = uint32(unsafe.Sizeof(e))
	for err = windows.Process32First(snap, &e); err == nil; err = windows.Process32Next(snap, &e) {
		if !f(windows.UTF16ToString(e.ExeFile[:]), e.ProcessID) {
			return
		}
	}
}

// ProcessRunning reports whether a process with this image name runs.
func ProcessRunning(image string) bool {
	found := false
	eachProcess(func(name string, _ uint32) bool {
		found = strings.EqualFold(name, image)
		return !found
	})
	return found
}

// ProcessStarted returns the start time of the first process with this image name.
func ProcessStarted(image string) (time.Time, bool) {
	var pid uint32
	eachProcess(func(name string, id uint32) bool {
		if strings.EqualFold(name, image) {
			pid = id
			return false
		}
		return true
	})
	if pid == 0 {
		return time.Time{}, false
	}
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return time.Time{}, true
	}
	defer windows.CloseHandle(h)
	var c, x, k, u windows.Filetime
	if err := windows.GetProcessTimes(h, &c, &x, &k, &u); err != nil {
		return time.Time{}, true
	}
	return time.Unix(0, c.Nanoseconds()), true
}

// Aronium's installer is Aronium.Lite.Setup*.exe; its in-app updater downloads
// "<version>.exe" (e.g. 1.52.2.0.exe); its uninstaller is unins000.exe.
var updaterRE = regexp.MustCompile(`(?i)^(aronium.*setup.*|\d+\.\d+\.\d+\.\d+|unins\d+)\.(exe|tmp)$`)

// UpdaterRunning reports an Aronium installer, updater or uninstaller running.
func UpdaterRunning() bool {
	found := false
	eachProcess(func(name string, _ uint32) bool {
		found = updaterRE.MatchString(name)
		return !found
	})
	return found
}
