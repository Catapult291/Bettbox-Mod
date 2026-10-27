package main

import (
	"bytes"
	"context"
	"core/state"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"runtime"
	"runtime/debug"
	"sort"
	"strconv"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/observable"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/common/yaml"
	"github.com/metacubex/mihomo/component/age"
	"github.com/metacubex/mihomo/component/mmdb"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/component/updater"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/log"
	mihomoNtp "github.com/metacubex/mihomo/ntp/ntp"
	rulesProvider "github.com/metacubex/mihomo/rules/provider"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
	"sync"
)

var (
	isInit            = false
	externalProviders = map[string]cp.Provider{}
	logSubscriber     observable.Subscription[log.Event]
	ageMutex          sync.Mutex
)

func handleInitClash(paramsString string) bool {
	var params = InitParams{}
	err := json.Unmarshal([]byte(paramsString), &params)
	if err != nil {
		return false
	}
	version = params.Version
	if !isInit {
		constant.SetHomeDir(params.HomeDir)
		isInit = true
	}
	return isInit
}

func handleStartListener() bool {
	runLock.Lock()
	defer runLock.Unlock()
	isRunning = true
	updateListeners()
	resolver.ResetConnection()
	// mixed-port 被别的程序占用时 ReCreateMixed 只写日志、不建监听。这里按
	// 配置核对内核是否真的持有该端口——「有东西在听」不等于「我们在听」，
	// 否则上层端口探测会把别人的监听误报成启动成功。失败即回滚并停掉本轮
	// 可能已建起的其他监听，不留半启动态。
	if currentConfig != nil && currentConfig.General != nil && currentConfig.General.MixedPort > 0 {
		if listener.GetPorts().MixedPort != currentConfig.General.MixedPort {
			log.Errorln("[APP] startListener failed: mixed port %d is not held by core", currentConfig.General.MixedPort)
			isRunning = false
			listener.StopListener()
			return false
		}
	}
	return true
}

func handleStopListener() bool {
	runLock.Lock()
	defer runLock.Unlock()
	isRunning = false
	listener.StopListener()
	return true
}

func handleGetIsInit() bool {
	return isInit
}

func handleForceGc(forceFreeOSMemory bool) {
	go func() {
		log.Infoln("[APP] Request force GC, forceFreeOSMemory=%t", forceFreeOSMemory)
		runtime.GC()
		if forceFreeOSMemory {
			debug.FreeOSMemory()
		}
	}()
}

func handleShutdown() bool {
	stopListeners()
	executor.Shutdown()
	runtime.GC()
	debug.FreeOSMemory()
	isInit = false
	return true
}

func handleValidateConfig(params *ValidateConfigParams) string {
	ageMutex.Lock()
	defer ageMutex.Unlock()

	if params.AgeSecretKey != "" {
		age.SetGlobalSecretKeys(params.AgeSecretKey)
		defer age.SetGlobalSecretKeys()
	}

	_, err := config.Parse([]byte(params.Data))
	if err != nil {
		return err.Error()
	}
	return ""
}

func handleDecryptAgeConfig(params *DecryptAgeConfigParams) string {
	ageMutex.Lock()
	defer ageMutex.Unlock()

	decrypted, err := age.DecryptBytes([]byte(params.Data), params.AgeSecretKey)
	if err != nil {
		return ""
	}
	return string(decrypted)
}

func handleGetProxies() map[string]leanProxyIPC {
	runLock.Lock()
	defer runLock.Unlock()
	if !isInit {
		return make(map[string]leanProxyIPC)
	}
	// 瘦身：只回 UI 构组需要的 name/type/now/all/hidden/icon/testUrl，
	// 跳过 Proxy.MarshalJSON 的双重序列化与 history/extra/alive 等字段。
	// 详见 core/proxies_json.go。
	lean, err := marshalProxiesIPC(tunnel.Proxies())
	if err != nil {
		// 分组组字段解析失败时退回空表，不让单个坏分组拖垮整次 IPC。
		return make(map[string]leanProxyIPC)
	}
	return lean
}

