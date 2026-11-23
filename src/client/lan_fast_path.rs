use super::{Client, ConnType, Interface, KcpStream, Stream};
use hbb_common::{
    anyhow::{anyhow, bail},
    config::{self, DiscoveryPeer, PeerConfig},
    socket_client::connect_tcp_local,
    tokio, ResultType,
};
use std::{
    collections::HashSet,
    future::Future,
    net::{Ipv4Addr, SocketAddr},
    time::{Duration, Instant},
};

const VERIFIED_IDENTITY: &str = "aperture-lan-verified-identity";
const LAST_ADDRESS: &str = "aperture-lan-last-address";
const CANDIDATE_TIMEOUT: Duration = Duration::from_millis(250);
const LAN_HEAD_START: Duration = CANDIDATE_TIMEOUT;
const MAX_CANDIDATES: usize = 3;
const DISCOVERY_BUDGET: Duration = Duration::from_millis(750);
type StartOutcome = (
    (
        Stream,
        bool,
        Option<Vec<u8>>,
        Option<KcpStream>,
        &'static str,
    ),
    (i32, String),
    bool,
    // True only when the secured LAN fast path produced the connection.
    bool,
);

struct LanPolicy {
    incoming_only: bool,
    forced_relay: bool,
    custom_server: bool,
    token_bearing: bool,
    switch_back: bool,
    connection_type: ConnType,
}

impl LanPolicy {
    fn allows_lan(&self) -> bool {
        !self.incoming_only
            && !self.forced_relay
            && !self.custom_server
            && !self.token_bearing
            && !self.switch_back
            // Files and terminal too: Aperture has no account, and RustDesk's public server
            // refuses connections without one, so these must not depend on it at home.
            && matches!(
                self.connection_type,
                ConnType::DEFAULT_CONN | ConnType::FILE_TRANSFER | ConnType::TERMINAL
            )
    }
}
pub(super) async fn start(
    peer: &str,
    key: &str,
    token: &str,
    conn_type: ConnType,
    interface: impl Interface,
) -> ResultType<StartOutcome> {
    let normal = Client::_start(peer, key, token, conn_type, interface.clone());
    let custom_server = interface.get_lch().read().unwrap().other_server.is_some();
    let policy = LanPolicy {
        incoming_only: config::is_incoming_only(),
        forced_relay: interface.is_force_relay(),
        custom_server,
        token_bearing: !token.is_empty(),
        switch_back: !interface.get_switch_code().is_empty(),
        connection_type: conn_type,
    };
    let normal = async {
        let (connection, relay, direct_check) = normal.await?;
        Ok((connection, relay, direct_check, false))
    };
    if !policy.allows_lan() || !crate::common::is_valid_untrusted_peer_id(peer) {
        hbb_common::log::info!("Aperture LAN path skipped: connection policy or peer id");
        return normal.await;
    }
    let peer_config = PeerConfig::load(peer);
    let cached = peer_config.options.get(VERIFIED_IDENTITY).cloned();
    let last_address = peer_config
        .options
        .get(LAST_ADDRESS)
        .and_then(|value| value.parse::<SocketAddr>().ok());
    let signed = cached
        .and_then(|value| crate::decode64(value).ok())
        .filter(|value| trusted_identity(peer, value, key));
    let Some(signed) = signed else {
        hbb_common::log::info!("Aperture LAN path skipped: no verified identity saved for this peer");
        return normal.await;
    };
    let lan = async {
        let started = Instant::now();
        let (stream, pk, address) = connect_discovered(peer, &signed, key, || {
            private_candidates(peer, &config::LanPeers::load().peers, last_address)
        })
        .await
        .map_err(|err| {
            hbb_common::log::info!(
                "Aperture LAN path failed after {:?}: {err}",
                started.elapsed()
            );
            err
        })?;
        remember_lan_address(peer, address);
        hbb_common::log::info!(
            "Aperture secured LAN connection ready in {:?}",
            started.elapsed()
        );
        Ok((
            (stream, true, Some(pk), None, "TCP"),
            (0, String::new()),
            false,
            true,
        ))
    };
    race_lan(lan, normal).await
}

