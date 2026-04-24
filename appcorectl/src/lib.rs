use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Context, Result};
use clap::{error::ErrorKind, ArgAction, Args, CommandFactory, Parser, Subcommand};
use clap_complete::{generate, Shell};
use reqwest::blocking::{Client as HttpClient, ClientBuilder};
use reqwest::{Certificate, Identity, Method, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use url::Url;

const VERSION: &str = env!("CARGO_PKG_VERSION");
const EXIT_SUCCESS: i32 = 0;
const EXIT_VALIDATE: i32 = 2;
const EXIT_AUTH: i32 = 3;
const EXIT_TRANSPORT: i32 = 4;
const EXIT_API: i32 = 5;

#[derive(Parser, Debug, Clone)]
#[command(name = "appcorectl", version = VERSION, about = "Official operator CLI for AppCoreOS", disable_help_subcommand = true)]
struct Cli {
    #[arg(long)]
    config: Option<String>,
    #[arg(long)]
    target: Option<String>,
    #[arg(long)]
    ca: Option<String>,
    #[arg(long)]
    cert: Option<String>,
    #[arg(long)]
    key: Option<String>,
    #[arg(long = "api-key")]
    api_key: Option<String>,
    #[arg(long, action = ArgAction::SetTrue)]
    insecure: bool,
    #[arg(short = 'o', long)]
    output: Option<String>,
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand, Debug, Clone)]
enum Commands {
    Target {
        #[command(subcommand)]
        command: TargetCommand,
    },
    Bootstrap {
        #[command(subcommand)]
        command: BootstrapCommand,
    },
    Info,
    State,
    #[command(alias = "service")]
    Services {
        #[command(subcommand)]
        command: ServicesCommand,
    },
    #[command(alias = "container")]
    Containers {
        #[command(subcommand)]
        command: ContainersCommand,
    },
    Logs {
        #[command(subcommand)]
        command: LogsCommand,
    },
    Network {
        #[command(subcommand)]
        command: NetworkCommand,
    },
    Host {
        #[command(subcommand)]
        command: HostCommand,
    },
    Completion {
        shell: Shell,
    },
}

#[derive(Subcommand, Debug, Clone)]
enum TargetCommand {
    Add(TargetAddArgs),
    Use {
        name: String,
    },
    #[command(alias = "remove", alias = "delete")]
    Rm(TargetRemoveArgs),
    Ls,
}

#[derive(Args, Debug, Clone)]
struct TargetAddArgs {
    name: String,
    #[arg(long)]
    url: String,
    #[arg(long)]
    ca: Option<String>,
    #[arg(long)]
    cert: Option<String>,
    #[arg(long)]
    key: Option<String>,
    #[arg(long = "api-key")]
    api_key: Option<String>,
    #[arg(long, action = ArgAction::SetTrue)]
    insecure: bool,
}

#[derive(Args, Debug, Clone)]
struct TargetRemoveArgs {
    name: String,
    #[arg(long, action = ArgAction::SetTrue)]
    purge_pki: bool,
}

#[derive(Subcommand, Debug, Clone)]
enum BootstrapCommand {
    Status,
    Claim(BootstrapClaimArgs),
    Wait(BootstrapWaitArgs),
}

#[derive(Args, Debug, Clone)]
struct BootstrapClaimArgs {
    #[arg(long)]
    token: String,
    #[arg(long = "client-ca-file")]
    client_ca_file: Option<String>,
    #[arg(long, default_value_t = true, action = ArgAction::Set)]
    wait: bool,
    #[arg(long = "wait-timeout", default_value_t = 120)]
    wait_timeout: u64,
    #[arg(long = "wait-interval", default_value_t = 3)]
    wait_interval: u64,
}

#[derive(Args, Debug, Clone)]
struct BootstrapWaitArgs {
    #[arg(long, default_value_t = 120)]
    timeout: u64,
    #[arg(long, default_value_t = 3)]
    interval: u64,
}

#[derive(Subcommand, Debug, Clone)]
enum ServicesCommand {
    List,
    Get { unit: String },
    Restart { unit: String },
}

#[derive(Subcommand, Debug, Clone)]
enum ContainersCommand {
    List,
    Logs(ContainerLogsArgs),
}

#[derive(Args, Debug, Clone)]
struct ContainerLogsArgs {
    name: String,
    #[arg(long, default_value_t = 200)]
    tail: u64,
}

#[derive(Subcommand, Debug, Clone)]
enum LogsCommand {
    Journal(JournalArgs),
}

#[derive(Args, Debug, Clone)]
struct JournalArgs {
    #[arg(long, default_value_t = 200)]
    tail: u64,
    #[arg(long)]
    unit: Option<String>,
}

#[derive(Subcommand, Debug, Clone)]
enum NetworkCommand {
    Interfaces,
}

#[derive(Subcommand, Debug, Clone)]
enum HostCommand {
    UpdateStatus,
    Update,
    Reboot(HostRebootArgs),
}

#[derive(Args, Debug, Clone)]
struct HostRebootArgs {
    #[arg(long, action = ArgAction::SetTrue)]
    yes: bool,
}

#[derive(Debug)]
struct CliError {
    code: i32,
    message: String,
    hint: Option<String>,
}

impl CliError {
    fn new(code: i32, message: impl Into<String>, hint: Option<String>) -> Self {
        Self {
            code,
            message: message.into(),
            hint,
        }
    }

    fn render(&self) -> String {
        match &self.hint {
            Some(hint) => format!("{}\nHint: {}", self.message, hint),
            None => self.message.clone(),
        }
    }
}

#[derive(Debug)]
enum ClientError {
    Api {
        status: StatusCode,
        method: String,
        path: String,
        body: String,
    },
    Transport(String),
}

enum BootstrapWaitState {
    Ready,
    ReadyNeedsApiKey,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct TargetProfile {
    #[serde(default)]
    url: String,
    #[serde(default)]
    ca: String,
    #[serde(default)]
    cert: String,
    #[serde(default)]
    key: String,
    #[serde(default)]
    api_key: String,
    #[serde(default)]
    insecure: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Config {
    #[serde(default)]
    current_target: String,
    #[serde(default = "default_output")]
    output: String,
    #[serde(default)]
    targets: BTreeMap<String, TargetProfile>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            current_target: String::new(),
            output: default_output(),
            targets: BTreeMap::new(),
        }
    }
}

#[derive(Debug)]
struct Runtime {
    cfg_path: PathBuf,
    cfg: Config,
    target_name: String,
    target: TargetProfile,
    output: String,
    audit_path: PathBuf,
}

#[derive(Debug, Serialize)]
struct AuditEntry<'a> {
    timestamp: String,
    target: &'a str,
    verb: &'a str,
    path: &'a str,
    result_status: u16,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<&'a str>,
}

struct ApiClient {
    base_url: Url,
    http: HttpClient,
    api_key: String,
    audit_log: PathBuf,
    target_name: String,
}

