//! Bridge to the speech-to-text engine the user runs (spec R3, R3a; ADR 0002).
//!
//! Viby owns the request and nothing else: the engine, its model and its
//! inference belong to the user. Audio leaves the process only as the body of
//! a request built here, in memory, to an address checked here.

use std::future::Future;
use std::io;
use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, Instant};

use reqwest::multipart::{Form, Part};
use reqwest::Url;
use serde::Deserialize;
use thiserror::Error;

use crate::prefs::Preferences;

pub const MIN_AUDIO_SAMPLES: usize = 4_000;
const SAMPLE_RATE: u32 = 16_000;
/// The OpenAI transcription shape; used when the endpoint has no path.
pub const DEFAULT_PATH: &str = "/v1/audio/transcriptions";
/// Name resolution and connection together (R3).
pub const CONNECT_BOUND: Duration = Duration::from_secs(3);
pub const PREVIEW_RESPONSE_BOUND: Duration = Duration::from_secs(60);
const FINAL_RESPONSE_FLOOR: Duration = Duration::from_secs(60);
const FINAL_RESPONSE_FACTOR: u32 = 10;
/// How long the activation check waits for any answer once connected. A busy
/// engine that accepted the connection is still a running engine.
const CHECK_RESPONSE_GRACE: Duration = Duration::from_secs(2);
/// A transcript is text; anything this large is not one.
const MAX_RESPONSE_BYTES: usize = 1 << 20;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum EngineError {
    #[error("no speech engine is set — open Viby Options and enter your engine's address")]
    NotConfigured,
    #[error("the engine address must be a full http:// or https:// URL")]
    InvalidEndpoint,
    #[error("the engine address must not contain a user name, password, query, or fragment")]
    EndpointCredentials,
    #[error("the engine address is on your local network — turn on \"Allow an engine on my local network\" in Viby Options to use it")]
    NeedsLocalNetwork,
    #[error("the engine address is outside this PC and your local network — Viby only sends audio to an engine on this PC or an allowed local network")]
    Refused,
    #[error("the engine address could not be found — check it in Viby Options")]
    NotFound,
    #[error("Viby could not reach your speech engine — start it, then try again")]
    Unreachable,
    #[error("your engine's HTTPS certificate was rejected — check the engine's certificate and address")]
    Certificate,
    #[error("your speech engine returned an error (HTTP {0})")]
    Status(u16),
    #[error("your speech engine sent a response Viby could not read")]
    Malformed,
    #[error("your speech engine returned no text")]
    Empty,
    #[error("your speech engine took too long to answer")]
    Timeout,
    #[error("the capture was too short to transcribe")]
    TooShort,
}

/// What a take needs to reach the engine. Built from preferences at the
/// moment of activation, so a save mid-take never changes where audio goes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineConfig {
    pub endpoint: String,
    pub model: String,
    pub language: String,
    pub allow_local_network: bool,
}

impl EngineConfig {
    pub fn from_prefs(prefs: &Preferences) -> Self {
        Self {
            endpoint: prefs.engine.endpoint.trim().to_string(),
            model: prefs.model.name.trim().to_string(),
            language: prefs.model.language.trim().to_string(),
            allow_local_network: prefs.engine.allow_local_network,
        }
    }

    pub fn is_configured(&self) -> bool {
        !self.endpoint.is_empty()
    }
}

/// Parses the endpoint form (R3): a full http(s) URL with no credentials,
/// query, or fragment; an empty or `/` path means the default path.
pub fn parse_endpoint(raw: &str) -> Result<Url, EngineError> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err(EngineError::NotConfigured);
    }
    let mut url = Url::parse(raw).map_err(|_| EngineError::InvalidEndpoint)?;
    if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
        return Err(EngineError::InvalidEndpoint);
    }
    if !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(EngineError::EndpointCredentials);
    }
    if url.path().is_empty() || url.path() == "/" {
        url.set_path(DEFAULT_PATH);
    }
    Ok(url)
}

/// The address rule (R3a): loopback always; the private ranges only with the
/// user's permission; everything else — public, link-local, unspecified,
/// IPv4-mapped IPv6 — never.
pub fn address_allowed(ip: IpAddr, allow_local_network: bool) -> bool {
    match ip {
        IpAddr::V4(v4) => v4.is_loopback() || (allow_local_network && v4.is_private()),
        IpAddr::V6(v6) => {
            v6 == Ipv6Addr::LOCALHOST
                || (allow_local_network && (v6.segments()[0] & 0xfe00) == 0xfc00)
        }
    }
}

fn check_address(ip: IpAddr, allow_local_network: bool) -> Result<(), EngineError> {
    if address_allowed(ip, allow_local_network) {
        Ok(())
    } else if !allow_local_network && address_allowed(ip, true) {
        Err(EngineError::NeedsLocalNetwork)
    } else {
        Err(EngineError::Refused)
    }
}

/// How long the final request may wait for its answer once connected: the
/// greater of 60 s and ten times the take, so a slow working engine finishes
/// a long take (R3, D11).
pub fn final_response_bound(samples: usize) -> Duration {
    let take = Duration::from_secs_f64(samples as f64 / SAMPLE_RATE as f64);
    FINAL_RESPONSE_FLOOR.max(take * FINAL_RESPONSE_FACTOR)
}

