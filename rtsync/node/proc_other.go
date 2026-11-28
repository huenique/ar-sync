//go:build !windows

package node

// ProcessRunning is only implemented on Windows, where Aronium runs.
func ProcessRunning(image string) bool { return false }
