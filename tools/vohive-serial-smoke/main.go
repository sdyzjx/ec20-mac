package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"go.bug.st/serial"
)

const (
	ptyPrefix          = "/dev/ttys"
	readTimeout        = 75 * time.Millisecond
	transactionTimeout = 3 * time.Second
	maximumResponse    = 64 * 1024
)

var readOnlyCommands = map[string]struct{}{
	"AT":               {},
	"ATI":              {},
	"AT+GMR":           {},
	`AT+QCFG="usbnet"`: {},
}

type terminalState uint8

const (
	terminalPending terminalState = iota
	terminalOK
	terminalError
)

func usage(program string) {
	fmt.Fprintf(os.Stderr,
		"usage: %s /dev/ttysNNN [READ_ONLY_AT_COMMAND]\n"+
			"allowed commands: AT, ATI, AT+GMR, AT+QCFG=\"usbnet\"\n",
		program)
}

func validPTYPath(path string) bool {
	if !strings.HasPrefix(path, ptyPrefix) || len(path) == len(ptyPrefix) {
		return false
	}
	suffix := path[len(ptyPrefix):]
	return !strings.ContainsAny(suffix, "/\r\n\x00")
}

func terminalStateForResponse(response []byte) terminalState {
	lineStart := 0
	for index, value := range response {
		if value != '\r' && value != '\n' {
			continue
		}

		line := bytes.Trim(response[lineStart:index], " \t")
		switch {
		case bytes.Equal(line, []byte("OK")):
			return terminalOK
		case bytes.Equal(line, []byte("ERROR")),
			bytes.HasPrefix(line, []byte("+CME ERROR:")),
			bytes.HasPrefix(line, []byte("+CMS ERROR:")):
			return terminalError
		}
		lineStart = index + 1
	}
	return terminalPending
}

func writeAll(port serial.Port, payload []byte) error {
	for len(payload) != 0 {
		written, err := port.Write(payload)
		if written > 0 {
			payload = payload[written:]
		}
		if err != nil {
			return err
		}
		if written == 0 {
			return io.ErrShortWrite
		}
	}
	return nil
}

func run(path, command string) (returnErr error) {
	mode := &serial.Mode{
		BaudRate: 115200,
		DataBits: 8,
		Parity:   serial.NoParity,
		StopBits: serial.OneStopBit,
	}
	port, err := serial.Open(path, mode)
	if err != nil {
		return fmt.Errorf("open PTY: %w", err)
	}
	defer func() {
		if closeErr := port.Close(); closeErr != nil && returnErr == nil {
			returnErr = fmt.Errorf("close PTY: %w", closeErr)
		}
	}()

	if err := port.SetReadTimeout(readTimeout); err != nil {
		return fmt.Errorf("set 75ms read timeout: %w", err)
	}
	if err := port.ResetInputBuffer(); err != nil {
		return fmt.Errorf("reset input buffer: %w", err)
	}

	deadline := time.Now().Add(transactionTimeout)
	if err := writeAll(port, append([]byte(command), '\r')); err != nil {
		return fmt.Errorf("write command: %w", err)
	}

	response := make([]byte, 0, 4096)
	buffer := make([]byte, 4096)
	for time.Now().Before(deadline) {
		count, readErr := port.Read(buffer)
		if count > 0 {
			if count > maximumResponse-len(response) {
				return fmt.Errorf("response exceeds the %d-byte limit", maximumResponse)
			}
			response = append(response, buffer[:count]...)
			switch terminalStateForResponse(response) {
			case terminalOK:
				return nil
			case terminalError:
				return fmt.Errorf("modem returned a terminal error")
			case terminalPending:
			}
		}
		if readErr != nil {
			return fmt.Errorf("read response: %w", readErr)
		}
	}
	return fmt.Errorf("timed out after %s without an independent OK line",
		transactionTimeout)
}

func main() {
	if len(os.Args) < 2 || len(os.Args) > 3 {
		usage(os.Args[0])
		os.Exit(64)
	}

	path := os.Args[1]
	command := "AT"
	if len(os.Args) == 3 {
		command = os.Args[2]
	}
	if !validPTYPath(path) {
		fmt.Fprintln(os.Stderr, "vohive-serial-smoke: refusing non-PTY path")
		os.Exit(64)
	}
	if _, allowed := readOnlyCommands[command]; !allowed {
		fmt.Fprintln(os.Stderr,
			"vohive-serial-smoke: command is not in the read-only allowlist")
		usage(os.Args[0])
		os.Exit(64)
	}

	if err := run(path, command); err != nil {
		fmt.Fprintf(os.Stderr, "vohive-serial-smoke: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("vohive serial smoke: PASS")
}