pub fn validate_audio(audio: &[f32]) -> Result<(), EngineError> {
    if audio.len() < MIN_AUDIO_SAMPLES || audio.iter().any(|sample| !sample.is_finite()) {
        return Err(EngineError::TooShort);
    }
    Ok(())
}

/// 16 kHz mono 16-bit PCM WAV, built in memory: the take never touches disk.
pub fn encode_wav(samples: &[f32]) -> Vec<u8> {
    let data_len = (samples.len() * 2) as u32;
    let mut wav = Vec::with_capacity(44 + data_len as usize);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_len).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16_u32.to_le_bytes());
    wav.extend_from_slice(&1_u16.to_le_bytes());
    wav.extend_from_slice(&1_u16.to_le_bytes());
    wav.extend_from_slice(&SAMPLE_RATE.to_le_bytes());
    wav.extend_from_slice(&(SAMPLE_RATE * 2).to_le_bytes());
    wav.extend_from_slice(&2_u16.to_le_bytes());
    wav.extend_from_slice(&16_u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    for sample in samples {
        let value = (sample.clamp(-1.0, 1.0) * i16::MAX as f32).round() as i16;
        wav.extend_from_slice(&value.to_le_bytes());
    }
    wav
}

/// Reads the transcript out of a 2xx body: a JSON object whose `text` is a
/// string, trimmed, and not empty.
pub fn parse_transcript(body: &[u8]) -> Result<String, EngineError> {
    #[derive(Deserialize)]
    struct Reply {
        text: String,
    }
    let reply: Reply = serde_json::from_slice(body).map_err(|_| EngineError::Malformed)?;
    let text = reply.text.trim();
    if text.is_empty() {
        return Err(EngineError::Empty);
    }
    Ok(text.to_string())
}

type Lookup<'a> = Pin<Box<dyn Future<Output = io::Result<Vec<SocketAddr>>> + Send + 'a>>;

/// Name resolution, behind a seam so the check-to-connect binding can be
/// proven: the client never resolves on its own.
pub trait Resolver: Send + Sync {
    fn lookup<'a>(&'a self, host: &'a str, port: u16) -> Lookup<'a>;
}

struct SystemResolver;

impl Resolver for SystemResolver {
    fn lookup<'a>(&'a self, host: &'a str, port: u16) -> Lookup<'a> {
        Box::pin(async move { Ok(tokio::net::lookup_host((host, port)).await?.collect()) })
    }
}

/// An endpoint whose every address passed R3a, pinned for one connection.
struct Target {
    url: Url,
    domain: Option<String>,
    addrs: Vec<SocketAddr>,
    connect_deadline: Instant,
}

impl Target {
    fn connect_budget(&self) -> Duration {
        self.connect_deadline
            .saturating_duration_since(Instant::now())
            .max(Duration::from_millis(1))
    }
}

pub struct Engine {
    resolver: Arc<dyn Resolver>,
    extra_roots: Vec<reqwest::Certificate>,
}

impl Engine {
    pub fn system() -> Self {
        Self {
            resolver: Arc::new(SystemResolver),
            extra_roots: Vec::new(),
        }
    }

    /// Parses, resolves, and checks the endpoint (R3a). Runs before every
    /// connection; the connection then goes only to the addresses checked.
    async fn target(&self, endpoint: &str, allow_local_network: bool) -> Result<Target, EngineError> {
        let url = parse_endpoint(endpoint)?;
        let connect_deadline = Instant::now() + CONNECT_BOUND;
        let host = url.host_str().ok_or(EngineError::InvalidEndpoint)?;
        let port = url
            .port_or_known_default()
            .ok_or(EngineError::InvalidEndpoint)?;
        let literal = host.trim_start_matches('[').trim_end_matches(']');
        let (domain, addrs) = match literal.parse::<IpAddr>() {
            Ok(ip) => (None, vec![SocketAddr::new(ip, port)]),
            Err(_) => {
                let resolved = tokio::time::timeout(CONNECT_BOUND, self.resolver.lookup(host, port))
                    .await
                    .map_err(|_| EngineError::NotFound)?
                    .map_err(|_| EngineError::NotFound)?;
                (Some(host.to_string()), resolved)
            }
        };
        if addrs.is_empty() {
            return Err(EngineError::NotFound);
        }
        for addr in &addrs {
            check_address(addr.ip(), allow_local_network)?;
        }
        Ok(Target {
            url,
            domain,
            addrs,
            connect_deadline,
        })
    }

    /// A client for one connection to `target`. `total` bounds the whole
    /// request; the connection inside it is bounded by what is left of the
    /// 3 s budget (R3). Connecting to this PC or the local network takes
    /// milliseconds, so for a transcription `total` is the response bound.
    fn client(&self, target: &Target, total: Duration) -> Result<reqwest::Client, EngineError> {
        let connect = target.connect_budget();
        // Redirects and proxies would both carry the audio past the check.
        let mut builder = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .connect_timeout(connect)
            .timeout(total)
            .pool_max_idle_per_host(0);
        if let Some(domain) = &target.domain {
            builder = builder.resolve_to_addrs(domain, &target.addrs);
        }
        for root in &self.extra_roots {
            builder = builder.add_root_certificate(root.clone());
        }
        builder.build().map_err(|_| EngineError::Unreachable)
    }

