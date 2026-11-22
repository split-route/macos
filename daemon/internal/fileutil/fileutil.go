// Package fileutil holds small file helpers shared by the config, list cache
// and state writers.
package fileutil

import (
	"os"
	"path/filepath"
)

// WriteAtomic writes b to a temporary file next to path and renames it over
// path, so readers never see a half-written file.
func WriteAtomic(path string, b []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