struct ApiClientOptions<'a> {
    target_name: &'a str,
    base_url: &'a str,
    ca_path: &'a str,
    cert_path: &'a str,
    key_path: &'a str,
    api_key: &'a str,
    insecure: bool,
    audit_log: &'a Path,
}

pub fn run() -> i32 {
    let mut stdout = io::stdout();
    let mut stderr = io::stderr();
    match execute_args(env::args_os(), &mut stdout, &mut stderr) {
        Ok(()) => EXIT_SUCCESS,
        Err(err) => {
            let _ = writeln!(stderr, "{}", err.render());
            err.code
        }
    }
}

fn execute_args<I, T, W1, W2>(args: I, out: &mut W1, err: &mut W2) -> Result<(), CliError>
where
    I: IntoIterator<Item = T>,
    T: Into<std::ffi::OsString> + Clone,
    W1: Write,
    W2: Write,
{
    let cli = match Cli::try_parse_from(args) {
        Ok(cli) => cli,
        Err(err)
            if matches!(
                err.kind(),
                ErrorKind::DisplayHelp | ErrorKind::DisplayVersion
            ) =>
        {
            write!(out, "{err}").map_err(io_cli_error)?;
            return Ok(());
        }
        Err(err) => return Err(CliError::new(EXIT_VALIDATE, err.to_string(), None)),
    };
    run_cli(cli, out, err)
}

fn run_cli<W1: Write, W2: Write>(cli: Cli, out: &mut W1, err: &mut W2) -> Result<(), CliError> {
    match cli.command.clone() {
        Commands::Target { command } => handle_target(cli, command, out, err),
        Commands::Bootstrap { command } => handle_bootstrap(cli, command, out, err),
        Commands::Info => run_read_command(&cli, "/v1/info", None, out),
        Commands::State => run_read_command(&cli, "/v1/state", None, out),
        Commands::Services { command } => handle_services(cli, command, out),
        Commands::Containers { command } => handle_containers(cli, command, out),
        Commands::Logs { command } => handle_logs(cli, command, out),
        Commands::Network { command } => handle_network(cli, command, out),
        Commands::Host { command } => handle_host(cli, command, out),
        Commands::Completion { shell } => {
            let mut cmd = Cli::command();
            generate(shell, &mut cmd, "appcorectl", out);
            Ok(())
        }
    }
}

fn handle_target<W1: Write, W2: Write>(
    cli: Cli,
    cmd: TargetCommand,
    out: &mut W1,
    err: &mut W2,
) -> Result<(), CliError> {
    match cmd {
        TargetCommand::Add(args) => {
            let name = args.name.trim();
            if name.is_empty() {
                return Err(validate_error(
                    "target add requires exactly one profile name",
                    "run: appcorectl target add mylab --url https://host:9090",
                ));
            }
            let parsed = Url::parse(args.url.trim())
                .ok()
                .filter(|url| url.scheme() == "https")
                .ok_or_else(|| {
                    validate_error(
                        "--url must be a valid https URL",
                        "example: --url https://node1.example.com:9090",
                    )
                })?;
            if args.cert.is_some() ^ args.key.is_some() {
                return Err(validate_error(
                    "--cert and --key must be set together",
                    "set both mTLS file paths",
                ));
            }

            let mut runtime = build_runtime(&cli, false)?;
            let mut profile = TargetProfile {
                url: parsed.to_string(),
                ca: args.ca.unwrap_or_default().trim().to_string(),
                cert: args.cert.unwrap_or_default().trim().to_string(),
                key: args.key.unwrap_or_default().trim().to_string(),
                api_key: args.api_key.unwrap_or_default().trim().to_string(),
                insecure: args.insecure,
            };

            if profile.ca.is_empty() && !profile.insecure {
                match pin_server_certificate(name, &profile.url) {
                    Ok(path) => {
                        profile.ca = path.to_string_lossy().to_string();
                        writeln!(out, "Pinned server certificate at {}", profile.ca)
                            .map_err(io_cli_error)?;
                    }
                    Err(pin_err) => {
                        writeln!(
                            err,
                            "Warning: could not auto-pin server certificate ({pin_err}). Use --ca or --insecure."
                        )
                        .map_err(io_cli_error)?;
                    }
                }
            }

            runtime.cfg.targets.insert(name.to_string(), profile);
            if runtime.cfg.current_target.is_empty() {
                runtime.cfg.current_target = name.to_string();
            }
            save_config(&runtime.cfg_path, &runtime.cfg).map_err(api_cli_error)?;
            writeln!(out, "Saved target \"{name}\"").map_err(io_cli_error)?;
            Ok(())
        }
        TargetCommand::Use { name } => {
            let mut runtime = build_runtime(&cli, false)?;
            if !runtime.cfg.targets.contains_key(name.trim()) {
                return Err(validate_error(
                    format!("target \"{}\" not found", name.trim()),
                    "run: appcorectl target ls",
                ));
            }
            runtime.cfg.current_target = name.trim().to_string();
            save_config(&runtime.cfg_path, &runtime.cfg).map_err(api_cli_error)?;
            writeln!(out, "Using target \"{}\"", name.trim()).map_err(io_cli_error)?;
            Ok(())
        }
        TargetCommand::Rm(args) => {
            if args.name.trim().is_empty() {
                return Err(validate_error(
                    "target rm requires exactly one profile name",
                    "run: appcorectl target rm <name>",
                ));
            }
            let mut runtime = build_runtime(&cli, false)?;
            if runtime.cfg.targets.remove(args.name.trim()).is_none() {
                return Err(validate_error(
                    format!("target \"{}\" not found", args.name.trim()),
                    "run: appcorectl target ls",
                ));
            }
            if runtime.cfg.current_target == args.name.trim() {
                runtime.cfg.current_target = runtime
                    .cfg
                    .targets
                    .keys()
                    .next()
                    .cloned()
                    .unwrap_or_default();
            }
            save_config(&runtime.cfg_path, &runtime.cfg).map_err(api_cli_error)?;
            writeln!(out, "Removed target \"{}\" from config.", args.name.trim())
                .map_err(io_cli_error)?;
            if !runtime.cfg.current_target.is_empty() {
                writeln!(
                    out,
                    "Current target is now \"{}\".",
                    runtime.cfg.current_target
                )
                .map_err(io_cli_error)?;
            }
            if !args.purge_pki {
                writeln!(out, "Local PKI was not removed. Use --purge-pki to delete generated PKI for this target.")
                    .map_err(io_cli_error)?;
                return Ok(());
            }
            let pki_dir = local_pki_target_dir(args.name.trim()).map_err(api_cli_error)?;
            if pki_dir.exists() {
                fs::remove_dir_all(&pki_dir)
                    .with_context(|| format!("remove local PKI directory {}", pki_dir.display()))
                    .map_err(api_cli_error)?;
            }
            writeln!(
                out,
                "Removed local PKI directory \"{}\".",
                pki_dir.display()
            )
            .map_err(io_cli_error)?;
            Ok(())
        }
        TargetCommand::Ls => {
            let runtime = build_runtime(&cli, false)?;
            let rows = runtime
                .cfg
                .targets
                .iter()
                .map(|(name, profile)| {
                    json!({
                        "name": name,
                        "current": name == &runtime.cfg.current_target,
                        "url": profile.url,
                        "ca": profile.ca,
                        "cert": profile.cert,
                        "key": profile.key,
                        "api_key": redact_secret(&profile.api_key),
                        "insecure": profile.insecure,
                    })
                })
                .collect::<Vec<_>>();
            print_read(out, &runtime.output, Value::Array(rows))
        }
    }
}

