//go:build windows

package storage

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"unsafe"
)

const (
	cryptprotectUIForbidden = 0x01
	movefileReplaceExisting = 0x01
)

var (
	modCrypt32              = syscall.NewLazyDLL("crypt32.dll")
	procCryptProtectData    = modCrypt32.NewProc("CryptProtectData")
	procCryptUnprotectData  = modCrypt32.NewProc("CryptUnprotectData")
	modKernel32Storage      = syscall.NewLazyDLL("kernel32.dll")
	procLocalFree           = modKernel32Storage.NewProc("LocalFree")
	procMoveFileExW         = modKernel32Storage.NewProc("MoveFileExW")
)

type dataBlob struct {
	cbData uint32
	pbData *byte
}

func dpapiProtect(plaintext []byte) ([]byte, error) {
	if len(plaintext) == 0 {
		return nil, errors.New("empty plaintext")
	}
	in := dataBlob{cbData: uint32(len(plaintext)), pbData: &plaintext[0]}
	var out dataBlob
	desc, _ := syscall.UTF16PtrFromString("TailIME Curve25519 Identity")
	r1, _, err := procCryptProtectData.Call(
		uintptr(unsafe.Pointer(&in)),
		uintptr(unsafe.Pointer(desc)),
		0,
		0,
		0,
		uintptr(cryptprotectUIForbidden),
		uintptr(unsafe.Pointer(&out)),
	)
	if r1 == 0 {
		return nil, err
	}
	defer procLocalFree.Call(uintptr(unsafe.Pointer(out.pbData)))
	outSlice := unsafe.Slice(out.pbData, out.cbData)
	res := make([]byte, out.cbData)
	copy(res, outSlice)
	clear(outSlice)
	return res, nil
}

func dpapiUnprotect(ciphertext []byte) ([]byte, error) {
	if len(ciphertext) == 0 {
		return nil, errors.New("empty ciphertext")
	}
	in := dataBlob{cbData: uint32(len(ciphertext)), pbData: &ciphertext[0]}
	var out dataBlob
	r1, _, err := procCryptUnprotectData.Call(
		uintptr(unsafe.Pointer(&in)),
		0,
		0,
		0,
		0,
		uintptr(cryptprotectUIForbidden),
		uintptr(unsafe.Pointer(&out)),
	)
	if r1 == 0 {
		return nil, err
	}
	defer procLocalFree.Call(uintptr(unsafe.Pointer(out.pbData)))
	outSlice := unsafe.Slice(out.pbData, out.cbData)
	res := make([]byte, out.cbData)
	copy(res, outSlice)
	clear(outSlice)
	return res, nil
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
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	srcPtr, err := syscall.UTF16PtrFromString(tmpPath)
	if err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	dstPtr, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	r1, _, callErr := procMoveFileExW.Call(
		uintptr(unsafe.Pointer(srcPtr)),
		uintptr(unsafe.Pointer(dstPtr)),
		uintptr(movefileReplaceExisting),
	)
	if r1 == 0 {
		_ = os.Remove(tmpPath)
		return callErr
	}
	return nil
}
