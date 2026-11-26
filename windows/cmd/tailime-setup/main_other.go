//go:build !windows

package main

import "fmt"

func main() {
	fmt.Println("TailIME Windows setup is built for Windows (GOOS=windows -tags embedpayload).")
}