    /// Save-time validation (R7): the endpoint form and R3a under the
    /// permission being saved. Never called on load.
    pub async fn validate_for_save(&self, endpoint: &str, allow_local_network: bool) -> Result<(), EngineError> {
        self.target(endpoint, allow_local_network).await.map(|_| ())
    }

    /// The activation-time check (R3): R3a, then a connection — TLS included
    /// for https — to the checked address. Any HTTP answer means the engine
    /// is there; so does a connection that stays open without one.
    pub async fn check(&self, config: &EngineConfig) -> Result<(), EngineError> {
        let target = self.target(&config.endpoint, config.allow_local_network).await?;
        let client = self.client(&target, target.connect_budget() + CHECK_RESPONSE_GRACE)?;
        match client.head(target.url.clone()).send().await {
            Ok(_) => Ok(()),
            Err(error) => match classify(&error) {
                EngineError::Timeout => Ok(()),
                EngineError::Malformed => Ok(()),
                other => Err(other),
            },
        }
    }

    /// One request of the R3 shape. Dropping the returned future abandons
    /// the request and closes its connection.
    pub async fn transcribe(
        &self,
        config: &EngineConfig,
        audio: Vec<f32>,
        response_bound: Duration,
    ) -> Result<String, EngineError> {
        validate_audio(&audio)?;
        let target = self.target(&config.endpoint, config.allow_local_network).await?;
        let client = self.client(&target, response_bound)?;
        let wav = encode_wav(&audio);
        drop(audio);
        let file = Part::bytes(wav)
            .file_name("audio.wav")
            .mime_str("audio/wav")
            .map_err(|_| EngineError::Malformed)?;
        let mut form = Form::new().part("file", file).text("response_format", "json");
        if !config.language.is_empty() && !config.language.eq_ignore_ascii_case("auto") {
            form = form.text("language", config.language.to_ascii_lowercase());
        }
        if !config.model.is_empty() {
            form = form.text("model", config.model.clone());
        }
        let response = client
            .post(target.url.clone())
            .multipart(form)
            .send()
            .await
            .map_err(|error| classify(&error))?;
        let status = response.status();
        if !status.is_success() {
            return Err(EngineError::Status(status.as_u16()));
        }
        if response
            .content_length()
            .is_some_and(|length| length as usize > MAX_RESPONSE_BYTES)
        {
            return Err(EngineError::Malformed);
        }
        let body = response.bytes().await.map_err(|error| classify(&error))?;
        if body.len() > MAX_RESPONSE_BYTES {
            return Err(EngineError::Malformed);
        }
        parse_transcript(&body)
    }
}