fn handle_bootstrap<W1: Write, W2: Write>(
    cli: Cli,
    cmd: BootstrapCommand,
    out: &mut W1,
    err: &mut W2,
) -> Result<(), CliError> {
    match cmd {
        BootstrapCommand::Status => {
            let mut runtime = build_runtime(&cli, true)?;
            ensure_server_trust_for_bootstrap(&mut runtime, err)?;
            let client = runtime.new_client()?;
            let payload = client.get_json("/v1/bootstrap/status", None)?;
            print_read(out, &runtime.output, payload)
        }
        BootstrapCommand::Claim(args) => {
            if args.token.trim().is_empty() {
                return Err(validate_error(
                    "--token is required",
                    "pass the bootstrap token from the appliance",
                ));
            }
            if args.wait_timeout < 1 {
                return Err(validate_error(
                    "invalid wait timeout",
                    "set --wait-timeout to at least 1 second",
                ));
            }
            if args.wait_interval < 1 {
                return Err(validate_error(
                    "invalid wait interval",
                    "set --wait-interval to at least 1 second",
                ));
            }

            let mut runtime = build_runtime(&cli, true)?;
            ensure_server_trust_for_bootstrap(&mut runtime, err)?;

            let mut generated: Option<LocalClientPki> = None;
            let pem = if let Some(path) = args.client_ca_file.as_deref() {
                fs::read(expand_path(path).map_err(api_cli_error)?)
                    .with_context(|| format!("read {path}"))
                    .map_err(|_| {
                        validate_error(
                            "failed reading --client-ca-file",
                            "check the provided PEM path",
                        )
                    })?
            } else {
                let pki = ensure_local_client_pki(&runtime.target_name).map_err(api_cli_error)?;
                let mut profile = runtime
                    .cfg
                    .targets
                    .get(&runtime.target_name)
                    .cloned()
                    .unwrap_or_default();
                if profile.cert.is_empty() {
                    profile.cert = pki.client_cert_path.to_string_lossy().to_string();
                }
                if profile.key.is_empty() {
                    profile.key = pki.client_key_path.to_string_lossy().to_string();
                }
                runtime
                    .cfg
                    .targets
                    .insert(runtime.target_name.clone(), profile.clone());
                save_config(&runtime.cfg_path, &runtime.cfg).map_err(api_cli_error)?;
                runtime.target.cert = profile.cert;
                runtime.target.key = profile.key;
                let pem = pki.ca_cert_pem.clone();
                generated = Some(pki);
                pem
            };

            let client = runtime.new_client()?;
            let mut headers = BTreeMap::new();
            headers.insert(
                "X-Bootstrap-Token".to_string(),
                args.token.trim().to_string(),
            );
            client.post_json(
                "/v1/bootstrap/claim",
                Some(&headers),
                json!({ "client_ca_pem": String::from_utf8_lossy(&pem) }),
            )?;

            if let Some(pki) = generated {
                writeln!(
                    out,
                    "Generated local client PKI in {}",
                    pki.target_dir.display()
                )
                .map_err(io_cli_error)?;
                writeln!(out, "Using client cert: {}", pki.client_cert_path.display())
                    .map_err(io_cli_error)?;
                writeln!(out, "Note: --ca still configures server TLS trust; generated CA is for client mTLS.")
                    .map_err(io_cli_error)?;
            }
            if args.wait {
                writeln!(out, "Waiting for post-claim API readiness...").map_err(io_cli_error)?;
                match wait_for_bootstrap_ready(&runtime, args.wait_timeout, args.wait_interval)? {
                    BootstrapWaitState::Ready => {}
                    BootstrapWaitState::ReadyNeedsApiKey => {
                        writeln!(
                            out,
                            "Post-claim API is up, but management endpoints now require an API key."
                        )
                        .map_err(io_cli_error)?;
                        writeln!(
                            out,
                            "Set it with --api-key, APPCORECTL_API_KEY, or by updating the target profile."
                        )
                        .map_err(io_cli_error)?;
                    }
                }
            }
            writeln!(out, "Bootstrap claim succeeded.").map_err(io_cli_error)?;
            Ok(())
        }
        BootstrapCommand::Wait(args) => {
            if args.timeout < 1 {
                return Err(validate_error(
                    "invalid wait timeout",
                    "set --timeout to at least 1 second",
                ));
            }
            if args.interval < 1 {
                return Err(validate_error(
                    "invalid wait interval",
                    "set --interval to at least 1 second",
                ));
            }
            let mut runtime = build_runtime(&cli, true)?;
            ensure_server_trust_for_bootstrap(&mut runtime, err)?;
            match wait_for_bootstrap_ready(&runtime, args.timeout, args.interval)? {
                BootstrapWaitState::Ready => {}
                BootstrapWaitState::ReadyNeedsApiKey => {
                    writeln!(
                        out,
                        "Post-claim API is up, but management endpoints now require an API key."
                    )
                    .map_err(io_cli_error)?;
                    writeln!(
                        out,
                        "Set it with --api-key, APPCORECTL_API_KEY, or by updating the target profile."
                    )
                    .map_err(io_cli_error)?;
                }
            }
            Ok(())
        }
    }
}

fn handle_services<W: Write>(cli: Cli, cmd: ServicesCommand, out: &mut W) -> Result<(), CliError> {
    match cmd {
        ServicesCommand::List => run_read_command(&cli, "/v1/services", None, out),
        ServicesCommand::Get { unit } => {
            if unit.trim().is_empty() {
                return Err(validate_error(
                    "services get requires one unit name",
                    "run: appcorectl services get nginx.service",
                ));
            }
            run_read_command(
                &cli,
                &format!("/v1/services/{}", url_encode(unit.trim())),
                None,
                out,
            )
        }
        ServicesCommand::Restart { unit } => {
            if unit.trim().is_empty() {
                return Err(validate_error(
                    "services restart requires one unit name",
                    "run: appcorectl services restart nginx.service",
                ));
            }
            let runtime = build_runtime(&cli, true)?;
            let client = runtime.new_client()?;
            client.post_json(
                &format!("/v1/services/{}/restart", url_encode(unit.trim())),
                None,
                json!({}),
            )?;
            writeln!(out, "Service \"{}\" restart requested.", unit.trim())
                .map_err(io_cli_error)?;
            Ok(())
        }
    }
}

