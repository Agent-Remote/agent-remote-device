use std::{sync::Arc, time::Duration};

use hmac::{Hmac, Mac};
use rcgen::{
    CertificateParams, DistinguishedName, DnType, KeyPair, PublicKeyData, PKCS_ECDSA_P256_SHA256,
};
use rustls::{
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    crypto::{verify_tls12_signature, verify_tls13_signature, CryptoProvider},
    pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime},
    server::danger::{ClientCertVerified, ClientCertVerifier},
    CertificateError, ClientConfig, ClientConnection, DigitallySignedStruct,
    DistinguishedName as RustlsDistinguishedName, Error as RustlsError, ServerConfig,
    ServerConnection, SignatureScheme,
};
use sha2::{Digest, Sha256};
use thiserror::Error;
use time::OffsetDateTime;
use x509_parser::parse_x509_certificate;

use crate::protocol::MAX_ACTIVE_DEVICE_SESSION_GENERATION;

pub const EXPORTER_LABEL: &[u8] = b"EXPORTER-agent-remote-device-v1";
pub const EXPORTER_CONTEXT_BYTES: usize = 32;
pub const EXPORTER_OUTPUT_BYTES: usize = 32;
pub const CONFIRMATION_RECORD_BYTES: usize = 34;
pub const MAXIMUM_GENERATION_LIFETIME: Duration = Duration::from_secs(15 * 60);

const CONFIRMATION_LABEL: &[u8] = b"agent-remote-device-exporter-confirm-v1";
const CONFIRMATION_VERSION: u8 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum NestedTlsRole {
    Device = 1,
    Proxy = 2,
}

impl NestedTlsRole {
    pub fn peer(self) -> Self {
        match self {
            Self::Device => Self::Proxy,
            Self::Proxy => Self::Device,
        }
    }
}

#[derive(Debug)]
pub struct GenerationIdentity {
    pub certificate_der: CertificateDer<'static>,
    pub private_key_der: PrivatePkcs8KeyDer<'static>,
    pub spki_sha256: [u8; 32],
}

impl GenerationIdentity {
    pub fn generate() -> Result<Self, NestedTlsError> {
        let key_pair = KeyPair::generate_for(&PKCS_ECDSA_P256_SHA256)?;
        let mut params = CertificateParams::new(Vec::<String>::new())?;
        let now = OffsetDateTime::now_utc();
        params.not_before = now - time::Duration::seconds(30);
        params.not_after =
            now + time::Duration::seconds(MAXIMUM_GENERATION_LIFETIME.as_secs() as i64);
        let mut distinguished_name = DistinguishedName::new();
        distinguished_name.push(DnType::CommonName, "agent-remote-device-generation");
        params.distinguished_name = distinguished_name;
        let certificate = params.self_signed(&key_pair)?;
        let spki_sha256 = Sha256::digest(key_pair.subject_public_key_info()).into();

        Ok(Self {
            certificate_der: certificate.der().clone(),
            private_key_der: PrivatePkcs8KeyDer::from(key_pair.serialize_der()),
            spki_sha256,
        })
    }

    pub fn spki_sha256_hex(&self) -> String {
        hex::encode(self.spki_sha256)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GenerationMaterial {
    pub generation: u64,
    pub expected_peer_spki_sha256: [u8; 32],
    pub exporter_context: [u8; EXPORTER_CONTEXT_BYTES],
}

impl GenerationMaterial {
    pub fn from_hex(
        generation: u64,
        expected_peer_spki_sha256: &str,
        exporter_context: &str,
    ) -> Result<Self, NestedTlsError> {
        if generation == 0 || generation > MAX_ACTIVE_DEVICE_SESSION_GENERATION {
            return Err(NestedTlsError::InvalidGeneration);
        }
        Ok(Self {
            generation,
            expected_peer_spki_sha256: decode_fixed_hex(expected_peer_spki_sha256)?,
            exporter_context: decode_fixed_hex(exporter_context)?,
        })
    }
}

pub fn client_config(
    identity: &GenerationIdentity,
    material: &GenerationMaterial,
) -> Result<ClientConfig, NestedTlsError> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let verifier = Arc::new(PinnedServerVerifier {
        expected_spki_sha256: material.expected_peer_spki_sha256,
        provider: Arc::clone(&provider),
    });
    ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_client_auth_cert(
            vec![identity.certificate_der.clone()],
            PrivateKeyDer::Pkcs8(identity.private_key_der.clone_key()),
        )
        .map_err(NestedTlsError::Tls)
}

pub fn client_connection(config: ClientConfig) -> Result<ClientConnection, NestedTlsError> {
    ClientConnection::new(
        Arc::new(config),
        ServerName::try_from("agent-remote-device.invalid")?,
    )
    .map_err(NestedTlsError::Tls)
}

pub fn server_config(
    identity: &GenerationIdentity,
    material: &GenerationMaterial,
) -> Result<ServerConfig, NestedTlsError> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let verifier = Arc::new(PinnedClientVerifier {
        expected_spki_sha256: material.expected_peer_spki_sha256,
        provider: Arc::clone(&provider),
        root_hints: Vec::new(),
    });
    ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_client_cert_verifier(verifier)
        .with_single_cert(
            vec![identity.certificate_der.clone()],
            PrivateKeyDer::Pkcs8(identity.private_key_der.clone_key()),
        )
        .map_err(NestedTlsError::Tls)
}

