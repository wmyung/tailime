//go:build !windows

package main

import "fmt"

func main() {
	fmt.Println("TailIME Windows agent is built for Windows (GOOS=windows).")
}