fn handle_containers<W: Write>(
    cli: Cli,
    cmd: ContainersCommand,
    out: &mut W,
) -> Result<(), CliError> {
    match cmd {
        ContainersCommand::List => run_read_command(&cli, "/v1/containers", None, out),
        ContainersCommand::Logs(args) => {
            if args.name.trim().is_empty() {
                return Err(validate_error(
                    "containers logs requires one container name",
                    "run: appcorectl containers logs <name> --tail 200",
                ));
            }
            if args.tail == 0 {
                return Err(validate_error(
                    "--tail must be greater than 0",
                    "use a positive integer, e.g. --tail 200",
                ));
            }
            let runtime = build_runtime(&cli, true)?;
            let client = runtime.new_client()?;
            let payload = client.get_text(
                &format!("/v1/containers/{}/logs", url_encode(args.name.trim())),
                Some(&[("tail".to_string(), args.tail.to_string())]),
            )?;
            write_text(out, &payload)
        }
    }
}

fn handle_logs<W: Write>(cli: Cli, cmd: LogsCommand, out: &mut W) -> Result<(), CliError> {
    match cmd {
        LogsCommand::Journal(args) => {
            if args.tail == 0 {
                return Err(validate_error(
                    "--tail must be greater than 0",
                    "use a positive integer, e.g. --tail 200",
                ));
            }
            let runtime = build_runtime(&cli, true)?;
            let client = runtime.new_client()?;
            let mut query = vec![("tail".to_string(), args.tail.to_string())];
            if let Some(unit) = args
                .unit
                .as_deref()
                .map(str::trim)
                .filter(|unit| !unit.is_empty())
            {
                query.push(("unit".to_string(), unit.to_string()));
            }
            let payload = client.get_text("/v1/logs/journal", Some(&query))?;
            write_text(out, &payload)
        }
    }
}

fn handle_network<W: Write>(cli: Cli, cmd: NetworkCommand, out: &mut W) -> Result<(), CliError> {
    match cmd {
        NetworkCommand::Interfaces => run_read_command(&cli, "/v1/network/interfaces", None, out),
    }
}

fn handle_host<W: Write>(cli: Cli, cmd: HostCommand, out: &mut W) -> Result<(), CliError> {
    match cmd {
        HostCommand::UpdateStatus => run_read_command(&cli, "/v1/host/update-status", None, out),
        HostCommand::Update => {
            let runtime = build_runtime(&cli, true)?;
            let client = runtime.new_client()?;
            client.post_json("/v1/host/update", None, json!({}))?;
            writeln!(out, "Host update requested.").map_err(io_cli_error)?;
            Ok(())
        }
        HostCommand::Reboot(args) => {
            if !args.yes {
                return Err(validate_error(
                    "host reboot requires --yes",
                    "run: appcorectl host reboot --yes",
                ));
            }
            let runtime = build_runtime(&cli, true)?;
            let client = runtime.new_client()?;
            client.post_json("/v1/host/reboot", None, json!({}))?;
            writeln!(out, "Host reboot requested.").map_err(io_cli_error)?;
            Ok(())
        }
    }
}

fn run_read_command<W: Write>(
    cli: &Cli,
    path: &str,
    query: Option<Vec<(String, String)>>,
    out: &mut W,
) -> Result<(), CliError> {
    let runtime = build_runtime(cli, true)?;
    let client = runtime.new_client()?;
    let payload = client.get_json(path, query.as_deref())?;
    print_read(out, &runtime.output, payload)
}

impl Runtime {
    fn new_client(&self) -> Result<ApiClient, CliError> {
        ApiClient::new(ApiClientOptions {
            target_name: &self.target_name,
            base_url: &self.target.url,
            ca_path: &self.target.ca,
            cert_path: &self.target.cert,
            key_path: &self.target.key,
            api_key: &self.target.api_key,
            insecure: self.target.insecure,
            audit_log: &self.audit_path,
        })
    }
}

impl ApiClient {
    fn new(opts: ApiClientOptions<'_>) -> Result<Self, CliError> {
        if opts.base_url.trim().is_empty() {
            return Err(validate_error(
                "target URL is empty",
                "review target profile with: appcorectl target ls",
            ));
        }
        let url = Url::parse(opts.base_url).map_err(|e| {
            validate_error(
                format!("parse target URL: {e}"),
                "review target profile with: appcorectl target ls",
            )
        })?;
        if url.scheme() != "https" {
            return Err(validate_error(
                "target URL must use https",
                "review target profile with: appcorectl target ls",
            ));
        }

        let mut builder = ClientBuilder::new()
            .timeout(Duration::from_secs(20))
            .http1_only();
        if opts.insecure {
            builder = builder.danger_accept_invalid_certs(true);
        }
        if !opts.ca_path.trim().is_empty() {
            let ca_path = expand_path(opts.ca_path).map_err(api_cli_error)?;
            let pem = fs::read(&ca_path)
                .with_context(|| format!("read CA file {}", ca_path.display()))
                .map_err(api_cli_error)?;
            let cert = Certificate::from_pem(&pem)
                .context("parse CA PEM failed")
                .map_err(api_cli_error)?;
            builder = builder.add_root_certificate(cert);
        }
        if !opts.cert_path.trim().is_empty() || !opts.key_path.trim().is_empty() {
            if opts.cert_path.trim().is_empty() || opts.key_path.trim().is_empty() {
                return Err(validate_error(
                    "both client cert and key are required for mTLS",
                    "review target profile with: appcorectl target ls",
                ));
            }
            let cert_path = expand_path(opts.cert_path).map_err(api_cli_error)?;
            let key_path = expand_path(opts.key_path).map_err(api_cli_error)?;
            let mut identity_pem = fs::read(&cert_path)
                .with_context(|| format!("read client cert {}", cert_path.display()))
                .map_err(api_cli_error)?;
            identity_pem.extend(
                fs::read(&key_path)
                    .with_context(|| format!("read client key {}", key_path.display()))
                    .map_err(api_cli_error)?,
            );
            let identity = Identity::from_pem(&identity_pem)
                .context("load client cert/key")
                .map_err(api_cli_error)?;
            builder = builder.identity(identity);
        }
        let http = builder
            .build()
            .context("build HTTP client")
            .map_err(api_cli_error)?;
        Ok(Self {
            base_url: url,
            http,
            api_key: opts.api_key.to_string(),
            audit_log: opts.audit_log.to_path_buf(),
            target_name: opts.target_name.to_string(),
        })
    }

    fn get_json(&self, path: &str, query: Option<&[(String, String)]>) -> Result<Value, CliError> {
        let bytes = self.request(Method::GET, path, query, None, None)?;
        if bytes.is_empty() {
            return Ok(Value::Null);
        }
        serde_json::from_slice(&bytes)
            .context("decode response json")
            .map_err(api_cli_error)
    }

