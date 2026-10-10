use crate::ops;

use hmac::{Hmac, Mac};
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

// 2：签名消息加入 nonce（`timestamp:nonce:body`）。1 及更早的请求一律拒收，
// 应用侧靠 `helper.ping` 的 TOKEN 比对发现不一致并重装服务。
const PROTOCOL_VERSION: u32 = 2;
const TIME_WINDOW_SECS: u64 = 5;
const NONCE_MAX_LEN: usize = 64;

/// 已用 nonce 的缓存上限。窗口淘汰本身就把规模压在「窗口内请求数」上，这里是
/// 防止密钥持有者按请求速率灌爆内存的兜底。
const MAX_REPLAY_ENTRIES: usize = 8192;

type HmacSha256 = Hmac<Sha256>;

static AUTH_KEY: Lazy<Arc<Mutex<Option<Vec<u8>>>>> = Lazy::new(|| Arc::new(Mutex::new(None)));

/// nonce → 该请求的时间戳（秒）。只保留窗口内的条目。
static REPLAY_CACHE: Lazy<Arc<Mutex<HashMap<String, u64>>>> =
    Lazy::new(|| Arc::new(Mutex::new(HashMap::new())));

/// 读取鉴权 key。
///
/// 优先读 `HELPER_AUTH_KEY_FILE` 指向的文件：服务注册表的 `Environment` 值对
/// `BUILTIN\Users` 可读，明文写在那里等于本机任何用户都能拿到 key。文件只保留
/// 路径，key 本体放在只有当前用户与 SYSTEM 能读的位置。`HELPER_AUTH_KEY` 仅作为
/// 旧配置的兜底（文件缺失、不可读或为空时）。
fn read_auth_key() -> Option<String> {
    if let Ok(path) = std::env::var("HELPER_AUTH_KEY_FILE") {
        match std::fs::read_to_string(&path) {
            Ok(content) => {
                let trimmed = content.trim();
                if !trimmed.is_empty() {
                    return Some(trimmed.to_string());
                }
                ops::logs::log_message(format!("Auth key file is empty: {}", path));
            }
            Err(e) => {
                ops::logs::log_message(format!("Failed to read auth key file {}: {}", path, e));
            }
        }
    }

    std::env::var("HELPER_AUTH_KEY").ok()
}

pub fn init_auth_key() {
    let key_hex = match read_auth_key() {
        Some(v) => v,
        None => {
            ops::logs::log_message(
                "Neither HELPER_AUTH_KEY_FILE nor HELPER_AUTH_KEY is set, helper requests will fail auth".to_string(),
            );
            return;
        }
    };

    match hex::decode(&key_hex) {
        Ok(key) => {
            if let Ok(mut auth_key) = AUTH_KEY.lock() {
                *auth_key = Some(key);
                ops::logs::log_message("Auth key initialized".to_string());
            }
        }
        Err(e) => {
            ops::logs::log_message(format!("HELPER_AUTH_KEY is invalid hex: {}", e));
        }
    }

    std::env::remove_var("HELPER_AUTH_KEY");
}

pub async fn handle_payload(payload: &str) -> String {
    match HelperRequest::decode(payload) {
        Ok(request) => handle_request(request).await.encode(),
        Err(e) => {
            HelperResponse::error("", HelperError::new("INVALID_REQUEST", e.to_string())).encode()
        }
    }
}