func handleChangeProxy(data string, fn func(string string)) {
	if !isInit {
		fn("core not initialized")
		return
	}
	runLock.Lock()
	go func() {
		defer runLock.Unlock()
		var params = &ChangeProxyParams{}
		err := json.Unmarshal([]byte(data), params)
		if err != nil {
			fn(err.Error())
			return
		}
		groupName := *params.GroupName
		proxyName := *params.ProxyName
		group, ok := tunnel.Proxies()[groupName]
		if !ok {
			fn("Not found group")
			return
		}
		adapterProxy := group.(*adapter.Proxy)
		selector, ok := adapterProxy.ProxyAdapter.(outboundgroup.SelectAble)
		if !ok {
			fn("Group is not selectable")
			return
		}
		if proxyName == "" {
			selector.ForceSet(proxyName)
		} else {
			err = selector.Set(proxyName)
		}
		if err != nil {
			fn(err.Error())
			return
		}

		fn("")
		return
	}()
}

// handleGetTraffic 单包返回现速与累计流量。UI 每秒同时要两者，拆成两个
// action 就是每秒两次 IPC 往返，合并后由一次 marshal 一次往返带全。
func handleGetTraffic() string {
	up, down := statistic.DefaultManager.NowTraffic(state.CurrentState.OnlyStatisticsProxy)
	totalUp, totalDown := statistic.DefaultManager.TotalTraffic(state.CurrentState.OnlyStatisticsProxy)
	traffic := map[string]int64{
		"up":        up,
		"down":      down,
		"totalUp":   totalUp,
		"totalDown": totalDown,
	}
	data, err := json.Marshal(traffic)
	if err != nil {
		fmt.Println("Error:", err)
		return ""
	}
	return string(data)
}

func handleGetTotalTraffic() string {
	up, down := statistic.DefaultManager.TotalTraffic(state.CurrentState.OnlyStatisticsProxy)
	traffic := map[string]int64{
		"up":   up,
		"down": down,
	}
	data, err := json.Marshal(traffic)
	if err != nil {
		fmt.Println("Error:", err)
		return ""
	}
	return string(data)
}

func handleResetTraffic() {
	statistic.DefaultManager.ResetStatistic()
}

// delayTestBatchConcurrency 是批量测速在内核侧的并发上限。
//
// 与改前逐节点路径里 mBatch 的 50 保持一致：一次批量请求最多同时发起
// 50 个 URL 测试，不会因为界面把整组节点打包发过来而抬高出站连接数。
const delayTestBatchConcurrency = 50

// delayTestProxyLookup 按名字在内核代理表与各 provider 里找节点。
type delayTestProxyLookup func(name string) constant.Proxy

func lookupDelayTestProxy(name string) constant.Proxy {
	if proxy, exist := tunnel.Proxies()[name]; exist {
		return proxy
	}
	for _, provider := range tunnel.Providers() {
		for _, p := range provider.Proxies() {
			if p.Name() == name {
				return p
			}
		}
	}
	return nil
}

// runDelayTest 对单个节点做一次 URL 测试。所有失败分支都回 -1，
// 应答形态与改前 handleAsyncTestDelay 一致。
func runDelayTest(lookup delayTestProxyLookup, name, testUrl string, timeout int64, expectedStatus utils.IntRanges[uint16]) Delay {
	delayData := Delay{
		Name: name,
	}

	proxy := lookup(name)
	if proxy == nil {
		delayData.Value = -1
		return delayData
	}

	if testUrl == "" {
		testUrl = constant.DefaultTestURL
	}
	delayData.Url = testUrl

	ctx, cancel := context.WithTimeout(context.Background(), time.Millisecond*time.Duration(timeout))
	defer cancel()

	delay, err := proxy.URLTest(ctx, testUrl, expectedStatus)
	if err != nil || delay == 0 {
		delayData.Value = -1
		return delayData
	}

	delayData.Value = int32(delay)
	return delayData
}

func handleAsyncTestDelay(paramsString string, fn func(string)) {
	mBatch.Go(paramsString, func() (bool, error) {
		var params = &TestDelayParams{}
		err := json.Unmarshal([]byte(paramsString), params)
		if err != nil {
			fn("")
			return false, nil
		}

		expectedStatus, err := utils.NewUnsignedRanges[uint16]("")
		if err != nil {
			fn("")
			return false, nil
		}

		delay := runDelayTest(lookupDelayTestProxy, params.ProxyName, params.TestUrl, params.Timeout, expectedStatus)
		data, _ := json.Marshal(delay)
		fn(string(data))
		return false, nil
	})
}

