use serde::{Deserialize, Serialize};
use shared::{info, warn, VERSION, VERSION_STR};
use std::collections::HashMap;
use std::io::Write;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::Path;
use std::sync::{Arc, Mutex};
use warp::Filter;

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ServerInfo {
    name: String,
    player_count: u8,
    max_players: u8,
    description: String,
    map: String,
    port: u16,
    version: (u32, u32),
    #[serde(skip)]
    update_time: Option<std::time::Instant>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ServerList(HashMap<SocketAddr, ServerInfo>);

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(default)]
pub struct MasterConfig {
    pub bind_ip: String,
    pub udp_discovery_port: u16,
    pub http_api_port: u16,
}

impl Default for MasterConfig {
    fn default() -> Self {
        Self {
            bind_ip: "0.0.0.0".to_string(),
            udp_discovery_port: 3691,
            http_api_port: 3692,
        }
    }
}

impl MasterConfig {
    fn load_or_create(path: &Path) -> Self {
        if !path.exists() {
            let default = MasterConfig::default();
            let json = serde_json::to_vec_pretty(&default).unwrap();
            if let Ok(mut file) = std::fs::File::create(path) {
                let _ = file.write_all(&json);
                info!("Created default master config at {}", path.display());
            } else {
                warn!("Failed to create {}. Using in-memory defaults", path.display());
            }
            return default;
        }

        let config_file = match std::fs::File::open(path) {
            Ok(file) => file,
            Err(e) => {
                warn!("Failed to open {}: {}. Using defaults", path.display(), e);
                return MasterConfig::default();
            }
        };

        let reader = std::io::BufReader::new(config_file);
        match serde_json::from_reader(reader) {
            Ok(config) => config,
            Err(e) => {
                warn!("Failed to parse {}: {}. Using defaults", path.display(), e);
                MasterConfig::default()
            }
        }
    }
}

#[tokio::main]
async fn main() {
    shared::init_logging();
    let config_path = Path::new("./config.json");
    let config = MasterConfig::load_or_create(config_path);
    let bind_ip = config
        .bind_ip
        .parse::<IpAddr>()
        .unwrap_or_else(|_| IpAddr::V4(Ipv4Addr::new(0, 0, 0, 0)));
    let udp_addr = SocketAddr::new(bind_ip, config.udp_discovery_port);
    let http_addr = SocketAddr::new(bind_ip, config.http_api_port);

    info!(
        "Starting KissMP master server (version path: {}, udp discovery: {}, http api: {})",
        VERSION_STR,
        udp_addr,
        http_addr
    );

    p2p_server(udp_addr).await;

    let server_list_r = Arc::new(Mutex::new(ServerList(HashMap::new())));
    let addresses_r: Arc<Mutex<HashMap<std::net::IpAddr, HashMap<u16, bool>>>> =
        Arc::new(Mutex::new(HashMap::new()));

    let server_list = server_list_r.clone();
    let addresses = addresses_r.clone();
    let post = warp::post()
        .and(warp::addr::remote())
        .and(warp::body::json())
        .and(warp::path::end())
        .map(move |addr: Option<SocketAddr>, server_info: ServerInfo| {
            let addr = {
                if let Some(addr) = addr {
                    addr
                } else {
                    warn!("Received server announce without remote address");
                    return "err";
                }
            };
            let censor_standart = censor::Censor::Standard;
            let censor_sex = censor::Censor::Sex;
            let mut server_info: ServerInfo = server_info;
            if server_info.version != VERSION {
                warn!(
                    "Rejected server announce from {} due to version mismatch: {:?}",
                    addr, server_info.version
                );
                return "Invalid server version";
            }
            if server_info.description.len() > 256 || server_info.name.len() > 64 {
                return "Server descrition/name length is too big!";
            }
            if censor_standart.check(&server_info.name) || censor_sex.check(&server_info.name) {
                return "Censor!";
            }
            {
                let server_list = &mut *server_list.lock().unwrap();
                let addresses = &mut *addresses.lock().unwrap();
                if let Some(ports) = addresses.get_mut(&addr.ip()) {
                    ports.insert(server_info.port, true);
                    // Limit amount of servers per addr to avoid spam
                    if ports.len() > 10 {
                        return "Too many servers!";
                    }
                } else {
                    addresses.insert(addr.ip(), HashMap::new());
                    addresses
                        .get_mut(&addr.ip())
                        .unwrap()
                        .insert(server_info.port, true);
                }
                let addr = SocketAddr::new(addr.ip(), server_info.port);
                server_info.update_time = Some(std::time::Instant::now());
                info!(
                    "Server announce OK: {} on {} (players: {}/{})",
                    server_info.name, addr, server_info.player_count, server_info.max_players
                );
                server_list.0.insert(addr, server_info);
            }
            return "ok";
        });
    let server_list = server_list_r.clone();
    let addresses = addresses_r.clone();
    let ver = warp::path::param().map(move |ver: String| {
        if ver != VERSION_STR && ver != "latest" {
            warn!("Server list requested with unsupported version path: {}", ver);
            return outdated_ver();
        }
        let server_list = server_list.clone();
        let addresses = addresses.clone();
        {
            let server_list = &mut *server_list.lock().unwrap();
            let addresses = &mut *addresses.lock().unwrap();
            for (k, server) in server_list.0.clone() {
                if server.update_time.unwrap().elapsed().as_secs() > 10 {
                    server_list.0.remove(&k);
                    if let Some(ports) = addresses.get_mut(&k.ip()) {
                        ports.remove(&k.port());
                    }
                }
            }
        }
        let response = {
            let server_list = &mut *server_list.lock().unwrap();
            serde_json::to_string(&server_list).unwrap()
        };
        response
    });
    let outdated = warp::get().map(move || return outdated_ver());
    let routes = post.or(ver).or(outdated);
    info!("Master HTTP endpoint is listening on {}", http_addr);
    warp::serve(routes).run(http_addr).await;
}

async fn p2p_server(bind_addr: SocketAddr) {
    tokio::spawn(async move {
        info!("Master UDP discovery endpoint is listening on {}", bind_addr);
        let mut socket = tokio::net::UdpSocket::bind(bind_addr).await.unwrap();
        loop {
            let mut buf = [0; 16];
            let result = socket.recv_from(&mut buf).await;
            if let Ok((_, src_addr)) = result {
                let _ = socket
                    .send_to(src_addr.to_string().as_bytes(), src_addr)
                    .await;
            }
        }
    });
}

fn outdated_ver() -> String {
    let mut server_list = ServerList(HashMap::with_capacity(5));
    for k in 0..5 {
        server_list.0.insert(SocketAddr::new(std::net::IpAddr::V4(std::net::Ipv4Addr::new(127, 0, 0, 1)), k), ServerInfo {
            name: "You're running an outdated version of KissMP. Please, consider updating to a newer version".to_string(),
            player_count: 0,
            max_players: 0,
            description: "You can find updated version of KissMP on a github releases page".to_string(),
            map: "Update to a newer version of KissMP".to_string(),
            port: 0,
            version: VERSION,
            update_time: None
        });
    }
    serde_json::to_string(&server_list).unwrap()
}