async fn handle_request(request: HelperRequest) -> HelperResponse {
    if request.version != PROTOCOL_VERSION {
        return HelperResponse::error(
            &request.id,
            HelperError::new("UNSUPPORTED_VERSION", "Unsupported helper protocol version"),
        );
    }

    if !is_valid_nonce(&request.auth.nonce) {
        ops::logs::log_message("Rejected request with malformed nonce".to_string());
        return HelperResponse::error(
            &request.id,
            HelperError::new("UNAUTHORIZED", "Unauthorized helper request"),
        );
    }

    let auth_payload = format!("{}:{}:{}", request.version, request.method, request.body);
    if !verify_request(
        request.auth.timestamp,
        &request.auth.nonce,
        &request.auth.signature,
        &auth_payload,
    ) {
        ops::logs::log_message("Authentication failed".to_string());
        return HelperResponse::error(
            &request.id,
            HelperError::new("UNAUTHORIZED", "Unauthorized helper request"),
        );
    }

    // 只在签名通过之后再登记 nonce：否则未鉴权的连接可以拿垃圾 nonce 灌缓存，
    // 反过来把合法请求挤成「重放」。
    if !claim_nonce(&request.auth.nonce, request.auth.timestamp) {
        ops::logs::log_message("Rejected replayed request".to_string());
        return HelperResponse::error(
            &request.id,
            HelperError::new("UNAUTHORIZED", "Unauthorized helper request"),
        );
    }

    match request.method.as_str() {
        "helper.ping" => HelperResponse::success(&request.id, serde_json::json!(env!("TOKEN"))),
        "helper.logs" => HelperResponse::success(&request.id, serde_json::json!(ops::logs::logs())),
        "helper.stop_service" => {
            ops::logs::log_message(format!(
                "Received helper.stop_service request [{}]",
                request.id
            ));
            std::thread::spawn(|| {
                std::thread::sleep(std::time::Duration::from_millis(100));
                ops::core::stop_core();
                std::process::exit(0);
            });
            HelperResponse::empty_success(&request.id)
        }
        "core.start" => {
            ops::logs::log_message(format!("Received core.start request [{}]", request.id));
            handle_core_start(&request).await
        }
        "core.stop" => result_to_response(&request.id, ops::core::stop_core(), "CORE_STOP_FAILED"),
        "process.set_priority" => handle_set_priority(&request).await,
        _ => HelperResponse::error(
            &request.id,
            HelperError::new(
                "UNKNOWN_METHOD",
                format!("Unknown method: {}", request.method),
            ),
        ),
    }
}

async fn handle_core_start(request: &HelperRequest) -> HelperResponse {
    let params = match serde_json::from_str::<ops::core::StartParams>(&request.body) {
        Ok(params) => params,
        Err(e) => {
            return HelperResponse::error(
                &request.id,
                HelperError::new("INVALID_BODY", e.to_string()),
            )
        }
    };

    let result = tokio::task::spawn_blocking(move || ops::core::start_core(params))
        .await
        .unwrap_or_else(|e| e.to_string());
    result_to_response(&request.id, result, "CORE_START_FAILED")
}

async fn handle_set_priority(request: &HelperRequest) -> HelperResponse {
    let params = match serde_json::from_str::<ops::process::PriorityParams>(&request.body) {
        Ok(params) => params,
        Err(e) => {
            return HelperResponse::error(
                &request.id,
                HelperError::new("INVALID_BODY", e.to_string()),
            )
        }
    };

    let result = tokio::task::spawn_blocking(move || {
        ops::process::set_process_priority(&params.process_name, params.enable)
    })
    .await
    .unwrap_or_else(|e| e.to_string());
    result_to_response(&request.id, result, "PROCESS_PRIORITY_FAILED")
}

