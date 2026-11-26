//go:build windows && embedpayload

package main

import _ "embed"

//go:embed payload/TailIME.exe
var embeddedAppExe []byte

//go:embed payload/tailime-ctl.exe
var embeddedCtlExe []byte

//go:embed payload/README.ko.md
var embeddedReadmeKO []byte

//go:embed payload/README.md
var embeddedReadmeEN []byte

//go:embed payload/LICENSE
var embeddedLicense []byte
