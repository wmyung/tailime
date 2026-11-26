//go:build !windows

package storage

import (
	"os"
	"path/filepath"
)

func dpapiProtect(plaintext []byte) ([]byte, error) {
	return append([]byte(nil), plaintext...), nil
}

func dpapiUnprotect(ciphertext []byte) ([]byte, error) {
	return append([]byte(nil), ciphertext...), nil
}

func atomicWriteFile(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".tailime-*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		return err
	}
	if err := tmp.Chmod(0600); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	return os.Rename(tmpPath, path)
}