fn result_to_response(id: &str, result: String, code: &str) -> HelperResponse {
    if result.is_empty() {
        HelperResponse::empty_success(id)
    } else {
        HelperResponse::error(id, HelperError::new(code, result))
    }
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// nonce 只接受短 hex 串：它必须进签名消息，而缓存又按它建键，所以长度要有上界。
fn is_valid_nonce(nonce: &str) -> bool {
    !nonce.is_empty()
        && nonce.len() <= NONCE_MAX_LEN
        && nonce.bytes().all(|b| b.is_ascii_hexdigit())
}

/// 登记一次 nonce，返回是否为首次使用。
///
/// 与 `verify_request` 的窗口校验用同一个时钟，所以时间戳超窗的条目会在下次调用
/// 时被淘汰——缓存不会无限增长。
fn claim_nonce(nonce: &str, timestamp: u64) -> bool {
    let now = now_secs();
    let mut cache = match REPLAY_CACHE.lock() {
        Ok(cache) => cache,
        Err(_) => return false,
    };

    cache.retain(|_, ts| now.abs_diff(*ts) <= TIME_WINDOW_SECS);
    if cache.contains_key(nonce) {
        return false;
    }
    if cache.len() >= MAX_REPLAY_ENTRIES {
        ops::logs::log_message(format!(
            "Replay cache reached {} entries, clearing",
            MAX_REPLAY_ENTRIES
        ));
        cache.clear();
    }
    cache.insert(nonce.to_string(), timestamp);
    true
}

fn verify_request(timestamp: u64, nonce: &str, signature: &str, body: &str) -> bool {
    let key = match AUTH_KEY.lock() {
        Ok(guard) => match guard.as_ref() {
            Some(k) => k.clone(),
            None => return false,
        },
        Err(_) => return false,
    };

    let now = now_secs();

    if now.abs_diff(timestamp) > TIME_WINDOW_SECS {
        ops::logs::log_message(format!(
            "Request timestamp out of window: {} vs {}",
            timestamp, now
        ));
        return false;
    }

    let message = format!("{}:{}:{}", timestamp, nonce, body);
    let mut mac = match HmacSha256::new_from_slice(&key) {
        Ok(m) => m,
        Err(_) => return false,
    };
    mac.update(message.as_bytes());

    // Constant-time verification: decode the hex signature and let the MAC
    // compare it, avoiding the timing side-channel of `&str` equality.
    match hex::decode(signature) {
        Ok(provided) => mac.verify_slice(&provided).is_ok(),
        Err(_) => false,
    }
}

#[derive(Debug, Deserialize)]
struct HelperRequest {
    version: u32,
    id: String,
    method: String,
    #[serde(default)]
    body: String,
    auth: HelperAuth,
}

#[derive(Debug, Deserialize)]
struct HelperAuth {
    timestamp: u64,
    nonce: String,
    signature: String,
}

impl HelperRequest {
    fn decode(payload: &str) -> serde_json::Result<Self> {
        serde_json::from_str(payload)
    }
}

#[derive(Debug, Serialize)]
struct HelperResponse {
    version: u32,
    id: String,
    ok: bool,
    data: Option<serde_json::Value>,
    error: Option<HelperError>,
}

impl HelperResponse {
    fn success(id: &str, data: serde_json::Value) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            id: id.to_string(),
            ok: true,
            data: Some(data),
            error: None,
        }
    }

    fn empty_success(id: &str) -> Self {
        Self::success(id, serde_json::Value::Null)
    }

    fn error(id: &str, error: HelperError) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            id: id.to_string(),
            ok: false,
            data: None,
            error: Some(error),
        }
    }

    fn encode(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|e| {
            format!(
                r#"{{"version":{},"id":"{}","ok":false,"data":null,"error":{{"code":"ENCODE_ERROR","message":"{}"}}}}"#,
                PROTOCOL_VERSION,
                self.id,
                e
            )
        })
    }
}

#[derive(Debug, Serialize)]
struct HelperError {
    code: String,
    message: String,
}