    fn get_text(&self, path: &str, query: Option<&[(String, String)]>) -> Result<String, CliError> {
        let bytes = self.request(Method::GET, path, query, None, None)?;
        String::from_utf8(bytes)
            .context("decode text response")
            .map_err(api_cli_error)
    }

    fn post_json(
        &self,
        path: &str,
        headers: Option<&BTreeMap<String, String>>,
        body: Value,
    ) -> Result<(), CliError> {
        let payload = serde_json::to_vec(&body)
            .context("encode request body")
            .map_err(api_cli_error)?;
        let _ = self.request(Method::POST, path, None, headers, Some(payload))?;
        Ok(())
    }

    fn request(
        &self,
        method: Method,
        path: &str,
        query: Option<&[(String, String)]>,
        headers: Option<&BTreeMap<String, String>>,
        body: Option<Vec<u8>>,
    ) -> Result<Vec<u8>, CliError> {
        let mut url = self
            .base_url
            .join(path)
            .map_err(|e| api_cli_error(anyhow!("build request URL: {e}")))?;
        if let Some(query) = query {
            let mut pairs = url.query_pairs_mut();
            for (key, value) in query {
                pairs.append_pair(key, value);
            }
        }

        let mut request = self
            .http
            .request(method.clone(), url.clone())
            .header("Accept", "application/json");
        if let Some(body) = body {
            request = request
                .header("Content-Type", "application/json")
                .body(body);
        }
        if !self.api_key.is_empty() {
            request = request.header("Authorization", format!("Bearer {}", self.api_key));
        }
        if let Some(headers) = headers {
            for (key, value) in headers {
                request = request.header(key, value);
            }
        }

        let response = request.send();
        match response {
            Ok(response) => {
                let status = response.status();
                let bytes = response
                    .bytes()
                    .map(|b| b.to_vec())
                    .context("read response body")
                    .map_err(api_cli_error)?;
                self.write_audit(path, method.as_str(), status.as_u16(), None);
                if status.is_client_error() || status.is_server_error() {
                    let body = String::from_utf8_lossy(&bytes).trim().to_string();
                    return Err(map_client_error(ClientError::Api {
                        status,
                        method: method.as_str().to_string(),
                        path: path.to_string(),
                        body,
                    }));
                }
                Ok(bytes)
            }
            Err(err) => {
                let err_text = err.to_string();
                self.write_audit(path, method.as_str(), 0, Some(&err_text));
                Err(map_client_error(ClientError::Transport(err_text)))
            }
        }
    }

    fn write_audit(&self, path: &str, verb: &str, result_status: u16, error: Option<&str>) {
        let timestamp = chrono_timestamp();
        let entry = AuditEntry {
            timestamp,
            target: &self.target_name,
            verb,
            path,
            result_status,
            error,
        };
        if let Ok(line) = serde_json::to_string(&entry) {
            if let Some(parent) = self.audit_log.parent() {
                let _ = fs::create_dir_all(parent);
            }
            let mut content = line;
            content.push('\n');
            let _ = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&self.audit_log)
                .and_then(|mut file| file.write_all(content.as_bytes()));
        }
    }
}

fn build_runtime(cli: &Cli, require_target: bool) -> Result<Runtime, CliError> {
    let cfg_path = resolve_config_path(cli.config.as_deref()).map_err(api_cli_error)?;
    let cfg = load_config(&cfg_path).map_err(|_| {
        validate_error(
            "failed to load config",
            "fix YAML syntax or select a valid --config path",
        )
    })?;

    let target_name = cli
        .target
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToString::to_string)
        .or_else(|| env_string("APPCORECTL_TARGET"))
        .or_else(|| (!cfg.current_target.is_empty()).then(|| cfg.current_target.clone()))
        .unwrap_or_default();

    if require_target && target_name.is_empty() {
        return Err(validate_error(
            "no active target selected",
            "run: appcorectl target use <name>",
        ));
    }

    let base = if target_name.is_empty() {
        TargetProfile::default()
    } else {
        cfg.targets.get(&target_name).cloned().ok_or_else(|| {
            validate_error(
                format!("target \"{target_name}\" not found"),
                "run: appcorectl target ls",
            )
        })?
    };

    let merged = merge_target(
        base,
        TargetProfile {
            url: String::new(),
            ca: cli.ca.clone().unwrap_or_default(),
            cert: cli.cert.clone().unwrap_or_default(),
            key: cli.key.clone().unwrap_or_default(),
            api_key: cli.api_key.clone().unwrap_or_default(),
            insecure: cli.insecure,
        },
    )?;

    if require_target && merged.url.trim().is_empty() {
        return Err(validate_error(
            "target URL is missing",
            "run: appcorectl target add <name> --url https://host:9090",
        ));
    }
    if merged.insecure {
        eprintln!("WARNING: TLS verification disabled via --insecure / APPCORECTL_INSECURE. Do not use in production.");
    }

    let output = resolve_output(cli.output.as_deref(), Some(&cfg.output));
    Ok(Runtime {
        cfg_path,
        cfg,
        target_name,
        target: merged,
        output,
        audit_path: default_audit_log_path().map_err(api_cli_error)?,
    })
}

fn ensure_server_trust_for_bootstrap<W: Write>(
    runtime: &mut Runtime,
    err: &mut W,
) -> Result<(), CliError> {
    if runtime.target.insecure || !runtime.target.ca.trim().is_empty() {
        return Ok(());
    }
    let ca_path =
        pin_server_certificate(&runtime.target_name, &runtime.target.url).map_err(|_| {
            validate_error(
                "failed to establish TLS trust for bootstrap",
                "set target CA with --ca, or use --insecure for local development",
            )
        })?;
    let ca_string = ca_path.to_string_lossy().to_string();
    runtime
        .cfg
        .targets
        .entry(runtime.target_name.clone())
        .or_default()
        .ca = ca_string.clone();
    save_config(&runtime.cfg_path, &runtime.cfg).map_err(api_cli_error)?;
    runtime.target.ca = ca_string;
    writeln!(
        err,
        "Pinned server certificate for \"{}\" at {}",
        runtime.target_name, runtime.target.ca
    )
    .map_err(io_cli_error)?;
    Ok(())
}

