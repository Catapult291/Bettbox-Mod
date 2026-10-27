package main

import (
	"encoding/json"
	"fmt"
	"testing"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
)

// 对照基线：Proxy.MarshalJSON 全量 vs marshalProxiesIPC 瘦身。
// 数据形态与 adapter.MarshalJSON 的 Full 基准一致（叶子 + history + extra），
// 用于量化 IPC 出口瘦身收益。运行：
//
//	CGO_ENABLED=0 go test -tags=with_gvisor -bench=BenchmarkIPCProxies -benchtime=2s -run=^$ .
func benchIPCProxies(b *testing.B, n int) {
	proxies := make(map[string]C.Proxy, n)
	for i := 0; i < n; i++ {
		name := fmt.Sprintf("node-%04d", i)
		proxies[name] = adapter.NewProxy(outbound.NewBase(outbound.BaseOption{
			Name: name,
			Type: C.Shadowsocks,
			UDP:  true,
		}))
	}

	// 先量 payload，不计入 b.N。
	var fullBytes, leanBytes int
	for _, p := range proxies {
		data, _ := p.MarshalJSON()
		fullBytes += len(data)
	}
	lean, err := marshalProxiesIPC(proxies)
	if err != nil {
		b.Fatalf("marshalProxiesIPC: %v", err)
	}
	leanData, _ := json.Marshal(lean)
	leanBytes = len(leanData)
	b.ReportMetric(float64(fullBytes), "full_bytes")
	b.ReportMetric(float64(leanBytes), "lean_bytes")
	b.ReportMetric(float64(fullBytes)/float64(leanBytes), "bytes_ratio")

	b.Run("full", func(b *testing.B) {
		b.ReportAllocs()
		for i := 0; i < b.N; i++ {
			_, _ = json.Marshal(proxies)
		}
	})
	b.Run("lean", func(b *testing.B) {
		b.ReportAllocs()
		for i := 0; i < b.N; i++ {
			out, err := marshalProxiesIPC(proxies)
			if err != nil {
				b.Fatal(err)
			}
			_, _ = json.Marshal(out)
		}
	})
}

func BenchmarkIPCProxies_100(b *testing.B)  { benchIPCProxies(b, 100) }
func BenchmarkIPCProxies_500(b *testing.B)  { benchIPCProxies(b, 500) }
func BenchmarkIPCProxies_1000(b *testing.B) { benchIPCProxies(b, 1000) }