impl HelperError {
    fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.to_string(),
            message: message.into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        claim_nonce, is_valid_nonce, now_secs, read_auth_key, verify_request, HmacSha256, AUTH_KEY,
        REPLAY_CACHE, TIME_WINDOW_SECS,
    };
    use hmac::Mac;

    /// `AUTH_KEY` / `REPLAY_CACHE` 是进程级静态量，而 cargo 并行跑用例，
    /// 所以凡是要动它们的用例都得先拿这把锁串行化。
    static TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn test_lock() -> std::sync::MutexGuard<'static, ()> {
        TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// 造一个签名，消息格式与 Dart 侧 `generateAuthHeaders` 一致。
    fn sign(timestamp: u64, nonce: &str, body: &str, key: &[u8]) -> String {
        let mut mac = HmacSha256::new_from_slice(key).unwrap();
        mac.update(format!("{}:{}:{}", timestamp, nonce, body).as_bytes());
        hex::encode(mac.finalize().into_bytes())
    }

    #[test]
    fn rejects_stale_tampered_and_replayed_requests() {
        let _guard = test_lock();
        let key = b"0123456789abcdef0123456789abcdef".to_vec();
        *AUTH_KEY.lock().unwrap() = Some(key.clone());
        REPLAY_CACHE.lock().unwrap().clear();

        let body = "2:helper.ping:";
        let now = now_secs();
        let nonce = "00112233445566778899aabbccddeeff";
        let signature = sign(now, nonce, body, &key);

        assert!(verify_request(now, nonce, &signature, body));
        assert!(claim_nonce(nonce, now), "首次使用的 nonce 应当通过");
        assert!(!claim_nonce(nonce, now), "重放的 nonce 应当被拒");

        // 窗口外：即使签名正确也拒收。
        let stale = now - TIME_WINDOW_SECS - 1;
        assert!(!verify_request(
            stale,
            nonce,
            &sign(stale, nonce, body, &key),
            body
        ));

        // 旧格式签名（nonce 未参与）不再被接受。
        let mut legacy_mac = HmacSha256::new_from_slice(&key).unwrap();
        legacy_mac.update(format!("{}:{}", now, body).as_bytes());
        let legacy = hex::encode(legacy_mac.finalize().into_bytes());
        assert!(!verify_request(now, nonce, &legacy, body));

        // 改过的 nonce 会让签名失配。
        assert!(!verify_request(
            now,
            "ffeeddccbbaa99887766554433221100",
            &signature,
            body
        ));

        // 另一个 nonce 正常通过，且与上一个互不影响。
        let nonce2 = "ffeeddccbbaa99887766554433221100";
        assert!(verify_request(
            now,
            nonce2,
            &sign(now, nonce2, body, &key),
            body
        ));
        assert!(claim_nonce(nonce2, now));
    }

    #[test]
    fn replay_cache_drops_entries_outside_the_window() {
        let _guard = test_lock();
        REPLAY_CACHE.lock().unwrap().clear();
        let now = now_secs();
        let stale = now - TIME_WINDOW_SECS - 1;

        assert!(claim_nonce("aa", stale));
        // 下一次调用会淘汰窗口外的旧条目，所以同一个 nonce 又能用。
        assert!(claim_nonce("bb", now));
        assert!(claim_nonce("aa", now));
    }

    #[test]
    fn nonce_must_be_short_hex() {
        assert!(is_valid_nonce("00112233445566778899aabbccddeeff"));
        assert!(is_valid_nonce("a"));
        assert!(!is_valid_nonce(""));
        assert!(!is_valid_nonce("not-hex"));
        assert!(!is_valid_nonce(&"a".repeat(65)));
    }

    /// 与 Dart 侧 `test/common/helper_auth_test.dart` 用同一个固定向量，
    /// 两侧消息格式一旦漂移，这里会先红。
    #[test]
    fn signature_matches_the_shared_fixed_vector() {
        let key = hex::decode("0123456789abcdef0123456789abcdef").unwrap();
        assert_eq!(
            sign(
                1_700_000_000,
                "00112233445566778899aabbccddeeff",
                "2:helper.ping:",
                &key
            ),
            "f280c7b7888c7455b6a15f6733be2ce25baa45a901c17686769fa73738428f3e"
        );
    }

    #[test]
    fn reads_the_key_file_and_falls_back_to_the_env() {
        let previous_file = std::env::var("HELPER_AUTH_KEY_FILE").ok();
        let previous_env = std::env::var("HELPER_AUTH_KEY").ok();

        let dir = std::env::temp_dir().join(format!("bettbox_helper_auth_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let key_path = dir.join("helper_auth_service.key");
        std::fs::write(&key_path, "  aabbcc  \n").unwrap();

        std::env::set_var("HELPER_AUTH_KEY_FILE", key_path.to_str().unwrap());
        std::env::set_var("HELPER_AUTH_KEY", "deadbeef");
        assert_eq!(read_auth_key().as_deref(), Some("aabbcc"));

        // 文件不可读时退回旧的环境变量，避免升级后 helper 直接失去鉴权能力。
        std::fs::remove_file(&key_path).unwrap();
        assert_eq!(read_auth_key().as_deref(), Some("deadbeef"));

        std::env::remove_var("HELPER_AUTH_KEY_FILE");
        assert_eq!(read_auth_key().as_deref(), Some("deadbeef"));

        std::env::remove_var("HELPER_AUTH_KEY");
        assert_eq!(read_auth_key(), None);

        match previous_file {
            Some(value) => std::env::set_var("HELPER_AUTH_KEY_FILE", value),
            None => std::env::remove_var("HELPER_AUTH_KEY_FILE"),
        }
        match previous_env {
            Some(value) => std::env::set_var("HELPER_AUTH_KEY", value),
            None => std::env::remove_var("HELPER_AUTH_KEY"),
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
