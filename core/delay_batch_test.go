package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/constant"
)

// fakeDelayProxy 只需实现 URLTest：constant.Proxy 的其余方法由内嵌接口
// 提供（调用即 panic），本组测试不会走到。
type fakeDelayProxy struct {
	constant.Proxy
	delay    uint16
	err      error
	hold     time.Duration
	inFlight *int32
	peak     *int32
}

func (f *fakeDelayProxy) URLTest(_ context.Context, _ string, _ utils.IntRanges[uint16]) (uint16, error) {
	if f.inFlight != nil {
		n := atomic.AddInt32(f.inFlight, 1)
		for {
			old := atomic.LoadInt32(f.peak)
			if n <= old || atomic.CompareAndSwapInt32(f.peak, old, n) {
				break
			}
		}
		defer atomic.AddInt32(f.inFlight, -1)
	}
	if f.hold > 0 {
		time.Sleep(f.hold)
	}
	return f.delay, f.err
}

func fakeLookup(proxies map[string]constant.Proxy) delayTestProxyLookup {
	return func(name string) constant.Proxy {
		return proxies[name]
	}
}

func TestRunDelayTestBatch_KeepsOrderAndShapesResults(t *testing.T) {
	ok := &fakeDelayProxy{delay: 120}
	failing := &fakeDelayProxy{err: errors.New("dial failed")}
	zero := &fakeDelayProxy{delay: 0}
	lookup := fakeLookup(map[string]constant.Proxy{
		"ok":      ok,
		"failing": failing,
		"zero":    zero,
	})

	targets := []TestDelayTargetParams{
		{ProxyName: "ok", TestUrl: "https://cp.cloudflare.com/generate_204"},
		{ProxyName: "missing", TestUrl: "https://cp.cloudflare.com/generate_204"},
		{ProxyName: "failing", TestUrl: "https://cp.cloudflare.com/generate_204"},
		{ProxyName: "zero", TestUrl: ""},
	}

	delays := runDelayTestBatch(lookup, targets, 1000, nil)
	if len(delays) != len(targets) {
		t.Fatalf("want %d results, got %d", len(targets), len(delays))
	}

	want := []Delay{
		{Name: "ok", Url: "https://cp.cloudflare.com/generate_204", Value: 120},
		// 找不到节点时与改前单节点应答一致：不带 url，值为 -1。
		{Name: "missing", Url: "", Value: -1},
		{Name: "failing", Url: "https://cp.cloudflare.com/generate_204", Value: -1},
		// 空 test-url 回落内核默认测试地址。
		{Name: "zero", Url: constant.DefaultTestURL, Value: -1},
	}
	for i := range want {
		if delays[i] != want[i] {
			t.Fatalf("result[%d] = %+v, want %+v", i, delays[i], want[i])
		}
	}

	raw, err := json.Marshal(delays)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	var decoded []map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("json.Unmarshal: %v", err)
	}
	if len(decoded) != 4 {
		t.Fatalf("want 4 objects, got %d", len(decoded))
	}
	// Dart 侧 Delay.fromJson 依赖 name/url/value 三个键始终存在。
	for _, key := range []string{"name", "url", "value"} {
		if _, ok := decoded[0][key]; !ok {
			t.Fatalf("missing key %q in %v", key, decoded[0])
		}
	}
	if _, ok := decoded[0]["value"].(float64); !ok {
		t.Fatalf("value is not a number: %T", decoded[0]["value"])
	}
}

func TestRunDelayTestBatch_EmptyReturnsEmptySlice(t *testing.T) {
	delays := runDelayTestBatch(fakeLookup(nil), nil, 1000, nil)
	if len(delays) != 0 {
		t.Fatalf("want empty, got %d", len(delays))
	}
	raw, err := json.Marshal(delays)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	if string(raw) != "[]" {
		t.Fatalf("want [], got %s", raw)
	}
}

func TestRunDelayTestBatch_CapsConcurrency(t *testing.T) {
	var inFlight, peak int32
	proxy := &fakeDelayProxy{delay: 10, hold: 20 * time.Millisecond, inFlight: &inFlight, peak: &peak}
	lookup := fakeLookup(map[string]constant.Proxy{
		"p": proxy,
	})

	const n = delayTestBatchConcurrency*2 + 20
	targets := make([]TestDelayTargetParams, n)
	for i := range targets {
		targets[i] = TestDelayTargetParams{ProxyName: "p", TestUrl: "https://example.com/generate_204"}
	}

	delays := runDelayTestBatch(lookup, targets, 5000, nil)
	if len(delays) != n {
		t.Fatalf("want %d results, got %d", n, len(delays))
	}
	if got := atomic.LoadInt32(&peak); got > delayTestBatchConcurrency {
		t.Fatalf("peak concurrency %d exceeds cap %d", got, delayTestBatchConcurrency)
	} else if got < 2 {
		t.Fatalf("peak concurrency %d: batch did not run concurrently", got)
	}
}

func TestHandleAsyncTestDelayBatch_InvalidParamsReturnsEmpty(t *testing.T) {
	var got string
	called := false
	handleAsyncTestDelayBatch("not json", func(value string) {
		called = true
		got = value
	})
	if !called {
		t.Fatal("callback not called")
	}
	if got != "" {
		t.Fatalf("want empty string, got %q", got)
	}

	called = false
	handleAsyncTestDelayBatch(`{"proxies":[]}`, func(value string) {
		called = true
		got = value
	})
	if !called || got != "[]" {
		t.Fatalf("want [], got %q (called=%v)", got, called)
	}
}

func TestRunDelayTest_MissingProxyMatchesLegacyShape(t *testing.T) {
	delay := runDelayTest(fakeLookup(nil), "nope", "https://example.com/generate_204", 100, nil)
	want := Delay{Name: "nope", Value: -1}
	if delay != want {
		t.Fatalf("got %+v, want %+v", delay, want)
	}

	raw, err := json.Marshal(delay)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	// 与改前 handleAsyncTestDelay 的应答逐字节一致。
	if got, want := string(raw), fmt.Sprintf(`{"url":"","name":%q,"value":-1}`, "nope"); got != want {
		t.Fatalf("got %s, want %s", got, want)
	}
}