// runDelayTestBatch 并发跑一整批节点，返回顺序与入参一致。
func runDelayTestBatch(lookup delayTestProxyLookup, targets []TestDelayTargetParams, timeout int64, expectedStatus utils.IntRanges[uint16]) []Delay {
	delays := make([]Delay, len(targets))
	sem := make(chan struct{}, delayTestBatchConcurrency)
	var wg sync.WaitGroup
	for i := range targets {
		wg.Add(1)
		sem <- struct{}{}
		go func(i int) {
			defer wg.Done()
			defer func() { <-sem }()
			delays[i] = runDelayTest(lookup, targets[i].ProxyName, targets[i].TestUrl, timeout, expectedStatus)
		}(i)
	}
	wg.Wait()
	return delays
}

// handleAsyncTestDelayBatch 一次 action 测一整批节点。
//
// 界面按批发送（批大小同时受 delayTestBatchConcurrency 约束），内核在
// 本 action 的 goroutine 里跑完再一次性回包：N 个节点从 N 次 IPC 降到
// ceil(N/50) 次。空批次回 `[]`；整批失败回空串，由调用方按超时处理。
func handleAsyncTestDelayBatch(paramsString string, fn func(string)) {
	var params TestDelayBatchParams
	if err := json.Unmarshal([]byte(paramsString), &params); err != nil {
		fn("")
		return
	}

	expectedStatus, err := utils.NewUnsignedRanges[uint16]("")
	if err != nil {
		fn("")
		return
	}

	timeout := params.Timeout
	if timeout <= 0 {
		timeout = 5000
	}

	data, err := json.Marshal(runDelayTestBatch(lookupDelayTestProxy, params.Proxies, timeout, expectedStatus))
	if err != nil {
		fn("")
		return
	}
	fn(string(data))
}

// handleGetConnections 回连接列表的瘦身快照。
//
// 不持有 runLock：连接表的读写由 statistic.Manager 自己保证并发安全，
// 原先每秒一次的整表序列化会和 setupConfig/getProxies 争同一把锁。
func handleGetConnections() string {
	data, err := marshalConnectionsIPC(statistic.DefaultManager.Connections())
	if err != nil {
		fmt.Println("Error:", err)
		return ""
	}
	return string(data)
}

// handleGetConnectionsCount 只回连接数，供首页计数卡片使用：
// 不物化连接表、不序列化。返回十进制字符串，与 getMemory 一致。
func handleGetConnectionsCount() string {
	return strconv.Itoa(statistic.DefaultManager.Count())
}

func handleCloseConnections() bool {
	runLock.Lock()
	defer runLock.Unlock()
	closeConnections()
	return true
}

func closeConnections() {
	// 单条连接关不掉不该中断整轮：以前直接 return false 会让后面的连接
	// 全部漏关，换节点后旧连接继续占着内核内存。
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		_ = c.Close()
		return true
	})
}

func handleResetConnections() bool {
	runLock.Lock()
	defer runLock.Unlock()
	resolver.ResetConnection()
	return true
}

func handleCloseConnection(connectionId string) bool {
	runLock.Lock()
	defer runLock.Unlock()
	c := statistic.DefaultManager.Get(connectionId)
	if c == nil {
		return false
	}
	_ = c.Close()
	return true
}

func handleGetExternalProviders() string {
	runLock.Lock()
	defer runLock.Unlock()
	if !isInit {
		return "[]"
	}
	externalProviders = getExternalProvidersRaw()
	eps := make([]ExternalProvider, 0)
	for _, p := range externalProviders {
		externalProvider, err := toExternalProvider(p)
		if err != nil {
			continue
		}
		eps = append(eps, *externalProvider)
	}
	sort.Sort(ExternalProviders(eps))
	// 瘦身：provider 的 proxies 从全量节点（每个再走一遍 Proxy.MarshalJSON）
	// 换成只回 name+type——构组时只用 name 并入 allProxies，类型供
	// Proxy.fromJson 物化。详见 core/proxies_json.go。
	lean, err := marshalProvidersIPC(eps)
	if err != nil {
		return ""
	}
	data, err := json.Marshal(lean)
	if err != nil {
		return ""
	}
	return string(data)
}