async fn connect_discovered(
    peer: &str,
    signed: &[u8],
    key: &str,
    mut discover: impl FnMut() -> Vec<SocketAddr>,
) -> ResultType<(Stream, Vec<u8>, SocketAddr)> {
    let attempt = async {
        let mut attempted = HashSet::new();
        loop {
            for candidate in discover() {
                if attempted.len() >= 8 || !attempted.insert(candidate) {
                    continue;
                }
                match tokio::time::timeout(
                    CANDIDATE_TIMEOUT,
                    connect_candidate(peer, candidate, signed, key),
                )
                .await
                {
                    Ok(Ok(connection)) => return Ok((connection.0, connection.1, candidate)),
                    // At most 8 candidates per connection, so this stays bounded.
                    Ok(Err(err)) => {
                        hbb_common::log::info!("Aperture LAN candidate {candidate} failed: {err}")
                    }
                    Err(_) => hbb_common::log::info!(
                        "Aperture LAN candidate {candidate} timed out after {:?}",
                        CANDIDATE_TIMEOUT
                    ),
                }
            }
            tokio::time::sleep(Duration::from_millis(60)).await;
        }
    };
    match tokio::time::timeout(DISCOVERY_BUDGET, attempt).await {
        Ok(result) => result,
        Err(_) => bail!(
            "Saved peer is not reachable over secured LAN ({} candidate(s) known)",
            discover().len()
        ),
    }
}
fn trusted_identity(peer: &str, signed: &[u8], key: &str) -> bool {
    if signed.is_empty() || signed.len() > 4096 {
        return false;
    }
    let root = if key.is_empty() {
        config::RS_PUB_KEY
    } else {
        key
    };
    crate::get_rs_pk(root)
        .and_then(|root| crate::decode_id_pk(signed, &root).ok())
        .map(|(id, _)| id == peer)
        .unwrap_or(false)
}

pub(super) fn remember_verified_peer(peer: &str, signed: &[u8], key: &str, secured: bool) {
    if !secured || !trusted_identity(peer, signed, key) {
        return;
    }
    let value = crate::encode64(signed);
    let mut config = PeerConfig::load(peer);
    if config.options.get(VERIFIED_IDENTITY) == Some(&value) {
        return;
    }
    config.options.insert(VERIFIED_IDENTITY.to_owned(), value);
    config.store(peer);
}

fn storable_address(address: SocketAddr) -> bool {
    matches!(address, SocketAddr::V4(v4)
        if v4.ip().is_private() && v4.port() == crate::lan::SECURE_LAN_PORT)
}

// Called only after the candidate's identity was verified and its stream secured.
fn remember_lan_address(peer: &str, address: SocketAddr) {
    if !storable_address(address) {
        return;
    }
    let value = address.to_string();
    let mut config = PeerConfig::load(peer);
    if config.options.get(LAST_ADDRESS) == Some(&value) {
        return;
    }
    config.options.insert(LAST_ADDRESS.to_owned(), value);
    config.store(peer);
}

fn private_candidates(
    peer: &str,
    discovered: &[DiscoveryPeer],
    last: Option<SocketAddr>,
) -> Vec<SocketAddr> {
    let mut ips: Vec<Ipv4Addr> = discovered
        .iter()
        .filter(|candidate| candidate.id == peer)
        .flat_map(|candidate| candidate.ip_mac.keys())
        .filter_map(|ip| ip.parse::<Ipv4Addr>().ok())
        .filter(Ipv4Addr::is_private)
        .collect();
    ips.sort_unstable();
    ips.dedup();
    let mut candidates: Vec<SocketAddr> = ips
        .into_iter()
        .take(MAX_CANDIDATES)
        .map(|ip| SocketAddr::from((ip, crate::lan::SECURE_LAN_PORT)))
        .collect();
    if let Some(last) = last.filter(|last| storable_address(*last)) {
        if !candidates.contains(&last) {
            candidates.push(last);
        }
    }
    candidates.truncate(MAX_CANDIDATES);
    candidates
}

