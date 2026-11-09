//! OpenMLS provider whose whole state can be saved and restored, so a
//! member can be "restarted" in tests (docs/PROTOCOL.md B13: persisting and
//! restoring MLS state). In the app this blob would live in the PIN vault.

use std::collections::HashMap;
use std::sync::RwLock;

use openmls_rust_crypto::{MemoryStorage, RustCrypto};
use openmls_traits::OpenMlsProvider;

#[derive(Default)]
pub struct PocProvider {
    crypto: RustCrypto,
    storage: MemoryStorage,
}

impl PocProvider {
    /// Serialized OpenMLS storage (group state, epoch secrets, keys): the
    /// key/value pairs, sorted so equal states give equal bytes.
    pub fn snapshot(&self) -> Vec<u8> {
        let values = self.storage.values.read().expect("storage lock");
        let mut pairs: Vec<(&Vec<u8>, &Vec<u8>)> = values.iter().collect();
        pairs.sort();
        serde_json::to_vec(&pairs).expect("storage serializes")
    }

    pub fn restore(bytes: &[u8]) -> std::io::Result<Self> {
        let pairs: Vec<(Vec<u8>, Vec<u8>)> = serde_json::from_slice(bytes)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        Ok(Self {
            crypto: RustCrypto::default(),
            storage: MemoryStorage {
                values: RwLock::new(pairs.into_iter().collect::<HashMap<_, _>>()),
            },
        })
    }
}

impl OpenMlsProvider for PocProvider {
    type CryptoProvider = RustCrypto;
    type RandProvider = RustCrypto;
    type StorageProvider = MemoryStorage;

    fn storage(&self) -> &Self::StorageProvider {
        &self.storage
    }

    fn crypto(&self) -> &Self::CryptoProvider {
        &self.crypto
    }

    fn rand(&self) -> &Self::RandProvider {
        &self.crypto
    }
}