func handleGetExternalProvider(externalProviderName string) string {
	runLock.Lock()
	defer runLock.Unlock()
	externalProvider, exist := externalProviders[externalProviderName]
	if !exist {
		return ""
	}
	e, err := toExternalProvider(externalProvider)
	if err != nil {
		return ""
	}
	data, err := json.Marshal(e)
	if err != nil {
		return ""
	}
	return string(data)
}

func handleUpdateGeoData(geoType string, geoName string, fn func(value string)) {
	go func() {
		path := constant.Path.Resolve(geoName)
		switch geoType {
		case "MMDB":
			err := updater.UpdateMMDBWithPath(path)
			if err != nil {
				fn(err.Error())
				return
			}
		case "ASN":
			err := updater.UpdateASNWithPath(path)
			if err != nil {
				fn(err.Error())
				return
			}
		case "GeoSite":
			err := updater.UpdateGeoSiteWithPath(path)
			if err != nil {
				fn(err.Error())
				return
			}
		}
		fn("")
	}()
}

func handleUpdateExternalProvider(providerName string, fn func(value string)) {
	go func() {
		externalProvider, exist := externalProviders[providerName]
		if !exist {
			fn("external provider is not exist")
			return
		}
		err := externalProvider.Update()
		if err != nil {
			fn(err.Error())
			return
		}
		fn("")
	}()
}

func handleSideLoadExternalProvider(providerName string, data []byte, fn func(value string)) {
	go func() {
		runLock.Lock()
		defer runLock.Unlock()
		externalProvider, exist := externalProviders[providerName]
		if !exist {
			fn("external provider is not exist")
			return
		}
		err := sideUpdateExternalProvider(externalProvider, data)
		if err != nil {
			fn(err.Error())
			return
		}
		fn("")
	}()
}

func handleParseExternalProviderContent(providerName string, fn func(value string)) {
	go func() {
		runLock.Lock()
		p, exist := getExternalProvidersRaw()[providerName]
		rawConfig := currentRawConfig
		runLock.Unlock()

		if !exist {
			fn("external provider does not exist")
			return
		}

		if p.VehicleType() == cp.Inline {
			buf, err := marshalInlineProviderContent(rawConfig, providerName)
			if err != nil {
				fn(err.Error())
				return
			}
			fn(string(buf))
			return
		}

		ep, err := toExternalProvider(p)
		if err != nil || ep.Path == "" {
			fn("provider path is empty")
			return
		}

		buf, err := os.ReadFile(ep.Path)
		if err != nil {
			fn(fmt.Sprintf("read file error: %v", err))
			return
		}

		if rp, ok := p.(cp.RuleProvider); ok {
			var out bytes.Buffer
			if err := rulesProvider.ConvertToMrs(buf, rp.Behavior(), cp.MrsRule, &out); err == nil {
				fn(out.String())
				return
			}
		}

		fn(string(buf))
	}()
}

func marshalInlineProviderContent(rawConfig *config.RawConfig, providerName string) ([]byte, error) {
	if rawConfig == nil {
		return nil, fmt.Errorf("provider content is empty")
	}

	rawProvider, exist := rawConfig.ProxyProvider[providerName]
	if !exist {
		return nil, fmt.Errorf("provider content is empty")
	}
	payload, exist := rawProvider["payload"]
	if !exist {
		return nil, fmt.Errorf("provider content is empty")
	}

	return yaml.Marshal(map[string]any{"proxies": payload})
}

func handleStartLog() {
	if logSubscriber != nil {
		log.UnSubscribe(logSubscriber)
		logSubscriber = nil
	}
	logSubscriber = log.Subscribe()
	go func() {
		for logData := range logSubscriber {
			if logData.LogLevel < log.Level() {
				continue
			}
			message := &Message{
				Type: LogMessage,
				Data: logData,
			}
			sendMessage(*message)
		}
	}()
}

func handleStopLog() {
	if logSubscriber != nil {
		log.UnSubscribe(logSubscriber)
		logSubscriber = nil
	}
}