fn wait_for_bootstrap_ready(
    runtime: &Runtime,
    timeout_secs: u64,
    interval_secs: u64,
) -> Result<BootstrapWaitState, CliError> {
    let deadline = SystemTime::now()
        .checked_add(Duration::from_secs(timeout_secs))
        .ok_or_else(|| api_cli_error(anyhow!("invalid wait timeout")))?;
    let mut last_err: Option<CliError> = None;

    loop {
        match runtime
            .new_client()
            .and_then(|client| client.get_json("/v1/bootstrap/status", None))
        {
            Ok(payload) => {
                let claimed = payload
                    .as_object()
                    .and_then(|map| map.get("claimed"))
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                if claimed {
                    let client = runtime.new_client()?;
                    match client.get_json("/v1/info", None) {
                        Ok(_) => return Ok(BootstrapWaitState::Ready),
                        Err(err) if err.code == EXIT_AUTH => {
                            return Ok(BootstrapWaitState::ReadyNeedsApiKey);
                        }
                        Err(err) => last_err = Some(err),
                    }
                }
            }
            Err(err) => last_err = Some(err),
        }

        if SystemTime::now() >= deadline {
            if let Some(err) = last_err {
                return Err(CliError::new(
                    EXIT_TRANSPORT,
                    "timed out waiting for bootstrap readiness",
                    Some(err.message),
                ));
            }
            return Err(CliError::new(
                EXIT_TRANSPORT,
                "timed out waiting for bootstrap readiness",
                Some("check agent.service and API reachability".to_string()),
            ));
        }
        std::thread::sleep(Duration::from_secs(interval_secs));
    }
}

fn print_read<W: Write>(out: &mut W, format: &str, value: Value) -> Result<(), CliError> {
    match format.trim() {
        "table" | "" => print_table(out, &value),
        "json" => {
            let text = serde_json::to_string_pretty(&value)
                .context("render json output")
                .map_err(api_cli_error)?;
            writeln!(out, "{text}").map_err(io_cli_error)
        }
        _ => Err(validate_error(
            "invalid --output value",
            "use --output table or --output json",
        )),
    }
}

fn print_table<W: Write>(out: &mut W, value: &Value) -> Result<(), CliError> {
    match value {
        Value::Array(rows) => print_array_table(out, rows),
        Value::Object(map) => {
            if map.len() == 1 {
                if let Some((_, nested)) = map.iter().next() {
                    match nested {
                        Value::Array(rows) => return print_array_table(out, rows),
                        Value::Object(_) => return print_table(out, nested),
                        _ => {}
                    }
                }
            }
            let mut lines = vec![("KEY".to_string(), "VALUE".to_string())];
            for (key, val) in map {
                lines.push((key.to_string(), value_to_string(val)));
            }
            print_columns(out, lines)
        }
        _ => {
            writeln!(out, "{}", value_to_string(value)).map_err(io_cli_error)?;
            Ok(())
        }
    }
}

fn print_array_table<W: Write>(out: &mut W, rows: &[Value]) -> Result<(), CliError> {
    if rows.is_empty() {
        writeln!(out, "No results.").map_err(io_cli_error)?;
        return Ok(());
    }
    let mut headers = BTreeSet::new();
    let mut mapped = Vec::new();
    for row in rows {
        let object = row
            .as_object()
            .ok_or_else(|| api_cli_error(anyhow!("render output: expected object rows")))?;
        for key in object.keys() {
            headers.insert(key.to_string());
        }
        mapped.push(object);
    }

    let headers = headers.into_iter().collect::<Vec<_>>();
    let mut lines = vec![headers.iter().map(String::from).collect::<Vec<_>>()];
    for row in mapped {
        lines.push(
            headers
                .iter()
                .map(|key| value_to_string(row.get(key).unwrap_or(&Value::Null)))
                .collect(),
        );
    }
    print_matrix(out, lines)
}

fn print_columns<W: Write>(out: &mut W, rows: Vec<(String, String)>) -> Result<(), CliError> {
    let width = rows.iter().map(|(left, _)| left.len()).max().unwrap_or(0);
    for (left, right) in rows {
        writeln!(out, "{left:width$}  {right}").map_err(io_cli_error)?;
    }
    Ok(())
}

fn print_matrix<W: Write>(out: &mut W, rows: Vec<Vec<String>>) -> Result<(), CliError> {
    let columns = rows.iter().map(|row| row.len()).max().unwrap_or(0);
    let mut widths = vec![0usize; columns];
    for row in &rows {
        for (index, value) in row.iter().enumerate() {
            widths[index] = widths[index].max(value.len());
        }
    }
    for row in rows {
        let mut rendered = String::new();
        for (index, value) in row.iter().enumerate() {
            if index > 0 {
                rendered.push_str("  ");
            }
            rendered.push_str(&format!("{value:width$}", width = widths[index]));
        }
        writeln!(out, "{rendered}").map_err(io_cli_error)?;
    }
    Ok(())
}

fn write_text<W: Write>(out: &mut W, payload: &str) -> Result<(), CliError> {
    write!(out, "{payload}").map_err(io_cli_error)?;
    if !payload.ends_with('\n') {
        writeln!(out).map_err(io_cli_error)?;
    }
    Ok(())
}

fn value_to_string(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        Value::Bool(v) => v.to_string(),
        Value::Number(v) => v.to_string(),
        Value::Array(_) | Value::Object(_) => {
            serde_json::to_string(value).unwrap_or_else(|_| "<invalid>".to_string())
        }
    }
}

fn default_output() -> String {
    "table".to_string()
}

fn resolve_config_path(path: Option<&str>) -> Result<PathBuf> {
    if let Some(path) = path.filter(|path| !path.trim().is_empty()) {
        return expand_path(path);
    }
    if let Some(path) = env_string("APPCORECTL_CONFIG") {
        return expand_path(&path);
    }
    default_config_path()
}

fn load_config(path: &Path) -> Result<Config> {
    if !path.exists() {
        return Ok(Config::default());
    }
    let bytes = fs::read(path).with_context(|| format!("read config file {}", path.display()))?;
    if bytes.is_empty() {
        return Ok(Config::default());
    }
    let mut cfg: Config = serde_yaml::from_slice(&bytes).context("parse config file")?;
    if cfg.output.trim().is_empty() {
        cfg.output = default_output();
    }
    Ok(cfg)
}

fn save_config(path: &Path, cfg: &Config) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("create config directory {}", parent.display()))?;
    }
    let yaml = serde_yaml::to_string(cfg).context("marshal config")?;
    let temp_path = path.with_extension("tmp");
    fs::write(&temp_path, yaml)
        .with_context(|| format!("write temp config {}", temp_path.display()))?;
    fs::rename(&temp_path, path)
        .with_context(|| format!("replace config file {}", path.display()))?;
    Ok(())
}

