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
const CANDIDATE_TIMEOUT: Duration = Duration::from_millis(250);
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
            && self.connection_type == ConnType::DEFAULT_CONN
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
    if !policy.allows_lan() || !crate::common::is_valid_untrusted_peer_id(peer) {
        return normal.await;
    }
    let cached = PeerConfig::load(peer)
        .options
        .get(VERIFIED_IDENTITY)
        .cloned();
    let signed = cached
        .and_then(|value| crate::decode64(value).ok())
        .filter(|value| trusted_identity(peer, value, key));
    let Some(signed) = signed else {
        return normal.await;
    };
    let lan = async {
        let started = Instant::now();
        let (stream, pk) = connect_discovered(peer, &signed, key, || {
            private_candidates(peer, &config::LanPeers::load().peers)
        })
        .await?;
        hbb_common::log::info!(
            "Aperture secured LAN connection ready in {:?}",
            started.elapsed()
        );
        Ok((
            (stream, true, Some(pk), None, "TCP"),
            (0, String::new()),
            false,
        ))
    };
    race_lan(lan, normal).await
}

async fn connect_discovered(
    peer: &str,
    signed: &[u8],
    key: &str,
    mut discover: impl FnMut() -> Vec<SocketAddr>,
) -> ResultType<(Stream, Vec<u8>)> {
    let attempt = async {
        let mut attempted = HashSet::new();
        loop {
            for candidate in discover() {
                if attempted.len() >= 8 || !attempted.insert(candidate) {
                    continue;
                }
                if let Ok(Ok(connection)) = tokio::time::timeout(
                    CANDIDATE_TIMEOUT,
                    connect_candidate(peer, candidate, signed, key),
                )
                .await
                {
                    return Ok(connection);
                }
            }
            tokio::time::sleep(Duration::from_millis(60)).await;
        }
    };
    tokio::time::timeout(DISCOVERY_BUDGET, attempt)
        .await
        .map_err(|_| anyhow!("Saved peer is not reachable over secured LAN"))?
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

fn private_candidates(peer: &str, discovered: &[DiscoveryPeer]) -> Vec<SocketAddr> {
    let mut ips: Vec<Ipv4Addr> = discovered
        .iter()
        .filter(|candidate| candidate.id == peer)
        .flat_map(|candidate| candidate.ip_mac.keys())
        .filter_map(|ip| ip.parse::<Ipv4Addr>().ok())
        .filter(Ipv4Addr::is_private)
        .collect();
    ips.sort_unstable();
    ips.dedup();
    ips.into_iter()
        .take(MAX_CANDIDATES)
        .map(|ip| SocketAddr::from((ip, crate::lan::SECURE_LAN_PORT)))
        .collect()
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
                connection_type: ConnType::FILE_TRANSFER,
                ..ordinary()
            },
        ];
        for policy in blocked {
            assert!(!policy.allows_lan());
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
        let candidates = private_candidates(ID, &discovered);
        assert_eq!(candidates.len(), 3);
        assert!(candidates
            .iter()
            .all(|address| address.port() == crate::lan::SECURE_LAN_PORT
                && matches!(address.ip(), std::net::IpAddr::V4(ip) if ip.is_private())));
        assert!(private_candidates("987654321", &discovered).is_empty());
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
        let (mut stream, _) = connect_discovered(ID, &signed, &key, || {
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
