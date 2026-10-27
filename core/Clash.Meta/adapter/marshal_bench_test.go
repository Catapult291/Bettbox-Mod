package adapter

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/metacubex/mihomo/common/atomic"
	"github.com/metacubex/mihomo/common/queue"
	C "github.com/metacubex/mihomo/constant"
)

// mockAdapter 是只回 type 的最小 ProxyAdapter，用于基准里模拟叶子节点。
// 真实叶子（Base.MarshalJSON）是 {type, id}，history/extra 由 Proxy.MarshalJSON 注入。
type mockAdapter struct {
	name string
	tp   C.AdapterType
}

func (m *mockAdapter) Name() string                   { return m.name }
func (m *mockAdapter) Type() C.AdapterType            { return m.tp }
func (m *mockAdapter) Addr() string                   { return "" }
func (m *mockAdapter) SupportUDP() bool               { return true }
func (m *mockAdapter) SupportUOT() bool               { return false }
func (m *mockAdapter) IsL3Protocol(*C.Metadata) bool  { return false }
func (m *mockAdapter) Close() error                   { return nil }
func (m *mockAdapter) Unwrap(*C.Metadata, bool) C.Proxy { return nil }
func (m *mockAdapter) ProxyInfo() C.ProxyInfo         { return C.ProxyInfo{} }

func (m *mockAdapter) MarshalJSON() ([]byte, error) {
	return json.Marshal(map[string]string{"type": m.tp.String()})
}

func (m *mockAdapter) DialContext(ctx context.Context, metadata *C.Metadata) (C.Conn, error) {
	return nil, C.ErrNotSupport
}

func (m *mockAdapter) ListenPacketContext(ctx context.Context, metadata *C.Metadata) (C.PacketConn, error) {
	return nil, C.ErrNotSupport
}

// 用 NewProxy 包一层，注入与真实节点等量的 delay history + extra。
func newBenchProxy(name string, histories int) *Proxy {
	p := NewProxy(&mockAdapter{name: name, tp: C.Shadowsocks})
	for i := 0; i < histories; i++ {
		p.history.Put(C.DelayHistory{
			Time:  time.Now().Add(-time.Duration(i) * time.Minute),
			Delay: uint16(100 + i),
		})
	}
	for _, url := range []string{
		"http://www.gstatic.com/generate_204",
		"https://cp.cloudflare.com/generate_204",
	} {
		hq := queue.New[C.DelayHistory](defaultHistoriesNum)
		for j := 0; j < 5; j++ {
			hq.Put(C.DelayHistory{Time: time.Now(), Delay: uint16(50 + j)})
		}
		p.extra.Store(url, &internalProxyState{
			alive:   atomic.NewBool(true),
			history: hq,
		})
	}
	return p
}

// --- 基线：Proxy.MarshalJSON 全量输出 ---

func BenchmarkProxyMarshalJSON_Full_100(b *testing.B) {
	benchProxyMarshal(b, 100, 10)
}

func BenchmarkProxyMarshalJSON_Full_500(b *testing.B) {
	benchProxyMarshal(b, 500, 10)
}

func BenchmarkProxyMarshalJSON_Full_1000(b *testing.B) {
	benchProxyMarshal(b, 1000, 10)
}

func benchProxyMarshal(b *testing.B, n, histories int) {
	proxies := make([]*Proxy, n)
	for i := 0; i < n; i++ {
		proxies[i] = newBenchProxy(fmt.Sprintf("node-%04d", i), histories)
	}
	m := make(map[string]C.Proxy, n)
	for _, p := range proxies {
		m[p.Name()] = p
	}

	var total int
	for _, p := range proxies {
		data, _ := p.MarshalJSON()
		total += len(data)
	}
	b.ReportMetric(float64(total)/float64(n), "bytes/node")
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = json.Marshal(m)
	}
}

// --- 基线：单节点 MarshalJSON 延迟（无 map 包装） ---

func BenchmarkProxyMarshalJSON_Single(b *testing.B) {
	p := newBenchProxy("node-0001", 10)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = p.MarshalJSON()
	}
}

// --- 对照：只出 name/type（改后目标形态的下界参考） ---

func BenchmarkProxyMarshalJSON_Lean_100(b *testing.B) {
	n := 100
	m := make(map[string]C.Proxy, n)
	for i := 0; i < n; i++ {
		name := fmt.Sprintf("node-%04d", i)
		m[name] = newBenchProxy(name, 10)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		out := make(map[string]map[string]string, len(m))
		for name, p := range m {
			out[name] = map[string]string{"name": name, "type": p.Type().String()}
		}
		_, _ = json.Marshal(out)
	}
}