fn merge_target(base: TargetProfile, flags: TargetProfile) -> Result<TargetProfile, CliError> {
    let mut merged = base;
    if let Some(value) = env_string("APPCORECTL_URL") {
        merged.url = value;
    }
    if let Some(value) = env_string("APPCORECTL_CA") {
        merged.ca = value;
    }
    if let Some(value) = env_string("APPCORECTL_CERT") {
        merged.cert = value;
    }
    if let Some(value) = env_string("APPCORECTL_KEY") {
        merged.key = value;
    }
    if let Some(value) = env_string("APPCORECTL_API_KEY") {
        merged.api_key = value;
    }
    if let Some(value) = env_bool("APPCORECTL_INSECURE").map_err(api_cli_error)? {
        merged.insecure = value;
    }
    if !flags.ca.trim().is_empty() {
        merged.ca = flags.ca;
    }
    if !flags.cert.trim().is_empty() {
        merged.cert = flags.cert;
    }
    if !flags.key.trim().is_empty() {
        merged.key = flags.key;
    }
    if !flags.api_key.trim().is_empty() {
        merged.api_key = flags.api_key;
    }
    if flags.insecure {
        merged.insecure = true;
    }

    if merged.cert.trim().is_empty() ^ merged.key.trim().is_empty() {
        return Err(CliError::new(
            EXIT_VALIDATE,
            "set both --cert and --key for mTLS",
            Some("set both --cert and --key for mTLS".to_string()),
        ));
    }
    Ok(merged)
}

fn resolve_output(flag_output: Option<&str>, config_output: Option<&str>) -> String {
    if let Some(value) = flag_output.map(str::trim).filter(|value| !value.is_empty()) {
        return value.to_lowercase();
    }
    if let Some(value) = env_string("APPCORECTL_OUTPUT") {
        return value.to_lowercase();
    }
    config_output.unwrap_or("table").trim().to_lowercase()
}

fn env_string(key: &str) -> Option<String> {
    env::var(key)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn env_bool(key: &str) -> Result<Option<bool>> {
    let Some(value) = env_string(key) else {
        return Ok(None);
    };
    value
        .parse::<bool>()
        .map(Some)
        .map_err(|e| anyhow!("parse {key} as bool: {e}"))
}

fn default_config_path() -> Result<PathBuf> {
    Ok(home_dir()?.join(".config/appcorectl/config.yaml"))
}

fn default_audit_log_path() -> Result<PathBuf> {
    Ok(home_dir()?.join(".local/state/appcorectl/audit.log"))
}

fn default_pki_root_dir() -> Result<PathBuf> {
    Ok(home_dir()?.join(".local/share/appcorectl/pki"))
}

fn home_dir() -> Result<PathBuf> {
    dirs::home_dir().ok_or_else(|| anyhow!("resolve home directory"))
}

fn expand_path(path: &str) -> Result<PathBuf> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err(anyhow!("path is empty"));
    }
    let expanded = if trimmed == "~" {
        home_dir()?
    } else if let Some(rest) = trimmed.strip_prefix("~/") {
        home_dir()?.join(rest)
    } else {
        PathBuf::from(trimmed)
    };
    Ok(expanded.canonicalize().or_else(|_| {
        if expanded.is_absolute() {
            Ok(expanded)
        } else {
            env::current_dir().map(|cwd| cwd.join(expanded))
        }
    })?)
}

fn sanitize_target(name: &str) -> String {
    let mut out = String::new();
    for ch in name.trim().chars() {
        if ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.') {
            out.push(ch);
        } else {
            out.push('-');
        }
    }
    let out = out.trim_matches('-').to_string();
    if out.is_empty() {
        "default".to_string()
    } else {
        out
    }
}

fn local_pki_target_dir(target_name: &str) -> Result<PathBuf> {
    Ok(default_pki_root_dir()?.join(sanitize_target(target_name)))
}

#[derive(Debug, Clone)]
struct LocalClientPki {
    target_dir: PathBuf,
    ca_cert_path: PathBuf,
    ca_key_path: PathBuf,
    client_cert_path: PathBuf,
    client_key_path: PathBuf,
    ca_cert_pem: Vec<u8>,
}

fn ensure_local_client_pki(target_name: &str) -> Result<LocalClientPki> {
    let target_dir = local_pki_target_dir(target_name)?;
    let pki = LocalClientPki {
        target_dir: target_dir.clone(),
        ca_cert_path: target_dir.join("client-ca.pem"),
        ca_key_path: target_dir.join("client-ca.key"),
        client_cert_path: target_dir.join("client.crt"),
        client_key_path: target_dir.join("client.key"),
        ca_cert_pem: Vec::new(),
    };
    let files = [
        &pki.ca_cert_path,
        &pki.ca_key_path,
        &pki.client_cert_path,
        &pki.client_key_path,
    ];
    let existing = files.iter().filter(|path| path.exists()).count();
    if existing == files.len() {
        let ca_cert_pem = fs::read(&pki.ca_cert_path)
            .with_context(|| format!("read {}", pki.ca_cert_path.display()))?;
        return Ok(LocalClientPki { ca_cert_pem, ..pki });
    }
    if existing > 0 {
        return Err(anyhow!(
            "partial local PKI state detected; remove the target PKI directory and retry"
        ));
    }
    fs::create_dir_all(&target_dir)
        .with_context(|| format!("create target PKI directory {}", target_dir.display()))?;
    let csr_path = target_dir.join("client.csr");
    let ext_path = target_dir.join("client.ext");
    let serial_path = target_dir.join("client-ca.srl");

    run_openssl(&[
        "ecparam",
        "-genkey",
        "-name",
        "prime256v1",
        "-noout",
        "-out",
        &pki.ca_key_path.to_string_lossy(),
    ])?;
    run_openssl(&[
        "req",
        "-x509",
        "-new",
        "-key",
        &pki.ca_key_path.to_string_lossy(),
        "-out",
        &pki.ca_cert_path.to_string_lossy(),
        "-subj",
        "/CN=appcorectl-local-client-ca",
        "-days",
        "3650",
    ])?;
    run_openssl(&[
        "ecparam",
        "-genkey",
        "-name",
        "prime256v1",
        "-noout",
        "-out",
        &pki.client_key_path.to_string_lossy(),
    ])?;
    run_openssl(&[
        "req",
        "-new",
        "-key",
        &pki.client_key_path.to_string_lossy(),
        "-out",
        &csr_path.to_string_lossy(),
        "-subj",
        "/CN=appcorectl-local-client",
    ])?;
    fs::write(
        &ext_path,
        "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n",
    )
    .with_context(|| format!("write {}", ext_path.display()))?;
    run_openssl(&[
        "x509",
        "-req",
        "-in",
        &csr_path.to_string_lossy(),
        "-CA",
        &pki.ca_cert_path.to_string_lossy(),
        "-CAkey",
        &pki.ca_key_path.to_string_lossy(),
        "-CAcreateserial",
        "-out",
        &pki.client_cert_path.to_string_lossy(),
        "-days",
        "730",
        "-sha256",
        "-extfile",
        &ext_path.to_string_lossy(),
    ])?;

    let ca_cert_pem = fs::read(&pki.ca_cert_path)
        .with_context(|| format!("read {}", pki.ca_cert_path.display()))?;
    let _ = fs::remove_file(csr_path);
    let _ = fs::remove_file(ext_path);
    let _ = fs::remove_file(serial_path);

    Ok(LocalClientPki { ca_cert_pem, ..pki })
}

