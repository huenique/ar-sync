//go:build windows

package node

import (
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

// ProcessRunning reports whether a process with this image name runs.
func ProcessRunning(image string) bool {
	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return false
	}
	defer windows.CloseHandle(snap)
	var e windows.ProcessEntry32
	e.Size = uint32(unsafe.Sizeof(e))
	for err = windows.Process32First(snap, &e); err == nil; err = windows.Process32Next(snap, &e) {
		if strings.EqualFold(windows.UTF16ToString(e.ExeFile[:]), image) {
			return true
		}
	}
	return false
}