async fn connect_candidate(
    peer: &str,
    address: SocketAddr,
    signed: &[u8],
    key: &str,
) -> ResultType<(Stream, Vec<u8>)> {
    if !trusted_identity(peer, signed, key) {
        bail!("No verified saved peer identity");
    }
    let mut stream = connect_tcp_local(address, None, 200).await?;
    stream.set_max_packet_length(64 * 1024);
    let pk = Client::secure_connection(peer, signed.to_vec(), key, &mut stream).await?;
    if !stream.is_secured() {
        bail!("LAN peer did not establish verified encryption");
    }
    let pk = pk.ok_or_else(|| anyhow!("LAN peer identity was not verified"))?;
    stream.set_max_packet_length(usize::MAX);
    Ok((stream, pk))
}

pub(super) async fn race_lan<T>(
    lan: impl Future<Output = ResultType<T>>,
    normal: impl Future<Output = ResultType<T>>,
) -> ResultType<T> {
    tokio::pin!(lan, normal);
    // The normal route reaches the public rendezvous server, NAT test and STUN
    // servers. Give the home path a head start so a working one never touches them.
    tokio::select! {
        biased;
        result = &mut lan => return match result {
            Ok(value) => Ok(value),
            Err(_) => normal.await,
        },
        _ = tokio::time::sleep(LAN_HEAD_START) => {}
    }
    tokio::select! {
        biased;
        result = &mut lan => match result {
            Ok(value) => Ok(value),
            Err(_) => normal.await,
        },
        result = &mut normal => match result {
            Ok(value) => Ok(value),
            Err(normal_error) => lan.await.or(Err(normal_error)),
        },
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use hbb_common::anyhow::anyhow;
    use std::time::Duration;

    #[test]
    fn lan_cannot_bypass_connection_policy() {
        let ordinary = || LanPolicy {
            incoming_only: false,
            forced_relay: false,
            custom_server: false,
            token_bearing: false,
            switch_back: false,
            connection_type: ConnType::DEFAULT_CONN,
        };
        assert!(ordinary().allows_lan());
        let blocked = [
            LanPolicy {
                incoming_only: true,
                ..ordinary()
            },
            LanPolicy {
                forced_relay: true,
                ..ordinary()
            },
            LanPolicy {
                custom_server: true,
                ..ordinary()
            },
            LanPolicy {
                token_bearing: true,
                ..ordinary()
            },
            LanPolicy {
                switch_back: true,
                ..ordinary()
            },
            LanPolicy {
                connection_type: ConnType::PORT_FORWARD,
                ..ordinary()
            },
            LanPolicy {
                connection_type: ConnType::RDP,
                ..ordinary()
            },
            LanPolicy {
                connection_type: ConnType::VIEW_CAMERA,
                ..ordinary()
            },
        ];
        for policy in blocked {
            assert!(!policy.allows_lan());
        }
    }
    #[test]
    fn lan_allows_file_transfer_and_terminal() {
        for connection_type in [ConnType::FILE_TRANSFER, ConnType::TERMINAL] {
            let policy = LanPolicy {
                incoming_only: false,
                forced_relay: false,
                custom_server: false,
                token_bearing: false,
                switch_back: false,
                connection_type,
            };
            assert!(policy.allows_lan(), "{connection_type:?}");
        }
    }

    #[tokio::test]
    async fn ready_lan_wins_without_waiting_for_rendezvous() {
        let result = race_lan(async { Ok("lan") }, async {
            tokio::time::sleep(Duration::from_millis(30)).await;
            Ok("rendezvous")
        })
        .await
        .unwrap();
        assert_eq!(result, "lan");
    }

    #[tokio::test]
    async fn failed_lan_preserves_normal_connection() {
        let result = race_lan(async { Err(anyhow!("unreachable LAN")) }, async {
            Ok("rendezvous")
        })
        .await
        .unwrap();
        assert_eq!(result, "rendezvous");
    }

    #[tokio::test]
    async fn offline_rendezvous_does_not_cancel_working_lan() {
        let result = race_lan(
            async {
                tokio::time::sleep(Duration::from_millis(10)).await;
                Ok("lan")
            },
            async { Err(anyhow!("rendezvous offline")) },
        )
        .await;
        assert_eq!(result.unwrap(), "lan");
    }

    #[tokio::test]
    async fn normal_error_is_preserved_when_both_routes_fail() {
        let result: ResultType<()> = race_lan(async { Err(anyhow!("LAN failed")) }, async {
            Err(anyhow!("normal route failed"))
        })
        .await;
        assert_eq!(result.unwrap_err().to_string(), "normal route failed");
    }

    // At home the secured LAN path answers in ~40 ms; the public rendezvous
    // server, NAT test and STUN servers should not be contacted at all then.
    #[tokio::test]
    async fn working_home_path_never_starts_the_public_route() {
        let started = std::sync::atomic::AtomicBool::new(false);
        let result = race_lan(
            async {
                tokio::time::sleep(Duration::from_millis(20)).await;
                Ok("lan")
            },
            async {
                started.store(true, std::sync::atomic::Ordering::SeqCst);
                Ok("rendezvous")
            },
        )
        .await;
        assert_eq!(result.unwrap(), "lan");
        assert!(!started.load(std::sync::atomic::Ordering::SeqCst));
    }

    #[tokio::test]
    async fn slow_home_path_does_not_hold_back_the_public_route() {
        let begun = std::time::Instant::now();
        let result = race_lan(
            async {
                tokio::time::sleep(Duration::from_secs(3)).await;
                Ok("lan")
            },
            async { Ok("rendezvous") },
        )
        .await;
        assert_eq!(result.unwrap(), "rendezvous");
        assert!(begun.elapsed() < Duration::from_secs(1));
    }
}
#[cfg(test)]
mod identity_tests {
    use super::*;
    use base::message_proto::{self, Message, SignedId, TestDelay};
    use hbb_common::rendezvous_proto::IdPk;
    use hbb_common::{
        protobuf::Message as _,
        sodiumoxide::{
            self,
            crypto::{box_, sign},
        },
        tcp::{Encrypt, KxTranscript, KX_VERSION_LATEST},
        tokio::sync::oneshot,
    };
    use std::collections::HashMap;

    const ID: &str = "123456789";

    fn identity(pk: &[u8], kx_version: u32) -> Vec<u8> {
        IdPk {
            id: ID.to_owned(),
            pk: pk.to_vec().into(),
            kx_version,
            ..Default::default()
        }
        .write_to_bytes()
        .unwrap()
    }

    #[test]
    fn discovery_uses_saved_id_private_ipv4_and_bounded_candidates() {
        let discovered = vec![DiscoveryPeer {
            id: ID.to_owned(),
            ip_mac: [
                "10.0.4.93",
                "192.168.1.2",
                "172.16.0.2",
                "10.1.1.1",
                "8.8.8.8",
                "127.0.0.1",
                "::1",
            ]
            .into_iter()
            .map(|ip| (ip.to_owned(), String::new()))
            .collect::<HashMap<_, _>>(),
            ..Default::default()
        }];
        let candidates = private_candidates(ID, &discovered, None);
        assert_eq!(candidates.len(), 3);
        assert!(candidates
            .iter()
            .all(|address| address.port() == crate::lan::SECURE_LAN_PORT
                && matches!(address.ip(), std::net::IpAddr::V4(ip) if ip.is_private())));
        assert!(private_candidates("987654321", &discovered, None).is_empty());
    }

    #[test]
    fn cached_identity_must_match_saved_peer_and_configured_root() {
        sodiumoxide::init().unwrap();
        let (root, signing_root) = sign::gen_keypair();
        let (peer, _) = sign::gen_keypair();
        let signed = sign::sign(&identity(&peer.0, 0), &signing_root);
        let key = crate::encode64(root.0);
        assert!(trusted_identity(ID, &signed, &key));
        assert!(!trusted_identity("987654321", &signed, &key));
        let (other_root, _) = sign::gen_keypair();
        assert!(!trusted_identity(
            ID,
            &signed,
            &crate::encode64(other_root.0)
        ));
        assert!(!trusted_identity(ID, &[], &key));
    }

    async fn controlled_peer(
        plain: bool,
        wrong_signer: bool,
    ) -> (SocketAddr, Vec<u8>, String, oneshot::Receiver<bool>) {
        sodiumoxide::init().unwrap();
        let (root, root_secret) = sign::gen_keypair();
        let (host, host_secret) = sign::gen_keypair();
        let signed = sign::sign(&identity(&host.0, 0), &root_secret);
        let listener = hbb_common::tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .unwrap();
        let address = listener.local_addr().unwrap();
        let (tx, rx) = oneshot::channel();
        tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let mut stream = Stream::from(socket, address);
            let (ephemeral, ephemeral_secret) = box_::gen_keypair();
            let mut message = Message::new();
            if plain {
                message.set_hash(Default::default());
            } else {
                let signing_secret = if wrong_signer {
                    sign::gen_keypair().1
                } else {
                    host_secret
                };
                message.set_signed_id(SignedId {
                    id: sign::sign(&identity(&ephemeral.0, KX_VERSION_LATEST), &signing_secret)
                        .into(),
                    ..Default::default()
                });
            }
            stream.send(&message).await.unwrap();
            let received = tokio::time::timeout(Duration::from_millis(500), stream.next()).await;
            let public_key = match received {
                Ok(Some(Ok(bytes))) => {
                    Message::parse_from_bytes(&bytes)
                        .ok()
                        .and_then(|message| match message.union {
                            Some(message_proto::message::Union::PublicKey(key))
                                if !key.asymmetric_value.is_empty() =>
                            {
                                Some(key)
                            }
                            _ => None,
                        })
                }
                _ => None,
            };
            let Some(public_key) = public_key else {
                let _ = tx.send(false);
                return;
            };
            let key = Encrypt::decode(
                &public_key.symmetric_value,
                &public_key.asymmetric_value,
                &ephemeral_secret,
            )
            .unwrap();
            stream
                .set_negotiated_key(
                    key,
                    false,
                    &KxTranscript {
                        initiator_pk: &public_key.asymmetric_value,
                        responder_pk: &ephemeral.0,
                        advertised: KX_VERSION_LATEST,
                        picked: public_key.kx_version,
                    },
                )
                .unwrap();
            let mut response = Message::new();
            response.set_test_delay(TestDelay {
                time: 2,
                ..Default::default()
            });
            stream.send(&response).await.unwrap();
            let received = tokio::time::timeout(Duration::from_millis(500), stream.next()).await;
            let decrypted = matches!(received, Ok(Some(Ok(bytes))) if matches!(
                Message::parse_from_bytes(&bytes).unwrap().union,
                Some(message_proto::message::Union::TestDelay(delay)) if delay.time == 1));
            let _ = tx.send(decrypted);
        });
        (address, signed, crate::encode64(root.0), rx)
    }

    fn stored(text: &str) -> Option<SocketAddr> {
        Some(text.parse().unwrap())
    }

    fn discovered_with(ips: &[&str]) -> Vec<DiscoveryPeer> {
        vec![DiscoveryPeer {
            id: ID.to_owned(),
            ip_mac: ips
                .iter()
                .map(|ip| ((*ip).to_owned(), String::new()))
                .collect::<HashMap<_, _>>(),
            ..Default::default()
        }]
    }

    #[test]
    fn stored_address_is_tried_when_discovery_is_empty() {
        assert_eq!(
            private_candidates(ID, &[], stored("10.0.4.93:21120")),
            vec!["10.0.4.93:21120".parse::<SocketAddr>().unwrap()]
        );
    }

    #[test]
    fn stored_address_not_duplicated_and_respects_cap() {
        let one = discovered_with(&["10.0.4.93"]);
        assert_eq!(
            private_candidates(ID, &one, stored("10.0.4.93:21120")).len(),
            1
        );
        let two = discovered_with(&["10.0.4.1", "10.0.4.2"]);
        let with_last = private_candidates(ID, &two, stored("10.0.4.93:21120"));
        assert_eq!(with_last.len(), 3);
        assert_eq!(with_last[2], "10.0.4.93:21120".parse().unwrap());
        let full = discovered_with(&["10.0.4.1", "10.0.4.2", "10.0.4.3"]);
        let capped = private_candidates(ID, &full, stored("10.0.4.93:21120"));
        assert_eq!(capped.len(), MAX_CANDIDATES);
        assert!(!capped.contains(&"10.0.4.93:21120".parse().unwrap()));
    }

    #[test]
    fn public_or_wrong_port_stored_address_ignored() {
        assert!(private_candidates(ID, &[], stored("8.8.8.8:21120")).is_empty());
        assert!(private_candidates(ID, &[], stored("10.0.4.93:21118")).is_empty());
        assert!(private_candidates(ID, &[], stored("[::1]:21120")).is_empty());
    }

    #[tokio::test]
    async fn stored_address_with_wrong_identity_is_rejected() {
        let (address, signed, key, received) = controlled_peer(false, true).await;
        let result = connect_discovered(ID, &signed, &key, || vec![address]).await;
        assert!(result.is_err());
        assert!(!received.await.unwrap());
    }

    #[tokio::test]
    async fn successful_connection_reports_the_address_that_won() {
        let (address, signed, key, received) = controlled_peer(false, false).await;
        let (_, _, won) = connect_discovered(ID, &signed, &key, || vec![address])
            .await
            .unwrap();
        assert_eq!(won, address);
        drop(received);
    }

    #[test]
    fn remembered_address_requires_private_secure_lan_port() {
        assert!(storable_address("10.0.4.93:21120".parse().unwrap()));
        assert!(!storable_address("8.8.8.8:21120".parse().unwrap()));
        assert!(!storable_address("10.0.4.93:21118".parse().unwrap()));
    }

    #[tokio::test]
    async fn lan_candidate_authenticates_and_encrypts_application_bytes() {
        let (address, signed, key, received) = controlled_peer(false, false).await;
        let (mut stream, pk) = connect_candidate(ID, address, &signed, &key).await.unwrap();
        assert!(stream.is_secured());
        assert_eq!(pk.len(), 32);
        let mut message = Message::new();
        message.set_test_delay(TestDelay {
            time: 1,
            ..Default::default()
        });
        stream.send(&message).await.unwrap();
        let response = stream.next().await.unwrap().unwrap();
        assert!(
            matches!(Message::parse_from_bytes(&response).unwrap().union,
            Some(message_proto::message::Union::TestDelay(delay)) if delay.time == 2)
        );
        assert!(received.await.unwrap());
    }

    #[tokio::test]
    async fn wrong_host_key_is_rejected_before_application_data() {
        let (address, signed, key, received) = controlled_peer(false, true).await;
        assert!(connect_candidate(ID, address, &signed, &key).await.is_err());
        assert!(!received.await.unwrap());
    }

    #[tokio::test]
    async fn legacy_unsecured_listener_is_rejected_before_application_data() {
        let (address, signed, key, received) = controlled_peer(true, false).await;
        assert!(connect_candidate(ID, address, &signed, &key).await.is_err());
        assert!(!received.await.unwrap());
    }
    #[tokio::test]
    async fn fresh_discovery_can_arrive_after_connection_starts() {
        let (address, signed, key, received) = controlled_peer(false, false).await;
        let started = Instant::now();
        let (mut stream, _, _) = connect_discovered(ID, &signed, &key, || {
            if started.elapsed() < Duration::from_millis(30) {
                vec![]
            } else {
                vec![address]
            }
        })
        .await
        .unwrap();
        let mut message = Message::new();
        message.set_test_delay(TestDelay {
            time: 1,
            ..Default::default()
        });
        stream.send(&message).await.unwrap();
        assert!(received.await.unwrap());
        assert!(started.elapsed() < DISCOVERY_BUDGET);
    }

    #[tokio::test]
    async fn missing_discovery_has_a_bounded_startup_budget() {
        let started = Instant::now();
        let result = connect_discovered(ID, &[], "", Vec::new).await;
        assert!(result.is_err());
        assert!(started.elapsed() < Duration::from_secs(2));
    }
}
