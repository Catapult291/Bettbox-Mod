pub mod named_pipe {
    use tokio::net::windows::named_pipe::{PipeMode, ServerOptions};

    use crate::ipc::frame::{read_frame, write_frame};
    use crate::rpc;

    pub async fn run(pipe_name: &str) -> anyhow::Result<()> {
        let pipe_security = PipeSecurityAttributes::new()?;
        let mut first_instance = true;

        loop {
            let mut pipe = match ServerOptions::new()
                .first_pipe_instance(first_instance)
                .pipe_mode(PipeMode::Byte)
                .reject_remote_clients(true)
                .create_with_security_attributes(pipe_name, &pipe_security)
            {
                Ok(pipe) => pipe,
                Err(e) => {
                    // The first instance must be created with first_pipe_instance(true)
                    // to guarantee no other process squatted the pipe name; if that
                    // fails, abort instead of weakening the guarantee. Later failures
                    // are transient, so log and retry rather than stop the service.
                    if first_instance {
                        return Err(e.into());
                    }
                    crate::ops::logs::log_message(format!("Failed to create pipe instance: {}", e));
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                    continue;
                }
            };
            first_instance = false;

            if let Err(e) = pipe.connect().await {
                crate::ops::logs::log_message(format!("IPC connect error: {}", e));
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                continue;
            }

            tokio::spawn(async move {
                if let Err(e) = handle_connection(&mut pipe).await {
                    crate::ops::logs::log_message(format!("IPC connection error: {}", e));
                }
            });
        }
    }

    async fn handle_connection(
        pipe: &mut tokio::net::windows::named_pipe::NamedPipeServer,
    ) -> anyhow::Result<()> {
        if let Some(request) = read_frame(pipe).await? {
            let response = rpc::handle_payload(&request).await;
            write_frame(pipe, &response).await?;
        }
        Ok(())
    }

    /// 旧 ACL：本机所有已认证/交互用户都可连管道。只在拿不到客户端 SID 时兜底；
    /// 鉴权 key 已不再写进对 `BUILTIN\Users` 可读的服务注册表，未认证连接也做不了事。
    const LEGACY_SDDL: &str = "D:P(A;;GRGW;;;SY)(A;;GRGW;;;BA)(A;;GRGW;;;AU)(A;;GRGW;;;IU)";

    /// 管道 ACL：SYSTEM + Administrators + 应用当前用户。
    ///
    /// helper 以 SYSTEM 身份跑在 Session 0，拿不到调用方的登录会话，所以由应用在
    /// 服务 Environment 里用 `HELPER_ALLOWED_SID` 告知自己的用户 SID。
    fn pipe_sddl() -> String {
        match std::env::var("HELPER_ALLOWED_SID") {
            Ok(sid) if is_valid_sid(&sid) => {
                format!("D:P(A;;GRGW;;;SY)(A;;GRGW;;;BA)(A;;GRGW;;;{})", sid)
            }
            Ok(sid) => {
                crate::ops::logs::log_message(format!(
                    "Ignoring invalid HELPER_ALLOWED_SID '{}', falling back to legacy pipe ACL",
                    sid
                ));
                LEGACY_SDDL.to_string()
            }
            Err(_) => {
                crate::ops::logs::log_message(
                    "HELPER_ALLOWED_SID not set, falling back to legacy pipe ACL".to_string(),
                );
                LEGACY_SDDL.to_string()
            }
        }
    }

    /// 只接受 `S-1-...` 形式的 SID：非法 SID 会让 SDDL 转换失败，管道建不起来，
    /// 整个 helper 随之不可用，所以这里必须严格。
    fn is_valid_sid(sid: &str) -> bool {
        if sid.len() > 184 || !sid.starts_with("S-") {
            return false;
        }
        let mut parts = sid.split('-');
        if parts.next() != Some("S") {
            return false;
        }
        let rest: Vec<&str> = parts.collect();
        rest.len() >= 2
            && rest
                .iter()
                .all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()))
    }

    struct PipeSecurityAttributes {
        attributes: windows::Win32::Security::SECURITY_ATTRIBUTES,
        security_descriptor: windows::Win32::Security::PSECURITY_DESCRIPTOR,
    }

    impl PipeSecurityAttributes {
        fn new() -> anyhow::Result<Self> {
            use windows::core::PCWSTR;
            use windows::Win32::Security::Authorization::ConvertStringSecurityDescriptorToSecurityDescriptorW;
            use windows::Win32::Security::{PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES};

            let sddl: Vec<u16> = pipe_sddl()
                .encode_utf16()
                .chain(std::iter::once(0))
                .collect();
            let mut security_descriptor = PSECURITY_DESCRIPTOR::default();
            unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    PCWSTR(sddl.as_ptr()),
                    1,
                    &mut security_descriptor,
                    None,
                )?;
            }

            Ok(Self {
                attributes: SECURITY_ATTRIBUTES {
                    nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
                    lpSecurityDescriptor: security_descriptor.0,
                    bInheritHandle: windows::Win32::Foundation::BOOL(0),
                },
                security_descriptor,
            })
        }

        fn as_mut_ptr(&self) -> *mut std::ffi::c_void {
            (&self.attributes as *const windows::Win32::Security::SECURITY_ATTRIBUTES)
                as *mut std::ffi::c_void
        }
    }

    impl Drop for PipeSecurityAttributes {
        fn drop(&mut self) {
            unsafe {
                let _ = windows::Win32::Foundation::LocalFree(windows::Win32::Foundation::HLOCAL(
                    self.security_descriptor.0,
                ));
            }
        }
    }

    trait ServerOptionsSecurityExt {
        fn create_with_security_attributes(
            &self,
            pipe_name: &str,
            security_attributes: &PipeSecurityAttributes,
        ) -> std::io::Result<tokio::net::windows::named_pipe::NamedPipeServer>;
    }

    impl ServerOptionsSecurityExt for ServerOptions {
        fn create_with_security_attributes(
            &self,
            pipe_name: &str,
            security_attributes: &PipeSecurityAttributes,
        ) -> std::io::Result<tokio::net::windows::named_pipe::NamedPipeServer> {
            unsafe {
                self.create_with_security_attributes_raw(
                    pipe_name,
                    security_attributes.as_mut_ptr(),
                )
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use super::{is_valid_sid, pipe_sddl};

        #[test]
        fn accepts_real_sids() {
            assert!(is_valid_sid("S-1-5-18"));
            assert!(is_valid_sid(
                "S-1-5-21-3593993332-2847871167-1918145219-1001"
            ));
            assert!(is_valid_sid("S-1-12-1-1-1-1"));
        }

        #[test]
        fn rejects_sids_that_would_break_the_sddl() {
            for bad in [
                "",
                "S-",
                "S-1-",
                "S-1-5-21-)",
                "S-1-5-21-1;D:P(A;;GA;;;WD)",
                "Administrators",
                "S-a-1",
                "\u{ff11}-1-5-18",
            ] {
                assert!(!is_valid_sid(bad), "expected {:?} to be rejected", bad);
            }
        }

        #[test]
        fn sddl_prefers_the_configured_sid() {
            // 环境变量是进程级的，用例结束前恢复原值。
            let previous = std::env::var("HELPER_ALLOWED_SID").ok();

            std::env::set_var("HELPER_ALLOWED_SID", "S-1-5-21-1-2-3-1001");
            assert_eq!(
                pipe_sddl(),
                "D:P(A;;GRGW;;;SY)(A;;GRGW;;;BA)(A;;GRGW;;;S-1-5-21-1-2-3-1001)"
            );

            std::env::set_var("HELPER_ALLOWED_SID", "not-a-sid");
            assert_eq!(pipe_sddl(), super::LEGACY_SDDL);

            std::env::remove_var("HELPER_ALLOWED_SID");
            assert_eq!(pipe_sddl(), super::LEGACY_SDDL);

            if let Some(value) = previous {
                std::env::set_var("HELPER_ALLOWED_SID", value);
            }
        }
    }
}

mod frame {
    use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

    const MAX_FRAME_SIZE: usize = 1024 * 1024;

    pub async fn read_frame<T>(stream: &mut T) -> anyhow::Result<Option<String>>
    where
        T: AsyncRead + Unpin,
    {
        let mut header = [0u8; 4];
        match stream.read_exact(&mut header).await {
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
            Err(e) => return Err(e.into()),
        }

        let length = u32::from_le_bytes(header) as usize;
        if length > MAX_FRAME_SIZE {
            anyhow::bail!("frame too large: {}", length);
        }

        let mut payload = vec![0u8; length];
        stream.read_exact(&mut payload).await?;
        Ok(Some(String::from_utf8(payload)?))
    }

    pub async fn write_frame<T>(stream: &mut T, payload: &str) -> anyhow::Result<()>
    where
        T: AsyncWrite + Unpin,
    {
        let bytes = payload.as_bytes();
        if bytes.len() > MAX_FRAME_SIZE {
            anyhow::bail!("frame too large: {}", bytes.len());
        }
        stream
            .write_all(&(bytes.len() as u32).to_le_bytes())
            .await?;
        stream.write_all(bytes).await?;
        stream.flush().await?;
        Ok(())
    }
}
