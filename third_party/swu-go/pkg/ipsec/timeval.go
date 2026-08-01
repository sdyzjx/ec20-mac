package ipsec

import "syscall"

func durationToTimeval(sec int64, usec int64) syscall.Timeval {
	return syscall.NsecToTimeval(sec*1_000_000_000 + usec*1_000)
}
