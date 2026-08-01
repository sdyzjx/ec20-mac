package modem

import (
	"errors"
	"strings"
	"time"

	"go.bug.st/serial"
)

// SerialAT 是一个轻量级的串口包装器，用于在不实例化整个 Manager 的情况下执行简单的 AT 命令
type SerialAT struct {
	port  serial.Port
	lease *serialPortLease
}

// NewSerialAT 打开串口并返回 SerialAT 实例
func NewSerialAT(portName string, baudRate int, dataBits int, stopBits int, parity string) (*SerialAT, error) {
	lease, err := acquireSerialPortLease(portName, "serial-at")
	if err != nil {
		return nil, err
	}

	mode := &serial.Mode{
		BaudRate: baudRate,
		DataBits: dataBits,
	}

	switch stopBits {
	case 1:
		mode.StopBits = serial.OneStopBit
	case 2:
		mode.StopBits = serial.TwoStopBits
	default:
		mode.StopBits = serial.OneStopBit
	}

	switch strings.ToUpper(parity) {
	case "N":
		mode.Parity = serial.NoParity
	case "O":
		mode.Parity = serial.OddParity
	case "E":
		mode.Parity = serial.EvenParity
	default:
		mode.Parity = serial.NoParity
	}

	port, err := serial.Open(portName, mode)
	if err != nil {
		lease.Release()
		return nil, err
	}

	// 设置默认超时
	if err := port.SetReadTimeout(time.Second); err != nil {
		port.Close()
		lease.Release()
		return nil, err
	}

	return &SerialAT{port: port, lease: lease}, nil
}

// Close 关闭串口
func (s *SerialAT) Close() error {
	if s == nil {
		return nil
	}
	var err error
	if s.port != nil {
		err = s.port.Close()
		s.port = nil
	}
	if s.lease != nil {
		s.lease.Release()
		s.lease = nil
	}
	return err
}

// Execute 发送 AT 命令并等待响应
func (s *SerialAT) Execute(cmd string, timeout time.Duration) (string, error) {
	if timeout <= 0 {
		timeout = 2 * time.Second
	}

	// 临时调整超时
	if err := s.port.SetReadTimeout(100 * time.Millisecond); err != nil {
		return "", err
	}

	// 清空缓冲区
	buf := make([]byte, 1024)
	for {
		n, _ := s.port.Read(buf)
		if n == 0 {
			break
		}
	}

	if err := s.port.SetReadTimeout(200 * time.Millisecond); err != nil {
		return "", err
	}

	if !strings.HasSuffix(cmd, "\r\n") {
		cmd += "\r\n"
	}

	if _, err := s.port.Write([]byte(cmd)); err != nil {
		return "", err
	}

	deadline := time.Now().Add(timeout)
	var response strings.Builder

	for time.Now().Before(deadline) {
		n, err := s.port.Read(buf)
		if n > 0 {
			response.Write(buf[:n])
			str := response.String()
			if strings.Contains(str, "OK\r\n") || strings.Contains(str, "ERROR\r\n") {
				return str, nil
			}
		}
		if err != nil {
			// ignore read errors (timeouts)
			continue
		}
	}

	return response.String(), errors.New("timeout")
}
