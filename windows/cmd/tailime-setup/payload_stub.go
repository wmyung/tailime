//go:build !windows || !embedpayload

package main

var (
	embeddedAppExe   []byte
	embeddedCtlExe   []byte
	embeddedReadmeKO []byte
	embeddedReadmeEN []byte
	embeddedLicense  []byte
)