/// Maps a transport failure to the message the user acts on (R6). A
/// certificate failure is named as one, never as a stopped engine.
fn classify(error: &reqwest::Error) -> EngineError {
    let mut source: Option<&dyn std::error::Error> = Some(error);
    while let Some(current) = source {
        if current.to_string().to_ascii_lowercase().contains("certificate") {
            return EngineError::Certificate;
        }
        source = current.source();
    }
    if error.is_timeout() && !error.is_connect() {
        EngineError::Timeout
    } else if error.is_connect() || error.is_timeout() {
        EngineError::Unreachable
    } else if error.is_body() || error.is_decode() {
        EngineError::Malformed
    } else {
        EngineError::Unreachable
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::{Ipv4Addr, TcpListener, TcpStream};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Mutex;

    fn block_on<F: Future>(future: F) -> F::Output {
        tauri::async_runtime::block_on(future)
    }

    fn config(endpoint: String) -> EngineConfig {
        EngineConfig {
            endpoint,
            model: String::new(),
            language: "auto".to_string(),
            allow_local_network: false,
        }
    }

    fn speech() -> Vec<f32> {
        (0..MIN_AUDIO_SAMPLES * 2)
            .map(|i| (i as f32 / 20.0).sin() * 0.3)
            .collect()
    }

    // ---- endpoint form -------------------------------------------------

    #[test]
    fn an_endpoint_without_a_path_uses_the_openai_path() {
        for raw in ["http://127.0.0.1:8080", "http://127.0.0.1:8080/", " http://localhost:9000 "] {
            assert_eq!(parse_endpoint(raw).unwrap().path(), DEFAULT_PATH, "{raw}");
        }
    }

    #[test]
    fn any_other_path_is_used_exactly_as_typed() {
        let url = parse_endpoint("http://127.0.0.1:8080/inference").unwrap();
        assert_eq!(url.path(), "/inference");
    }

    #[test]
    fn the_endpoint_carries_no_credentials_query_or_fragment() {
        for raw in [
            "http://user:secret@127.0.0.1:8080",
            "http://user@127.0.0.1:8080",
            "http://127.0.0.1:8080/v1?api_key=secret",
            "http://127.0.0.1:8080/inference#x",
        ] {
            assert_eq!(parse_endpoint(raw), Err(EngineError::EndpointCredentials), "{raw}");
        }
    }

    #[test]
    fn the_endpoint_must_be_a_full_http_url() {
        for raw in ["127.0.0.1:8080", "ftp://127.0.0.1/x", "file:///C:/x", "http://", "not a url"] {
            assert_eq!(parse_endpoint(raw), Err(EngineError::InvalidEndpoint), "{raw}");
        }
        assert_eq!(parse_endpoint("   "), Err(EngineError::NotConfigured));
    }

    // ---- address rule (R3a) ----------------------------------------------

    #[test]
    fn loopback_is_always_allowed() {
        for ip in ["127.0.0.1", "127.8.9.10", "::1"] {
            assert!(address_allowed(ip.parse().unwrap(), false), "{ip}");
        }
    }

    #[test]
    fn private_ranges_need_the_users_permission() {
        for ip in ["10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.1.20", "fd12::1", "fc00::5"] {
            let ip: IpAddr = ip.parse().unwrap();
            assert!(!address_allowed(ip, false), "{ip} without permission");
            assert!(address_allowed(ip, true), "{ip} with permission");
            assert_eq!(check_address(ip, false), Err(EngineError::NeedsLocalNetwork));
        }
    }

    #[test]
    fn every_other_address_is_refused_even_with_permission() {
        for ip in [
            "8.8.8.8",
            "172.32.0.1",
            "169.254.1.1",
            "0.0.0.0",
            "::",
            "fe80::1",
            "2001:4860:4860::8888",
            "::ffff:127.0.0.1",
            "::ffff:192.168.1.1",
            "100.64.0.1",
        ] {
            let ip: IpAddr = ip.parse().unwrap();
            assert!(!address_allowed(ip, true), "{ip}");
            assert_eq!(check_address(ip, true), Err(EngineError::Refused), "{ip}");
        }
    }

    // ---- request shape -------------------------------------------------

    #[test]
    fn audio_is_encoded_as_16khz_mono_16bit_wav() {
        let wav = encode_wav(&[0.0, 1.0, -1.0]);
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(&wav[8..16], b"WAVEfmt ");
        assert_eq!(u16::from_le_bytes([wav[22], wav[23]]), 1, "mono");
        assert_eq!(u32::from_le_bytes(wav[24..28].try_into().unwrap()), 16_000);
        assert_eq!(u16::from_le_bytes([wav[34], wav[35]]), 16, "bits");
        assert_eq!(u32::from_le_bytes(wav[40..44].try_into().unwrap()), 6);
        assert_eq!(i16::from_le_bytes([wav[46], wav[47]]), i16::MAX);
        assert_eq!(i16::from_le_bytes([wav[48], wav[49]]), -i16::MAX);
    }

    #[test]
    fn a_transcript_is_a_trimmed_non_empty_text_string() {
        assert_eq!(parse_transcript(br#"{"text":"  hola mundo \n"}"#), Ok("hola mundo".into()));
        assert_eq!(parse_transcript(br#"{"text":"   "}"#), Err(EngineError::Empty));
        assert_eq!(parse_transcript(br#"{"text":42}"#), Err(EngineError::Malformed));
        assert_eq!(parse_transcript(br#"{"result":"x"}"#), Err(EngineError::Malformed));
        assert_eq!(parse_transcript(b"<html>"), Err(EngineError::Malformed));
    }

    #[test]
    fn the_final_bound_scales_with_the_take_above_a_minute() {
        let seconds = |s: usize| final_response_bound(s * SAMPLE_RATE as usize);
        assert_eq!(seconds(2), Duration::from_secs(60));
        assert_eq!(seconds(6), Duration::from_secs(60));
        assert_eq!(seconds(12), Duration::from_secs(120));
        assert_eq!(seconds(120), Duration::from_secs(1_200));
    }

    #[test]
    fn short_or_broken_audio_is_refused_before_any_request() {
        assert_eq!(validate_audio(&vec![0.0; MIN_AUDIO_SAMPLES - 1]), Err(EngineError::TooShort));
        let mut audio = vec![0.0_f32; MIN_AUDIO_SAMPLES];
        audio[10] = f32::NAN;
        assert_eq!(validate_audio(&audio), Err(EngineError::TooShort));
        audio[10] = 0.0;
        assert!(validate_audio(&audio).is_ok());
    }

    // ---- a local test engine -------------------------------------------

    #[derive(Debug, Clone, Default)]
    struct Recorded {
        method: String,
        path: String,
        body: Vec<u8>,
    }

    impl Recorded {
        fn field(&self, name: &str) -> Option<String> {
            let text = String::from_utf8_lossy(&self.body);
            let marker = format!("name=\"{name}\"");
            let start = text.find(&marker)? + marker.len();
            let rest = &text[start..];
            let value_start = rest.find("\r\n\r\n")? + 4;
            let value_end = rest[value_start..].find("\r\n")?;
            Some(rest[value_start..value_start + value_end].to_string())
        }
    }

    #[derive(Clone)]
    struct Reply {
        delay: Duration,
        status: u16,
        body: &'static str,
        location: Option<String>,
    }

    fn ok(body: &'static str) -> Reply {
        Reply {
            delay: Duration::ZERO,
            status: 200,
            body,
            location: None,
        }
    }

    struct TestEngine {
        port: u16,
        requests: Arc<Mutex<Vec<Recorded>>>,
        connections: Arc<AtomicUsize>,
    }

    fn read_request(stream: &mut impl Read) -> Option<Recorded> {
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        reader.read_line(&mut line).ok()?;
        let mut parts = line.split_whitespace();
        let method = parts.next()?.to_string();
        let path = parts.next()?.to_string();
        let mut length = 0;
        let mut chunked = false;
        loop {
            let mut header = String::new();
            reader.read_line(&mut header).ok()?;
            let header = header.trim_end();
            if header.is_empty() {
                break;
            }
            let lower = header.to_ascii_lowercase();
            if let Some(value) = lower.strip_prefix("content-length:") {
                length = value.trim().parse().ok()?;
            }
            if lower.starts_with("transfer-encoding:") && lower.contains("chunked") {
                chunked = true;
            }
        }
        let mut body = Vec::new();
        if chunked {
            loop {
                let mut size = String::new();
                reader.read_line(&mut size).ok()?;
                let size = usize::from_str_radix(size.trim(), 16).ok()?;
                let mut chunk = vec![0; size + 2];
                reader.read_exact(&mut chunk).ok()?;
                if size == 0 {
                    break;
                }
                body.extend_from_slice(&chunk[..size]);
            }
        } else {
            body.resize(length, 0);
            reader.read_exact(&mut body).ok()?;
        }
        Some(Recorded { method, path, body })
    }

    fn write_reply(stream: &mut impl Write, reply: &Reply) {
        std::thread::sleep(reply.delay);
        let location = reply
            .location
            .as_ref()
            .map(|to| format!("Location: {to}\r\n"))
            .unwrap_or_default();
        let _ = write!(
            stream,
            "HTTP/1.1 {} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\n{location}Connection: close\r\n\r\n{}",
            reply.status,
            reply.body.len(),
            reply.body
        );
        let _ = stream.flush();
    }

    fn serve(reply: impl Fn(&Recorded) -> Reply + Send + Sync + 'static) -> TestEngine {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let connections = Arc::new(AtomicUsize::new(0));
        let reply = Arc::new(reply);
        let (log, count) = (Arc::clone(&requests), Arc::clone(&connections));
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                count.fetch_add(1, Ordering::SeqCst);
                let (log, reply) = (Arc::clone(&log), Arc::clone(&reply));
                std::thread::spawn(move || {
                    if let Some(request) = read_request(&mut stream) {
                        log.lock().unwrap().push(request.clone());
                        write_reply(&mut stream, &reply(&request));
                    }
                });
            }
        });
        TestEngine {
            port,
            requests,
            connections,
        }
    }

    impl TestEngine {
        fn url(&self, path: &str) -> String {
            format!("http://127.0.0.1:{}{path}", self.port)
        }
        fn posts(&self) -> Vec<Recorded> {
            self.requests
                .lock()
                .unwrap()
                .iter()
                .filter(|request| request.method == "POST")
                .cloned()
                .collect()
        }
    }

    /// Resolves one name to a fixed answer for its first lookup, then to a
    /// different one: any second resolution would be visible.
    struct ScriptedResolver {
        answers: Mutex<Vec<Vec<SocketAddr>>>,
        lookups: AtomicUsize,
        delay: Duration,
    }

    impl ScriptedResolver {
        fn new(answers: Vec<Vec<SocketAddr>>) -> Arc<Self> {
            Arc::new(Self {
                answers: Mutex::new(answers),
                lookups: AtomicUsize::new(0),
                delay: Duration::ZERO,
            })
        }
    }

    impl Resolver for ScriptedResolver {
        fn lookup<'a>(&'a self, _host: &'a str, _port: u16) -> Lookup<'a> {
            Box::pin(async move {
                self.lookups.fetch_add(1, Ordering::SeqCst);
                tokio::time::sleep(self.delay).await;
                let mut answers = self.answers.lock().unwrap();
                Ok(if answers.len() > 1 { answers.remove(0) } else { answers[0].clone() })
            })
        }
    }

    fn engine_with(resolver: Arc<dyn Resolver>) -> Engine {
        Engine {
            resolver,
            extra_roots: Vec::new(),
        }
    }

    #[test]
    fn a_take_is_sent_as_the_r3_multipart_request() {
        let server = serve(|_| ok(r#"{"text":" hola "}"#));
        let engine = Engine::system();
        let mut cfg = config(server.url(""));
        cfg.language = "ES".into();
        cfg.model = "whisper-1".into();
        let text = block_on(engine.transcribe(&cfg, speech(), Duration::from_secs(5)));
        assert_eq!(text, Ok("hola".to_string()));
        let request = &server.posts()[0];
        assert_eq!(request.path, DEFAULT_PATH);
        assert_eq!(request.field("response_format").as_deref(), Some("json"));
        assert_eq!(request.field("language").as_deref(), Some("es"));
        assert_eq!(request.field("model").as_deref(), Some("whisper-1"));
        let body = String::from_utf8_lossy(&request.body);
        assert!(body.contains("name=\"file\"; filename=\"audio.wav\""));
        assert!(body.contains("Content-Type: audio/wav"));
        assert!(request.body.windows(4).any(|w| w == b"RIFF"));
    }

    #[test]
    fn automatic_language_and_an_empty_model_send_neither_field() {
        let server = serve(|_| ok(r#"{"text":"x"}"#));
        let cfg = config(server.url("/inference"));
        block_on(Engine::system().transcribe(&cfg, speech(), Duration::from_secs(5))).unwrap();
        let request = &server.posts()[0];
        assert_eq!(request.path, "/inference");
        assert_eq!(request.field("language"), None);
        assert_eq!(request.field("model"), None);
    }

    #[test]
    fn engine_failures_map_to_their_own_errors() {
        for (reply, expected) in [
            (Reply { status: 500, ..ok("oops") }, EngineError::Status(500)),
            (Reply { status: 404, ..ok("") }, EngineError::Status(404)),
            (ok("not json"), EngineError::Malformed),
            (ok(r#"{"text":7}"#), EngineError::Malformed),
            (ok(r#"{"text":""}"#), EngineError::Empty),
        ] {
            let server = serve(move |_| reply.clone());
            let result = block_on(Engine::system().transcribe(
                &config(server.url("")),
                speech(),
                Duration::from_secs(5),
            ));
            assert_eq!(result, Err(expected.clone()), "{expected:?}");
        }
    }

    #[test]
    fn a_redirect_is_never_followed() {
        // 303 is the redirect a client would follow even for a POST (as a
        // GET), and the check's HEAD carries no body, so either would reach
        // the target if redirects were followed. Nothing may.
        let target = serve(|_| ok(r#"{"text":"followed"}"#));
        for status in [303, 307] {
            let to = target.url(DEFAULT_PATH);
            let server = serve(move |_| Reply {
                status,
                location: Some(to.clone()),
                ..ok("")
            });
            let cfg = config(server.url(""));
            let result = block_on(Engine::system().transcribe(&cfg, speech(), Duration::from_secs(5)));
            assert_eq!(result, Err(EngineError::Status(status)));
            assert_eq!(block_on(Engine::system().check(&cfg)), Ok(()));
        }
        assert!(
            target.requests.lock().unwrap().is_empty(),
            "a redirect reached its target"
        );
    }

    #[test]
    fn a_system_proxy_is_not_used() {
        // A proxy that would accept the request: if it were consulted, the
        // audio would reach it instead of the engine.
        let proxy = serve(|_| ok(r#"{"text":"via proxy"}"#));
        let server = serve(|_| ok(r#"{"text":"direct"}"#));
        std::env::set_var("HTTP_PROXY", proxy.url(""));
        std::env::set_var("http_proxy", proxy.url(""));
        std::env::set_var("ALL_PROXY", proxy.url(""));
        let result = block_on(Engine::system().transcribe(
            &config(server.url("")),
            speech(),
            Duration::from_secs(5),
        ));
        for name in ["HTTP_PROXY", "http_proxy", "ALL_PROXY"] {
            std::env::remove_var(name);
        }
        assert_eq!(result, Ok("direct".to_string()));
        assert_eq!(proxy.connections.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn a_slow_answer_inside_the_bound_is_accepted_and_one_past_it_fails() {
        let server = serve(|_| Reply {
            delay: Duration::from_millis(600),
            ..ok(r#"{"text":"slow but fine"}"#)
        });
        let cfg = config(server.url(""));
        let inside = block_on(Engine::system().transcribe(&cfg, speech(), Duration::from_secs(3)));
        assert_eq!(inside, Ok("slow but fine".to_string()));
        let past = block_on(Engine::system().transcribe(&cfg, speech(), Duration::from_millis(200)));
        assert_eq!(past, Err(EngineError::Timeout));
    }

    #[test]
    fn a_stopped_engine_is_unreachable_not_missing() {
        let port = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let cfg = config(format!("http://127.0.0.1:{port}"));
        assert_eq!(block_on(Engine::system().check(&cfg)), Err(EngineError::Unreachable));
        assert_eq!(
            block_on(Engine::system().transcribe(&cfg, speech(), Duration::from_secs(5))),
            Err(EngineError::Unreachable)
        );
    }

    #[test]
    fn a_connection_that_never_opens_fails_within_the_connect_bound() {
        // 10.255.255.1 is private and, on this network, answers no SYN; the
        // permission lets the request try it.
        let mut cfg = config("http://10.255.255.1:9".to_string());
        cfg.allow_local_network = true;
        let started = Instant::now();
        let result = block_on(Engine::system().check(&cfg));
        let waited = started.elapsed();
        assert!(
            matches!(result, Err(EngineError::Unreachable)),
            "{result:?}"
        );
        assert!(waited < CONNECT_BOUND + Duration::from_millis(500), "{waited:?}");
    }

    #[test]
    fn a_resolution_that_never_answers_fails_as_not_found_within_the_bound() {
        let resolver = Arc::new(ScriptedResolver {
            answers: Mutex::new(vec![vec![]]),
            lookups: AtomicUsize::new(0),
            delay: Duration::from_secs(30),
        });
        let engine = engine_with(resolver);
        let started = Instant::now();
        let result = block_on(engine.check(&config("http://slow-dns.test:8080".into())));
        assert_eq!(result, Err(EngineError::NotFound));
        assert!(started.elapsed() < CONNECT_BOUND + Duration::from_millis(500));
    }

    #[test]
    fn a_name_that_resolves_to_nothing_is_not_found() {
        let engine = engine_with(ScriptedResolver::new(vec![vec![]]));
        assert_eq!(
            block_on(engine.check(&config("http://gone.test:8080".into()))),
            Err(EngineError::NotFound)
        );
    }

    #[test]
    fn a_name_with_any_refused_address_is_refused_before_audio_is_sent() {
        let server = serve(|_| ok(r#"{"text":"x"}"#));
        let local = SocketAddr::from((Ipv4Addr::LOCALHOST, server.port));
        let public = SocketAddr::from(([8, 8, 8, 8], server.port));
        let engine = engine_with(ScriptedResolver::new(vec![vec![local, public]]));
        let result = block_on(engine.transcribe(
            &config(format!("http://mixed.test:{}", server.port)),
            speech(),
            Duration::from_secs(5),
        ));
        assert_eq!(result, Err(EngineError::Refused));
        assert_eq!(server.connections.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn the_connection_goes_only_to_the_address_that_was_checked() {
        // First lookup: loopback (allowed). Any later lookup would answer a
        // public address. The request must reach the engine through the
        // first answer and never resolve again.
        let server = serve(|_| ok(r#"{"text":"pinned"}"#));
        let resolver = ScriptedResolver::new(vec![
            vec![SocketAddr::from((Ipv4Addr::LOCALHOST, server.port))],
            vec![SocketAddr::from(([8, 8, 8, 8], server.port))],
        ]);
        let engine = engine_with(resolver.clone());
        let result = block_on(engine.transcribe(
            &config(format!("http://viby-engine.test:{}", server.port)),
            speech(),
            Duration::from_secs(5),
        ));
        assert_eq!(result, Ok("pinned".to_string()));
        assert_eq!(resolver.lookups.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn a_dual_stack_name_reaches_an_engine_listening_only_on_ipv4() {
        let server = serve(|_| ok(r#"{"text":"v4"}"#));
        let resolver = ScriptedResolver::new(vec![vec![
            SocketAddr::from((Ipv6Addr::LOCALHOST, server.port)),
            SocketAddr::from((Ipv4Addr::LOCALHOST, server.port)),
        ]]);
        let result = block_on(engine_with(resolver).transcribe(
            &config(format!("http://localhost:{}", server.port)),
            speech(),
            Duration::from_secs(5),
        ));
        assert_eq!(result, Ok("v4".to_string()));
    }

    #[test]
    fn dropping_a_request_closes_it_and_its_answer_is_never_read() {
        let server = serve(|_| Reply {
            delay: Duration::from_secs(2),
            ..ok(r#"{"text":"late"}"#)
        });
        let cfg = config(server.url(""));
        let engine = Arc::new(Engine::system());
        let (tx, rx) = std::sync::mpsc::channel();
        let task = tauri::async_runtime::spawn({
            let engine = Arc::clone(&engine);
            async move {
                let result = engine.transcribe(&cfg, speech(), Duration::from_secs(5)).await;
                let _ = tx.send(result);
            }
        });
        let started = Instant::now();
        while server.posts().is_empty() && started.elapsed() < Duration::from_secs(3) {
            std::thread::sleep(Duration::from_millis(10));
        }
        task.abort();
        assert!(rx.recv_timeout(Duration::from_secs(4)).is_err(), "an abandoned request delivered a result");
    }

    #[test]
    fn the_activation_check_accepts_any_http_answer() {
        let server = serve(|_| Reply { status: 404, ..ok("") });
        assert_eq!(block_on(Engine::system().check(&config(server.url("/inference")))), Ok(()));
        assert!(server.posts().is_empty(), "the check sent no audio");
    }

    #[test]
    fn save_time_validation_applies_r3a_under_the_permission_being_saved() {
        let engine = Engine::system();
        assert_eq!(block_on(engine.validate_for_save("http://127.0.0.1:8080", false)), Ok(()));
        assert_eq!(
            block_on(engine.validate_for_save("http://192.168.1.5:8080", false)),
            Err(EngineError::NeedsLocalNetwork)
        );
        assert_eq!(block_on(engine.validate_for_save("http://192.168.1.5:8080", true)), Ok(()));
        assert_eq!(
            block_on(engine.validate_for_save("http://8.8.8.8:8080", true)),
            Err(EngineError::Refused)
        );
        assert_eq!(
            block_on(engine.validate_for_save("http://user:pw@127.0.0.1:8080", false)),
            Err(EngineError::EndpointCredentials)
        );
        let unresolvable = engine_with(ScriptedResolver::new(vec![vec![]]));
        assert_eq!(
            block_on(unresolvable.validate_for_save("http://nowhere.test", false)),
            Err(EngineError::NotFound)
        );
    }

    // ---- https through the pinned connection --------------------------

    struct TlsEngine {
        port: u16,
        ca_pem: String,
        posts: Arc<AtomicUsize>,
    }

    fn serve_tls(names: &[&str]) -> TlsEngine {
        use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
        let ca_key = rcgen::KeyPair::generate().unwrap();
        let mut ca_params = rcgen::CertificateParams::new(Vec::<String>::new()).unwrap();
        ca_params.is_ca = rcgen::IsCa::Ca(rcgen::BasicConstraints::Unconstrained);
        let ca = ca_params.self_signed(&ca_key).unwrap();
        let leaf_key = rcgen::KeyPair::generate().unwrap();
        let leaf = rcgen::CertificateParams::new(names.iter().map(|n| n.to_string()).collect::<Vec<_>>())
            .unwrap()
            .signed_by(&leaf_key, &ca, &ca_key)
            .unwrap();
        let server_config = rustls::ServerConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(
            vec![CertificateDer::from(leaf.der().to_vec())],
            PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(leaf_key.serialize_der())),
        )
        .unwrap();
        let server_config = Arc::new(server_config);
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let posts = Arc::new(AtomicUsize::new(0));
        let counter = Arc::clone(&posts);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { continue };
                let (config, counter) = (Arc::clone(&server_config), Arc::clone(&counter));
                std::thread::spawn(move || {
                    let connection = rustls::ServerConnection::new(config).unwrap();
                    let mut tls: rustls::StreamOwned<rustls::ServerConnection, TcpStream> =
                        rustls::StreamOwned::new(connection, stream);
                    if let Some(request) = read_request(&mut tls) {
                        if request.method == "POST" {
                            counter.fetch_add(1, Ordering::SeqCst);
                        }
                        write_reply(&mut tls, &ok(r#"{"text":"secure"}"#));
                        tls.conn.send_close_notify();
                        let _ = tls.flush();
                    }
                });
            }
        });
        TlsEngine {
            port,
            ca_pem: ca.pem(),
            posts,
        }
    }

    fn tls_engine(server: &TlsEngine, trust: bool) -> Engine {
        let resolver = ScriptedResolver::new(vec![vec![SocketAddr::from((
            Ipv4Addr::LOCALHOST,
            server.port,
        ))]]);
        Engine {
            resolver,
            extra_roots: if trust {
                vec![reqwest::Certificate::from_pem(server.ca_pem.as_bytes()).unwrap()]
            } else {
                Vec::new()
            },
        }
    }

    #[test]
    fn https_works_through_the_pinned_connection_with_validation_in_force() {
        let server = serve_tls(&["viby-engine.test"]);
        let engine = tls_engine(&server, true);
        let cfg = config(format!("https://viby-engine.test:{}", server.port));
        assert_eq!(block_on(engine.check(&cfg)), Ok(()));
        assert_eq!(
            block_on(engine.transcribe(&cfg, speech(), Duration::from_secs(5))),
            Ok("secure".to_string())
        );
    }

    #[test]
    fn an_untrusted_or_mismatched_certificate_is_rejected_before_audio_is_sent() {
        let untrusted = serve_tls(&["viby-engine.test"]);
        let cfg = config(format!("https://viby-engine.test:{}", untrusted.port));
        let engine = tls_engine(&untrusted, false);
        assert_eq!(block_on(engine.check(&cfg)), Err(EngineError::Certificate));
        assert_eq!(
            block_on(engine.transcribe(&cfg, speech(), Duration::from_secs(5))),
            Err(EngineError::Certificate)
        );
        assert_eq!(untrusted.posts.load(Ordering::SeqCst), 0);

        let mismatched = serve_tls(&["someone-else.test"]);
        let cfg = config(format!("https://viby-engine.test:{}", mismatched.port));
        let engine = tls_engine(&mismatched, true);
        assert_eq!(block_on(engine.check(&cfg)), Err(EngineError::Certificate));
        assert_eq!(mismatched.posts.load(Ordering::SeqCst), 0);
    }

    // ---- the real engine (scripts/smoke-engine.ps1) ---------------------

    fn read_wav_samples(path: &str) -> Vec<f32> {
        let bytes = std::fs::read(path).expect("smoke WAV");
        let data = bytes
            .windows(4)
            .position(|w| w == b"data")
            .expect("data chunk")
            + 8;
        bytes[data..]
            .chunks_exact(2)
            .map(|pair| i16::from_le_bytes([pair[0], pair[1]]) as f32 / i16::MAX as f32)
            .collect()
    }

    /// Real composition: the user's whisper.cpp server, a spoken take, the
    /// production request path. Counts only on stdout, never the text (R5).
    #[test]
    #[ignore = "needs a running engine; run scripts/smoke-engine.ps1"]
    fn a_real_engine_transcribes_a_spoken_take() {
        let endpoint = std::env::var("VIBY_SMOKE_ENDPOINT").expect("VIBY_SMOKE_ENDPOINT");
        let samples = read_wav_samples(&std::env::var("VIBY_SMOKE_WAV").expect("VIBY_SMOKE_WAV"));
        let expect: Vec<String> = std::env::var("VIBY_SMOKE_EXPECT")
            .unwrap_or_default()
            .split(',')
            .filter(|word| !word.is_empty())
            .map(str::to_ascii_lowercase)
            .collect();
        let mut cfg = config(endpoint);
        cfg.allow_local_network = std::env::var("VIBY_SMOKE_ALLOW_LAN").as_deref() == Ok("1");
        let engine = Engine::system();
        block_on(engine.check(&cfg)).expect("activation check");
        let bound = final_response_bound(samples.len());
        let started = Instant::now();
        let text = block_on(engine.transcribe(&cfg, samples.clone(), bound)).expect("final");
        let lowered = text.to_ascii_lowercase();
        let matched = expect.iter().filter(|word| lowered.contains(word.as_str())).count();
        println!(
            "REAL_ENGINE chars={} seconds={:.2} expected_words={}/{}",
            text.chars().count(),
            started.elapsed().as_secs_f64(),
            matched,
            expect.len()
        );
        assert!(matched * 2 >= expect.len(), "the engine missed most expected words");
        // A preview-sized window goes through the same path.
        let window = samples[samples.len().saturating_sub(48_000)..].to_vec();
        let preview = block_on(engine.transcribe(&cfg, window, PREVIEW_RESPONSE_BOUND));
        println!("REAL_ENGINE preview_ok={}", preview.is_ok());
        if !cfg.allow_local_network {
            return;
        }
        // The same private-address engine is refused once the permission is off.
        cfg.allow_local_network = false;
        assert_eq!(block_on(engine.check(&cfg)), Err(EngineError::NeedsLocalNetwork));
        println!("REAL_ENGINE private_refused_without_permission=true");
    }
}