func handleGetCountryCode(ip string, fn func(value string)) {
	go func() {
		runLock.Lock()
		defer runLock.Unlock()
		codes := mmdb.IPInstance().LookupCode(net.ParseIP(ip))
		if len(codes) == 0 {
			fn("")
			return
		}
		fn(codes[0])
	}()
}

func handleGetMemory(fn func(value string)) {
	go func() {
		fn(strconv.FormatUint(statistic.DefaultManager.Memory(), 10))
	}()
}

func handleGetMode() string {
	if !isInit {
		return ""
	}
	return tunnel.Mode().String()
}

func handleSetState(params string) {
	_ = json.Unmarshal([]byte(params), state.CurrentState)
}

func handleGetConfig(params *GetConfigParams) (*config.RawConfig, error) {
	ageMutex.Lock()
	defer ageMutex.Unlock()

	if params.AgeSecretKey != "" {
		age.SetGlobalSecretKeys(params.AgeSecretKey)
		defer age.SetGlobalSecretKeys()
	}

	bytes, err := readFile(params.Path)
	if err != nil {
		return nil, err
	}
	prof, err := config.UnmarshalRawConfig(bytes)
	if err != nil {
		return nil, err
	}
	return prof, nil
}

func handleFlushFakeIP() bool {
	if !isInit {
		return false
	}
	err := resolver.FlushFakeIP()
	if err != nil {
		log.Errorln("[APP] Flush FakeIP error: %v", err)
		return false
	}
	log.Infoln("[APP] FakeIP pool flushed")
	return true
}

func handleFlushDnsCache() {
	resolver.ClearCache()
	log.Infoln("[APP] DNS cache flushed")
}

func handleCrash() {
	panic("handle invoke crash")
}

func handleUpdateConfig(bytes []byte) string {
	var params = &UpdateParams{}
	err := json.Unmarshal(bytes, params)
	if err != nil {
		return err.Error()
	}
	updateConfig(params)
	return ""
}

func handleSetupConfig(bytes []byte) string {
	var params = defaultSetupParams()
	err := UnmarshalJson(bytes, params)
	if err != nil {
		log.Errorln("unmarshalRawConfig error %v", err)
		_ = setupConfig(defaultSetupParams())
		return err.Error()
	}
	clearSuspendedHealthChecks()
	clearSuspendedWireGuard()
	err = setupConfig(params)
	if err != nil {
		return err.Error()
	}
	return ""
}

func handleSuspend(suspended bool) bool {
	if !isInit {
		return false
	}
	if suspended {
		log.Infoln("[APP] Suspend mode enabled")
		tunnel.OnSuspend()
		pauseHealthChecks()
		pauseWireGuard()

		mihomoNtp.ReCreateNTPService("", 0, "", nil, false)

		statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
			_ = c.Close()
			return true
		})

		runtime.GC()
	} else {
		log.Infoln("[APP] Resume from suspend")
		tunnel.OnRunning()
		resumeHealthChecks()
		resumeWireGuard()

		runLock.Lock()
		cfg := currentConfig
		runLock.Unlock()
		if cfg != nil && cfg.NTP != nil && cfg.NTP.Enable {
			c := cfg.NTP
			mihomoNtp.ReCreateNTPService(
				net.JoinHostPort(c.Server, strconv.Itoa(c.Port)),
				time.Duration(c.Interval),
				c.DialerProxy,
				tunnel.Tunnel,
				c.WriteToSystem,
			)
		}
	}
	return true
}

func init() {
	adapter.UrlTestHook = func(url string, name string, delay uint16) {
		delayData := &Delay{
			Url:  url,
			Name: name,
		}
		if delay == 0 {
			delayData.Value = -1
		} else {
			delayData.Value = int32(delay)
		}
		sendMessage(Message{
			Type: DelayMessage,
			Data: delayData,
		})
	}
	statistic.DefaultRequestNotify = func(c statistic.Tracker) {
		sendMessage(Message{
			Type: RequestMessage,
			Data: c.Info(),
		})
	}
	executor.DefaultProviderLoadedHook = func(providerName string) {
		sendMessage(Message{
			Type: LoadedMessage,
			Data: providerName,
		})
	}
}