pub fn server_connection(config: ServerConfig) -> Result<ServerConnection, NestedTlsError> {
    ServerConnection::new(Arc::new(config)).map_err(NestedTlsError::Tls)
}

pub fn exporter_binding(
    connection: &ClientConnection,
    material: &GenerationMaterial,
) -> Result<[u8; EXPORTER_OUTPUT_BYTES], NestedTlsError> {
    if connection.is_handshaking() {
        return Err(NestedTlsError::HandshakeIncomplete);
    }
    let mut output = [0_u8; EXPORTER_OUTPUT_BYTES];
    connection
        .export_keying_material(
            &mut output,
            EXPORTER_LABEL,
            Some(&material.exporter_context),
        )
        .map_err(NestedTlsError::Tls)?;
    Ok(output)
}

pub fn server_exporter_binding(
    connection: &ServerConnection,
    material: &GenerationMaterial,
) -> Result<[u8; EXPORTER_OUTPUT_BYTES], NestedTlsError> {
    if connection.is_handshaking() {
        return Err(NestedTlsError::HandshakeIncomplete);
    }
    let mut output = [0_u8; EXPORTER_OUTPUT_BYTES];
    connection
        .export_keying_material(
            &mut output,
            EXPORTER_LABEL,
            Some(&material.exporter_context),
        )
        .map_err(NestedTlsError::Tls)?;
    Ok(output)
}

pub fn confirmation_record(
    exporter_binding: &[u8; EXPORTER_OUTPUT_BYTES],
    role: NestedTlsRole,
    generation: u64,
    device_session_id: uuid::Uuid,
) -> [u8; CONFIRMATION_RECORD_BYTES] {
    let transcript = confirmation_transcript(role, generation, device_session_id);
    let mut mac = Hmac::<Sha256>::new_from_slice(exporter_binding)
        .expect("the fixed exporter size is a valid HMAC key");
    mac.update(&transcript);
    let tag = mac.finalize().into_bytes();
    let mut record = [0_u8; CONFIRMATION_RECORD_BYTES];
    record[0] = CONFIRMATION_VERSION;
    record[1] = role as u8;
    record[2..].copy_from_slice(&tag);
    record
}

pub fn verify_peer_confirmation(
    record: &[u8],
    exporter_binding: &[u8; EXPORTER_OUTPUT_BYTES],
    local_role: NestedTlsRole,
    generation: u64,
    device_session_id: uuid::Uuid,
) -> Result<(), NestedTlsError> {
    let expected_role = local_role.peer();
    if record.len() != CONFIRMATION_RECORD_BYTES
        || record[0] != CONFIRMATION_VERSION
        || record[1] != expected_role as u8
    {
        return Err(NestedTlsError::ExporterConfirmation);
    }
    let transcript = confirmation_transcript(expected_role, generation, device_session_id);
    let mut mac = Hmac::<Sha256>::new_from_slice(exporter_binding)
        .expect("the fixed exporter size is a valid HMAC key");
    mac.update(&transcript);
    mac.verify_slice(&record[2..])
        .map_err(|_| NestedTlsError::ExporterConfirmation)
}

fn confirmation_transcript(
    role: NestedTlsRole,
    generation: u64,
    device_session_id: uuid::Uuid,
) -> Vec<u8> {
    let mut transcript = Vec::with_capacity(CONFIRMATION_LABEL.len() + 27);
    transcript.extend_from_slice(CONFIRMATION_LABEL);
    transcript.push(0);
    transcript.push(CONFIRMATION_VERSION);
    transcript.push(role as u8);
    transcript.extend_from_slice(&generation.to_be_bytes());
    transcript.extend_from_slice(device_session_id.as_bytes());
    transcript
}