fn pin_server_certificate(target_name: &str, raw_url: &str) -> Result<PathBuf> {
    let parsed = Url::parse(raw_url).context("parse target URL")?;
    if parsed.scheme() != "https" {
        return Err(anyhow!("target URL must use https"));
    }
    let host = parsed
        .host_str()
        .ok_or_else(|| anyhow!("target URL missing hostname"))?;
    let port = parsed
        .port_or_known_default()
        .ok_or_else(|| anyhow!("target URL missing port"))?;
    let addr = format!("{host}:{port}");

    let output = Command::new("openssl")
        .args([
            "s_client",
            "-connect",
            &addr,
            "-servername",
            host,
            "-showcerts",
        ])
        .stdin(Stdio::null())
        .output()
        .context("run openssl s_client")?;
    if !output.status.success() {
        return Err(anyhow!("tls connect to {addr} failed"));
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let begin = stdout
        .find("-----BEGIN CERTIFICATE-----")
        .ok_or_else(|| anyhow!("no peer certificates received from {addr}"))?;
    let end = stdout[begin..]
        .find("-----END CERTIFICATE-----")
        .map(|index| begin + index + "-----END CERTIFICATE-----".len())
        .ok_or_else(|| anyhow!("no peer certificates received from {addr}"))?;
    let pem = &stdout[begin..end];

    let temp_dir = env::temp_dir();
    let temp_cert = temp_dir.join(format!(
        "appcorectl-server-pin-{}.pem",
        sanitize_target(target_name)
    ));
    fs::write(&temp_cert, pem.as_bytes()).context("write temp pinned certificate")?;

    let status = Command::new("openssl")
        .args(["x509", "-in"])
        .arg(&temp_cert)
        .args(["-noout", "-checkhost", host])
        .status()
        .context("verify server certificate hostname")?;
    if !status.success() {
        let _ = fs::remove_file(&temp_cert);
        return Err(anyhow!("server certificate is not valid for {host:?}"));
    }

    let target_dir = local_pki_target_dir(target_name)?;
    fs::create_dir_all(&target_dir)
        .with_context(|| format!("create target PKI directory {}", target_dir.display()))?;
    let ca_path = target_dir.join("server-ca.pem");
    fs::write(&ca_path, pem.as_bytes())
        .with_context(|| format!("write pinned server certificate {}", ca_path.display()))?;
    let _ = fs::remove_file(&temp_cert);
    Ok(ca_path)
}

fn run_openssl(args: &[&str]) -> Result<()> {
    let output = Command::new("openssl")
        .args(args)
        .output()
        .with_context(|| format!("run openssl {args:?}"))?;
    if output.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    Err(anyhow!("openssl {args:?} failed: {stderr}"))
}

fn redact_secret(secret: &str) -> String {
    if secret.is_empty() {
        return String::new();
    }
    if secret.len() <= 4 {
        return "****".to_string();
    }
    format!("{}****{}", &secret[..2], &secret[secret.len() - 2..])
}

fn url_encode(value: &str) -> String {
    url::form_urlencoded::byte_serialize(value.as_bytes()).collect()
}

fn validate_error<M: Into<String>, H: Into<String>>(message: M, hint: H) -> CliError {
    CliError::new(EXIT_VALIDATE, message.into(), Some(hint.into()))
}

fn api_cli_error(err: anyhow::Error) -> CliError {
    CliError::new(
        EXIT_API,
        err.to_string(),
        Some("rerun with corrected parameters or inspect server logs".to_string()),
    )
}

fn io_cli_error(err: io::Error) -> CliError {
    CliError::new(EXIT_API, err.to_string(), None)
}

fn map_client_error(err: ClientError) -> CliError {
    match err {
        ClientError::Api {
            status,
            method,
            path,
            body,
        } => {
            let message = if body.is_empty() {
                format!("API {method} {path} returned status {}", status.as_u16())
            } else {
                format!(
                    "API {method} {path} returned status {}: {body}",
                    status.as_u16()
                )
            };
            if status == StatusCode::UNAUTHORIZED || status == StatusCode::FORBIDDEN {
                CliError::new(
                    EXIT_AUTH,
                    message,
                    Some("verify API key and mTLS client certificate for this target".to_string()),
                )
            } else {
                CliError::new(
                    EXIT_API,
                    message,
                    Some("check server status and endpoint compatibility".to_string()),
                )
            }
        }
        ClientError::Transport(message) => CliError::new(
            EXIT_TRANSPORT,
            message,
            Some("verify target URL, CA/cert files, and network reachability".to_string()),
        ),
    }
}

fn chrono_timestamp() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_else(|_| Duration::from_secs(0))
        .as_secs();
    format!("{now}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, OnceLock};

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn execute(args: &[&str]) -> (String, String, Result<(), CliError>) {
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        let result = execute_args(args.iter().copied(), &mut stdout, &mut stderr);
        (
            String::from_utf8(stdout).unwrap(),
            String::from_utf8(stderr).unwrap(),
            result,
        )
    }

    #[test]
    fn target_add_requires_url() {
        let (_, _, result) = execute(&["appcorectl", "target", "add", "lab"]);
        assert!(result.is_err());
        assert_eq!(result.err().unwrap().code, EXIT_VALIDATE);
    }

    #[test]
    fn host_reboot_requires_yes() {
        let _guard = env_lock().lock().unwrap();
        let home = tempfile::tempdir().unwrap();
        env::set_var("HOME", home.path());
        let config = home.path().join(".config/appcorectl/config.yaml");
        let (_, _, setup) = execute(&[
            "appcorectl",
            "--config",
            &config.to_string_lossy(),
            "target",
            "add",
            "lab",
            "--url",
            "https://host:9090",
            "--insecure",
        ]);
        assert!(setup.is_ok());
        let (_, _, result) = execute(&[
            "appcorectl",
            "--config",
            &config.to_string_lossy(),
            "host",
            "reboot",
        ]);
        assert!(result.is_err());
        assert_eq!(result.err().unwrap().code, EXIT_VALIDATE);
    }

    #[test]
    fn redact_secret_masks_middle() {
        assert_eq!(redact_secret(""), "");
        assert_eq!(redact_secret("abcd"), "****");
        assert_eq!(redact_secret("abcdef"), "ab****ef");
    }

    #[test]
    fn ensure_local_client_pki_creates_files() {
        let _guard = env_lock().lock().unwrap();
        let home = tempfile::tempdir().unwrap();
        env::set_var("HOME", home.path());
        let pki = ensure_local_client_pki("lab").unwrap();
        assert!(pki.ca_cert_path.exists());
        assert!(pki.ca_key_path.exists());
        assert!(pki.client_cert_path.exists());
        assert!(pki.client_key_path.exists());
        assert!(!pki.ca_cert_pem.is_empty());
    }

    #[test]
    fn target_remove_requires_name() {
        let (_, _, result) = execute(&["appcorectl", "target", "rm"]);
        assert!(result.is_err());
        assert_eq!(result.err().unwrap().code, EXIT_VALIDATE);
    }
}
