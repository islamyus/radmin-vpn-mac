// SPDX-License-Identifier: GPL-3.0-only
use anyhow::{anyhow, Result};
use std::sync::Mutex;

/// Reuse an already-authorized identity for this frontend's lifetime. The
/// loader still owns Keychain authorization; errors are never cached as data.
pub struct SessionIdentity<T> { value: Mutex<Option<T>> }
impl<T: Clone> SessionIdentity<T> {
    pub fn new() -> Self { Self { value: Mutex::new(None) } }
    pub fn get_or_load(&self, load: impl FnOnce() -> Result<T>) -> Result<T> {
        let mut slot = self.value.lock().map_err(|_| anyhow!("Identity cache unavailable"))?;
        if let Some(value) = slot.as_ref() { return Ok(value.clone()); }
        let value = load()?;
        *slot = Some(value.clone());
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    #[test]
    fn reconnects_only_load_the_authorized_identity_once() {
        let cache = SessionIdentity::new();
        let reads = AtomicUsize::new(0);
        for _ in 0..5 {
            let id = cache.get_or_load(|| { reads.fetch_add(1, Ordering::SeqCst); Ok(42) }).unwrap();
            assert_eq!(id,42);
        }
        assert_eq!(reads.load(Ordering::SeqCst),1);
    }
    #[test]
    fn authorization_failure_does_not_supply_an_identity_or_register_a_replacement() {
        let cache = SessionIdentity::<u64>::new();
        assert!(cache.get_or_load(|| Err(anyhow!("denied"))).is_err());
        assert_eq!(cache.get_or_load(|| Ok(42)).unwrap(),42);
        assert_eq!(cache.get_or_load(|| panic!("Keychain must not be read again")).unwrap(),42);
    }
}
