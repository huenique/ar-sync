//go:build !windows

package node

import "time"

// Process checks are only implemented on Windows, where Aronium runs.
func ProcessRunning(image string) bool              { return false }
func ProcessStarted(image string) (time.Time, bool) { return time.Time{}, false }
func UpdaterRunning() bool                          { return false }