#[derive(Debug)]
struct PinnedServerVerifier {
    expected_spki_sha256: [u8; 32],
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for PinnedServerVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, RustlsError> {
        verify_pinned_certificate(end_entity, intermediates, self.expected_spki_sha256)?;
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, RustlsError> {
        verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, RustlsError> {
        verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

#[derive(Debug)]
struct PinnedClientVerifier {
    expected_spki_sha256: [u8; 32],
    provider: Arc<CryptoProvider>,
    root_hints: Vec<RustlsDistinguishedName>,
}

impl ClientCertVerifier for PinnedClientVerifier {
    fn root_hint_subjects(&self) -> &[RustlsDistinguishedName] {
        &self.root_hints
    }

    fn verify_client_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        _now: UnixTime,
    ) -> Result<ClientCertVerified, RustlsError> {
        verify_pinned_certificate(end_entity, intermediates, self.expected_spki_sha256)?;
        Ok(ClientCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, RustlsError> {
        verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, RustlsError> {
        verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

#[derive(Debug, Error)]
pub enum NestedTlsError {
    #[error("nested TLS generation must be non-zero")]
    InvalidGeneration,
    #[error("nested TLS material must be exact lowercase hexadecimal")]
    InvalidHexMaterial,
    #[error("ephemeral certificate generation failed")]
    Certificate(#[from] rcgen::Error),
    #[error("nested TLS server name is invalid")]
    ServerName(#[from] rustls::pki_types::InvalidDnsNameError),
    #[error("nested TLS operation failed")]
    Tls(#[from] RustlsError),
    #[error("nested TLS exporter requested before handshake completion")]
    HandshakeIncomplete,
    #[error("nested TLS exporter confirmation failed")]
    ExporterConfirmation,
}

fn pin_mismatch() -> RustlsError {
    RustlsError::InvalidCertificate(CertificateError::ApplicationVerificationFailure)
}

fn verify_pinned_certificate(
    end_entity: &CertificateDer<'_>,
    intermediates: &[CertificateDer<'_>],
    expected_spki_sha256: [u8; 32],
) -> Result<(), RustlsError> {
    if !intermediates.is_empty() {
        return Err(pin_mismatch());
    }
    let (remainder, certificate) =
        parse_x509_certificate(end_entity.as_ref()).map_err(|_| pin_mismatch())?;
    if !remainder.is_empty() || !certificate.validity().is_valid() {
        return Err(pin_mismatch());
    }
    let actual: [u8; 32] = Sha256::digest(certificate.tbs_certificate.subject_pki.raw).into();
    if actual != expected_spki_sha256 {
        return Err(pin_mismatch());
    }
    Ok(())
}

fn decode_fixed_hex<const N: usize>(value: &str) -> Result<[u8; N], NestedTlsError> {
    if value.len() != N * 2
        || !value
            .as_bytes()
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
    {
        return Err(NestedTlsError::InvalidHexMaterial);
    }
    let decoded = hex::decode(value).map_err(|_| NestedTlsError::InvalidHexMaterial)?;
    decoded
        .try_into()
        .map_err(|_| NestedTlsError::InvalidHexMaterial)
}

#[cfg(test)]
mod tests {
    use std::{os::unix::net::UnixStream, thread};

    use super::*;

    #[test]
    fn each_generation_uses_a_distinct_p256_identity() {
        let first = GenerationIdentity::generate().expect("first identity");
        let second = GenerationIdentity::generate().expect("second identity");

        assert_ne!(first.certificate_der, second.certificate_der);
        assert_ne!(first.spki_sha256, second.spki_sha256);
        assert_eq!(first.spki_sha256_hex().len(), 64);
        assert!(first
            .spki_sha256_hex()
            .bytes()
            .all(|byte| { byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte) }));
    }

    #[test]
    fn generation_material_rejects_wrong_length_case_and_generation() {
        let valid = "ab".repeat(32);
        assert!(GenerationMaterial::from_hex(1, &valid, &valid).is_ok());
        assert!(matches!(
            GenerationMaterial::from_hex(0, &valid, &valid),
            Err(NestedTlsError::InvalidGeneration)
        ));
        assert!(matches!(
            GenerationMaterial::from_hex(i64::MAX as u64, &valid, &valid),
            Err(NestedTlsError::InvalidGeneration)
        ));
        assert!(matches!(
            GenerationMaterial::from_hex(1, &valid.to_uppercase(), &valid),
            Err(NestedTlsError::InvalidHexMaterial)
        ));
        assert!(matches!(
            GenerationMaterial::from_hex(1, &valid[..62], &valid),
            Err(NestedTlsError::InvalidHexMaterial)
        ));
    }

    #[test]
    fn mutual_tls13_handshake_pins_both_peers_and_matches_exporter() {
        let client_identity = GenerationIdentity::generate().expect("client identity");
        let server_identity = GenerationIdentity::generate().expect("server identity");
        let context = "cd".repeat(EXPORTER_CONTEXT_BYTES);
        let client_material =
            GenerationMaterial::from_hex(7, &server_identity.spki_sha256_hex(), &context)
                .expect("client material");
        let server_material =
            GenerationMaterial::from_hex(7, &client_identity.spki_sha256_hex(), &context)
                .expect("server material");
        let client_config =
            client_config(&client_identity, &client_material).expect("client config");
        let server_config =
            server_config(&server_identity, &server_material).expect("server config");
        let (mut client_io, mut server_io) = UnixStream::pair().expect("stream pair");
        client_io
            .set_read_timeout(Some(Duration::from_secs(2)))
            .expect("client timeout");
        server_io
            .set_read_timeout(Some(Duration::from_secs(2)))
            .expect("server timeout");

        let server = thread::spawn(move || {
            let mut connection = server_connection(server_config).expect("server connection");
            while connection.is_handshaking() {
                connection
                    .complete_io(&mut server_io)
                    .expect("server handshake");
            }
            assert_eq!(
                connection.protocol_version(),
                Some(rustls::ProtocolVersion::TLSv1_3)
            );
            server_exporter_binding(&connection, &server_material).expect("server exporter")
        });

        let mut connection = client_connection(client_config).expect("client connection");
        while connection.is_handshaking() {
            connection
                .complete_io(&mut client_io)
                .expect("client handshake");
        }
        assert_eq!(
            connection.protocol_version(),
            Some(rustls::ProtocolVersion::TLSv1_3)
        );
        let client_exporter =
            exporter_binding(&connection, &client_material).expect("client exporter");
        assert_eq!(client_exporter, server.join().expect("server thread"));
    }

    #[test]
    fn peer_pin_rejects_a_different_generation_identity() {
        let expected = GenerationIdentity::generate().expect("expected identity");
        let presented = GenerationIdentity::generate().expect("presented identity");

        assert!(
            verify_pinned_certificate(&presented.certificate_der, &[], expected.spki_sha256,)
                .is_err()
        );
    }

    #[test]
    fn exporter_confirmation_matches_the_cross_language_vector() {
        let mut exporter = [0_u8; EXPORTER_OUTPUT_BYTES];
        for (index, byte) in exporter.iter_mut().enumerate() {
            *byte = index as u8;
        }
        let session_id =
            uuid::Uuid::parse_str("00112233-4455-6677-8899-aabbccddeeff").expect("session id");
        let record = confirmation_record(&exporter, NestedTlsRole::Device, 9, session_id);

        assert_eq!(record[0], 1);
        assert_eq!(record[1], NestedTlsRole::Device as u8);
        assert_eq!(
            hex::encode(&record[2..]),
            "0c53d315be38f07f3cccd675e64f41621d8fc50cba65ab1133562d508aff9c48"
        );
        verify_peer_confirmation(&record, &exporter, NestedTlsRole::Proxy, 9, session_id)
            .expect("peer confirmation");
    }

    #[test]
    fn exporter_confirmation_rejects_role_generation_session_and_tag_changes() {
        let exporter = [7_u8; EXPORTER_OUTPUT_BYTES];
        let session_id = uuid::Uuid::new_v4();
        let record = confirmation_record(&exporter, NestedTlsRole::Device, 3, session_id);

        assert!(
            verify_peer_confirmation(&record, &exporter, NestedTlsRole::Device, 3, session_id)
                .is_err()
        );
        assert!(
            verify_peer_confirmation(&record, &exporter, NestedTlsRole::Proxy, 4, session_id)
                .is_err()
        );
        assert!(verify_peer_confirmation(
            &record,
            &exporter,
            NestedTlsRole::Proxy,
            3,
            uuid::Uuid::new_v4()
        )
        .is_err());
        let mut changed = record;
        changed[2] ^= 1;
        assert!(
            verify_peer_confirmation(&changed, &exporter, NestedTlsRole::Proxy, 3, session_id)
                .is_err()
        );
    }
}
