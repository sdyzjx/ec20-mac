package modem

import (
	"errors"
	"strings"
	"sync"
	"time"

	"go.bug.st/serial"
)

// imeiCacheItem 存储 IMEI 缓存条目及对应的获取时间戳
type imeiCacheItem struct {
	IMEI string
	TS   time.Time
}

type imeiCacheKey struct {
	attachmentKey string
	atPort        string
}

const legacyIMEICacheAttachment = "legacy-port-only"

// imeiCache 提供线程安全的内存 IMEI 映射缓存，避免频繁通过串口发起硬件查询
var imeiCache struct {
	mu sync.RWMutex
	m  map[imeiCacheKey]imeiCacheItem
}

// imeiProbeMissMu 串行化所有缓存未命中的实际串口探测。macOS 的 cooperative
// PTY 不提供内核级独占；即使 attachment 不同，也不能让冷启动、重扫和 API
// 请求同时打开串口并竞争响应。取得锁后必须再次检查缓存，以合并同一 attachment
// 的并发探测。
var imeiProbeMissMu sync.Mutex

// probeIMEIUncachedFn 是缓存 miss 后唯一的底层探测入口，测试可替换它而无需打开串口。
var probeIMEIUncachedFn = ProbeIMEI

// ProbeIMEICached 在 10 分钟缓存有效期内优先从内存缓存中获取指定 AT 串口的 IMEI；若未命中或过期，则调用底层串口方法探测
func ProbeIMEICached(atPort string, timeout time.Duration) (string, error) {
	return probeIMEICached(legacyIMEICacheAttachment, atPort, timeout)
}

// ProbeIMEICachedForAttachment 按 attachment 与当前 AT 串口共同缓存 IMEI。
// attachmentKey 必须来自当前硬件快照且非空，避免 PTY 路径被新设备复用后返回旧 IMEI。
func ProbeIMEICachedForAttachment(attachmentKey, atPort string, timeout time.Duration) (string, error) {
	attachmentKey = strings.TrimSpace(attachmentKey)
	if attachmentKey == "" {
		return "", errors.New("empty attachment key")
	}
	return probeIMEICached(attachmentKey, atPort, timeout)
}

func probeIMEICached(attachmentKey, atPort string, timeout time.Duration) (string, error) {
	attachmentKey = strings.TrimSpace(attachmentKey)
	atPort = strings.TrimSpace(atPort)
	if attachmentKey == "" {
		return "", errors.New("empty attachment key")
	}
	if atPort == "" {
		return "", errors.New("empty at port")
	}
	key := imeiCacheKey{attachmentKey: attachmentKey, atPort: atPort}

	if imei, ok := cachedIMEI(key); ok {
		return imei, nil
	}

	imeiProbeMissMu.Lock()
	defer imeiProbeMissMu.Unlock()

	// 另一个等待同一全局 miss 锁的调用可能已经完成探测并写入缓存。
	if imei, ok := cachedIMEI(key); ok {
		return imei, nil
	}

	imei, err := probeIMEIUncachedFn(atPort, timeout)
	if err == nil && imei != "" {
		imeiCache.mu.Lock()
		if imeiCache.m == nil {
			imeiCache.m = make(map[imeiCacheKey]imeiCacheItem)
		}
		imeiCache.m[key] = imeiCacheItem{IMEI: imei, TS: time.Now()}
		imeiCache.mu.Unlock()
	}
	return imei, err
}

func cachedIMEI(key imeiCacheKey) (string, bool) {
	imeiCache.mu.RLock()
	defer imeiCache.mu.RUnlock()
	if imeiCache.m == nil {
		return "", false
	}
	it, ok := imeiCache.m[key]
	if !ok || it.IMEI == "" || time.Since(it.TS) >= 10*time.Minute {
		return "", false
	}
	return it.IMEI, true
}

// ProbeIMEI 通过打开底层 TTY 串口设备并执行 `AT+CGSN` 指令来实时探测模组的 IMEI 串号
func ProbeIMEI(atPort string, timeout time.Duration) (string, error) {
	atPort = strings.TrimSpace(atPort)
	if atPort == "" {
		return "", errors.New("empty at port")
	}
	if timeout <= 0 {
		timeout = 1500 * time.Millisecond
	}

	// 配置标准的 3 线异步串口波特率与帧校验格式
	mode := &serial.Mode{
		BaudRate: 115200,
		DataBits: 8,
		StopBits: serial.OneStopBit,
		Parity:   serial.NoParity,
	}

	p, err := serial.Open(atPort, mode)
	if err != nil {
		return "", err
	}
	defer p.Close()

	_ = p.SetReadTimeout(80 * time.Millisecond)

	deadline := time.Now().Add(timeout)
	buf := make([]byte, 1024)
	var acc strings.Builder

	write := func(s string) {
		_, _ = p.Write([]byte(s))
	}

	// 写入 AT 测试命令与查询 IMEI 的 AT+CGSN 命令
	write("AT\r\n")
	time.Sleep(40 * time.Millisecond)
	write("AT+CGSN\r\n")

	// 在指定的截止时间内轮询并解析串口输出内容
	for time.Now().Before(deadline) {
		n, rerr := p.Read(buf)
		if n > 0 {
			acc.Write(buf[:n])
			if imei := parseIMEI(acc.String()); imei != "" {
				return imei, nil
			}
		}
		if rerr != nil {
			if strings.Contains(strings.ToLower(rerr.Error()), "timeout") {
				continue
			}
		}
	}

	// 最终尝试解析一次累积的串口缓冲区
	if imei := parseIMEI(acc.String()); imei != "" {
		return imei, nil
	}
	return "", errors.New("imei probe timeout")
}
